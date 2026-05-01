defmodule Spectabas.Conversions.ClickResolver do
  @moduledoc """
  Walks back through a visitor's events to find the click identifier that
  brought them to the site, within an attribution window. Used by every
  detector at conversion-record time.

  Returns `{click_id, click_id_type}` strings, or `{nil, nil}` if no
  valid click found. The Google `click_id_type` is normalized to one of:

    * `"google"`        — gclid (web → web)
    * `"google_wbraid"` — wbraid (in-app ad → web)
    * `"google_gbraid"` — gbraid (web ad → in-app)
    * `"microsoft"`     — msclkid
    * other strings as ingested

  Bounded by SETTINGS max_execution_time so it can't pin ClickHouse.
  """

  alias Spectabas.ClickHouse
  alias Spectabas.Sites.Site

  @doc """
  Returns the visitor's *first* click within the window
  (`attribution_model = "first_click"`) or *last* (`last_click`).
  """
  def resolve(site, visitor_id, occurred_at, opts \\ [])

  def resolve(%Site{} = site, visitor_id, occurred_at, opts)
      when is_binary(visitor_id) and visitor_id != "" do
    window_days = Keyword.get(opts, :window_days, 90)
    model = Keyword.get(opts, :attribution_model, "first_click")

    from_dt = DateTime.add(occurred_at, -window_days * 86_400, :second)

    arg_fn = if model == "last_click", do: "argMaxIf", else: "argMinIf"

    sql = """
    SELECT
      #{arg_fn}(click_id, timestamp, click_id != '') AS click_id,
      #{arg_fn}(click_id_type, timestamp, click_id_type != '') AS click_id_type
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND visitor_id = #{ClickHouse.param(visitor_id)}
      AND timestamp >= #{ClickHouse.param(format_dt(from_dt))}
      AND timestamp <= #{ClickHouse.param(format_dt(occurred_at))}
      AND click_id != ''
    SETTINGS max_execution_time = 10
    """

    case ClickHouse.query(sql) do
      {:ok, [row]} ->
        click_id = row["click_id"] || ""
        click_type = row["click_id_type"] || ""

        if click_id == "" do
          {nil, nil}
        else
          {click_id, normalize_type(click_type)}
        end

      _ ->
        {nil, nil}
    end
  end

  def resolve(_site, _visitor_id, _occurred_at, _opts), do: {nil, nil}

  @doc """
  Same as resolve/4 but takes an email — looks up the visitor first, then
  resolves. Used by Stripe payment detection where we only know the email.
  Tries every visitor with that email on the site (handles cookie-clear /
  multi-device cases) and picks the earliest qualifying click.
  """
  def resolve_by_email(site, email, occurred_at, opts \\ [])

  def resolve_by_email(%Site{} = site, email, occurred_at, opts)
      when is_binary(email) and email != "" do
    n_email = email |> String.trim() |> String.downcase()

    visitor_ids = list_visitor_ids_for_email(site.id, n_email)

    if visitor_ids == [] do
      {nil, nil}
    else
      window_days = Keyword.get(opts, :window_days, 90)
      from_dt = DateTime.add(occurred_at, -window_days * 86_400, :second)
      ids_sql = visitor_ids |> Enum.map(&ClickHouse.param/1) |> Enum.join(", ")

      sql = """
      SELECT
        argMinIf(click_id, timestamp, click_id != '') AS click_id,
        argMinIf(click_id_type, timestamp, click_id_type != '') AS click_id_type
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND visitor_id IN (#{ids_sql})
        AND timestamp >= #{ClickHouse.param(format_dt(from_dt))}
        AND timestamp <= #{ClickHouse.param(format_dt(occurred_at))}
        AND click_id != ''
      SETTINGS max_execution_time = 10
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} ->
          click_id = row["click_id"] || ""

          if click_id == "" do
            {nil, nil}
          else
            {click_id, normalize_type(row["click_id_type"] || "")}
          end

        _ ->
          {nil, nil}
      end
    end
  end

  def resolve_by_email(_, _, _, _), do: {nil, nil}

  defp list_visitor_ids_for_email(site_id, email) do
    import Ecto.Query

    Spectabas.Repo.all(
      from(v in Spectabas.Visitors.Visitor,
        where: v.site_id == ^site_id and v.email == ^email,
        select: v.id
      )
    )
    |> Enum.map(&to_string/1)
  end

  defp normalize_type(t) do
    case String.downcase(to_string(t)) do
      "gclid" -> "google"
      "wbraid" -> "google_wbraid"
      "gbraid" -> "google_gbraid"
      "msclkid" -> "microsoft"
      "fbclid" -> "meta"
      "" -> ""
      other -> other
    end
  end

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
