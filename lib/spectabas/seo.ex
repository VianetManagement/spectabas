defmodule Spectabas.SEO do
  @moduledoc """
  Per-page SEO audit context. Drives the `/dashboard/sites/:id/seo`
  surface and the SEO tab on Page Detail.

  ## Pipeline

      1. `Spectabas.Workers.SEOPageAudit` enqueued (or on-demand
         from the UI).
      2. Worker fetches the URL through `Spectabas.SEO.HeadlessClient`
         which proxies to a Playwright sidecar service (`PLAYWRIGHT_URL`).
      3. `parse_and_score/3` parses HTML (Floki), extracts metadata +
         counts, and computes a 0-100 score with issue list.
      4. `persist/1` writes the row and prunes older audits for the
         (site, url) pair to the most-recent 12.

  Per-(site, url) retention is capped at 12 — enough for ~3 months of
  weekly audits, used by the audit-history table on the Page Detail
  SEO tab + future title/meta change-tracker insights (Phase 4).

  ## Scoring rubric

  Start from 100 and subtract issue penalties:

  Critical (-20 each):
    - Missing title
    - Missing canonical
    - h1_count == 0
    - h1_count > 1
    - status_code != 200
    - meta_robots includes "noindex"

  Major (-10 each):
    - Title length outside 30..65 chars
    - Missing meta description
    - Meta description length outside 70..160 chars
    - response_time_ms > 3000
    - word_count < 150
    - image_alt_count / image_count < 0.5 (only counted when image_count > 0)

  Minor (-5 each):
    - Missing og:image
    - No schema.org types
    - Title equals h1 (verbatim) — minor; might be intentional but
      usually a missed differentiation opportunity

  Score floored at 0. Issues list contains each penalty with the
  `severity` ("critical"|"major"|"minor"), `code` (machine-readable),
  and `message` (human-readable, includes the offending value where
  useful).
  """

  import Ecto.Query
  alias Spectabas.Repo
  alias Spectabas.SEO.PageAudit

  @history_cap 12

  # ---- Crawl budget ----

  @doc """
  How many scheduled audits the site has already run this calendar
  week (Monday 00:00 UTC start). On-demand audits don't count.
  """
  def used_this_week(site_id) when is_integer(site_id) do
    monday = week_start_utc()

    from(a in PageAudit,
      where: a.site_id == ^site_id,
      where: a.trigger == "scheduled",
      where: a.captured_at >= ^monday
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Remaining weekly budget for scheduled audits. Returns 0 if the site
  has used its full allowance. Budget is `sites.seo_crawl_budget`
  (default 500, range 100..5000).
  """
  def budget_remaining(%{seo_crawl_budget: budget, id: site_id}) when is_integer(budget) do
    max(budget - used_this_week(site_id), 0)
  end

  def budget_remaining(%{id: site_id}),
    do: budget_remaining(%{seo_crawl_budget: 500, id: site_id})

  @doc """
  Enqueue an SEO audit for a (site, url). On-demand triggers always
  enqueue; scheduled triggers decrement the weekly budget. Returns
  `{:ok, job}` on success, `{:error, :budget_exhausted}` if the
  site's budget is spent for the week.

  Caller-supplied `:trigger` defaults to `"scheduled"`.
  """
  def enqueue_audit(%{id: site_id} = site, url, opts \\ []) when is_binary(url) do
    trigger = Keyword.get(opts, :trigger, "scheduled")

    cond do
      trigger != "scheduled" ->
        do_enqueue(site_id, url, trigger)

      budget_remaining(site) > 0 ->
        do_enqueue(site_id, url, trigger)

      true ->
        {:error, :budget_exhausted}
    end
  end

  defp do_enqueue(site_id, url, trigger) do
    %{"site_id" => site_id, "url" => url, "trigger" => trigger}
    |> Spectabas.Workers.SEOPageAudit.new()
    |> Oban.insert()
  end

  defp week_start_utc do
    now = DateTime.utc_now()
    days_since_monday = Date.day_of_week(DateTime.to_date(now)) - 1

    %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
    |> DateTime.add(-days_since_monday, :day)
  end

  @doc """
  Latest audit row for a (site_id, url) pair, or nil if never audited.
  """
  def latest(site_id, url) when is_integer(site_id) and is_binary(url) do
    from(a in PageAudit,
      where: a.site_id == ^site_id and a.url == ^url,
      order_by: [desc: a.captured_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Recent audits for a (site_id, url) pair, newest first. Up to
  `@history_cap` rows since we prune older on insert.
  """
  def history(site_id, url) when is_integer(site_id) and is_binary(url) do
    from(a in PageAudit,
      where: a.site_id == ^site_id and a.url == ^url,
      order_by: [desc: a.captured_at]
    )
    |> Repo.all()
  end

  @doc """
  Latest audit row per URL for a site, sorted by score asc (worst
  first) by default. Used by the SEO listing page.
  """
  def latest_per_url(site_id, opts \\ []) when is_integer(site_id) do
    order = Keyword.get(opts, :order, :score_asc)
    limit = Keyword.get(opts, :limit, 200)

    # DISTINCT ON (url) returns the newest row per url. PG handles the
    # ORDER inside DISTINCT ON before any user-facing ORDER BY.
    inner =
      from(a in PageAudit,
        where: a.site_id == ^site_id,
        distinct: a.url,
        order_by: [a.url, desc: a.captured_at],
        select: a
      )

    final =
      case order do
        :score_asc -> from(a in subquery(inner), order_by: [asc_nulls_last: a.score])
        :score_desc -> from(a in subquery(inner), order_by: [desc_nulls_last: a.score])
        :url -> from(a in subquery(inner), order_by: [asc: a.url])
        :recent -> from(a in subquery(inner), order_by: [desc: a.captured_at])
      end

    final |> limit(^limit) |> Repo.all()
  end

  @doc """
  Parse a fetched HTML doc, score it, and return a map ready for
  `persist/1`. Pure function — does not write to the DB.

  `fetch_result` is the map returned by `HeadlessClient.fetch/2`:
  `%{html: _, status_code: _, response_time_ms: _, final_url: _}`.
  Pass an `%{error: reason, response_time_ms: _}` shape for failed
  fetches; we record those too so the UI can show what happened.
  """
  def parse_and_score(site_id, url, fetch_result) when is_integer(site_id) and is_binary(url) do
    base = %{
      site_id: site_id,
      url: url,
      captured_at: DateTime.utc_now(),
      trigger: Map.get(fetch_result, :trigger, "scheduled")
    }

    case fetch_result do
      %{error: reason} = r ->
        Map.merge(base, %{
          error: to_string(reason),
          response_time_ms: Map.get(r, :response_time_ms),
          status_code: Map.get(r, :status_code),
          score: 0,
          issues: %{
            "items" => [
              %{
                "severity" => "critical",
                "code" => "fetch_failed",
                "message" => "Page could not be fetched: #{reason}"
              }
            ]
          }
        })

      %{html: html} = r ->
        parsed = parse_html(html, url)

        Map.merge(base, %{
          status_code: Map.get(r, :status_code, 200),
          final_url: Map.get(r, :final_url, url),
          response_time_ms: Map.get(r, :response_time_ms),
          content_hash: :crypto.hash(:sha256, html) |> Base.encode16(case: :lower),
          title: parsed.title,
          meta_description: parsed.meta_description,
          h1: parsed.h1,
          h1_count: parsed.h1_count,
          canonical: parsed.canonical,
          og_title: parsed.og_title,
          og_description: parsed.og_description,
          og_image: parsed.og_image,
          schema_types: parsed.schema_types,
          meta_robots: parsed.meta_robots,
          word_count: parsed.word_count,
          internal_link_count: parsed.internal_link_count,
          external_link_count: parsed.external_link_count,
          image_count: parsed.image_count,
          image_alt_count: parsed.image_alt_count
        })
        |> score()
    end
  end

  @doc """
  Insert an audit row + prune older rows for the same (site_id, url)
  pair beyond the 12-row cap.
  """
  def persist(attrs) when is_map(attrs) do
    {:ok, audit} =
      %PageAudit{}
      |> PageAudit.changeset(attrs)
      |> Repo.insert()

    prune_old(audit.site_id, audit.url)
    {:ok, audit}
  end

  defp prune_old(site_id, url) do
    keep_ids =
      from(a in PageAudit,
        where: a.site_id == ^site_id and a.url == ^url,
        order_by: [desc: a.captured_at],
        limit: ^@history_cap,
        select: a.id
      )
      |> Repo.all()

    from(a in PageAudit,
      where: a.site_id == ^site_id and a.url == ^url and a.id not in ^keep_ids
    )
    |> Repo.delete_all()
  end

  # ---- HTML parsing ----

  @doc false
  def parse_html(html, page_url) when is_binary(html) do
    doc =
      case Floki.parse_document(html) do
        {:ok, d} -> d
        _ -> []
      end

    host = page_host(page_url)
    links = Floki.find(doc, "a[href]")
    {internal, external} = classify_links(links, host)
    images = Floki.find(doc, "img")
    images_with_alt = Enum.count(images, fn img -> alt(img) not in [nil, ""] end)

    %{
      title: text_or_nil(Floki.find(doc, "title")),
      meta_description: meta_content(doc, "description"),
      h1: text_or_nil(Floki.find(doc, "h1") |> Enum.take(1)),
      h1_count: length(Floki.find(doc, "h1")),
      canonical: link_href(doc, "canonical"),
      og_title: meta_property(doc, "og:title"),
      og_description: meta_property(doc, "og:description"),
      og_image: meta_property(doc, "og:image"),
      schema_types: extract_schema_types(doc),
      meta_robots: meta_content(doc, "robots"),
      word_count: word_count(doc),
      internal_link_count: internal,
      external_link_count: external,
      image_count: length(images),
      image_alt_count: images_with_alt
    }
  end

  defp page_host(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) -> String.downcase(h)
      _ -> ""
    end
  end

  defp classify_links(links, host) do
    Enum.reduce(links, {0, 0}, fn link, {i, e} ->
      href = href(link)

      cond do
        href == nil or href == "" or String.starts_with?(href, "#") ->
          {i, e}

        String.starts_with?(href, "/") ->
          {i + 1, e}

        link_host = link_host(href) ->
          cond do
            link_host == "" or link_host == host -> {i + 1, e}
            true -> {i, e + 1}
          end

        true ->
          {i + 1, e}
      end
    end)
  end

  defp link_host(href) do
    case URI.parse(href) do
      %URI{host: h} when is_binary(h) -> String.downcase(h)
      _ -> nil
    end
  end

  defp href({_tag, attrs, _children}) do
    Enum.find_value(attrs, fn
      {"href", v} -> v
      _ -> nil
    end)
  end

  defp alt({_tag, attrs, _children}) do
    Enum.find_value(attrs, fn
      {"alt", v} -> v
      _ -> nil
    end)
  end

  defp text_or_nil([]), do: nil

  defp text_or_nil(nodes) do
    nodes
    |> Floki.text()
    |> String.trim()
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp meta_content(doc, name) do
    Floki.find(doc, "meta[name='#{name}']")
    |> first_attr("content")
  end

  defp meta_property(doc, property) do
    Floki.find(doc, "meta[property='#{property}']")
    |> first_attr("content")
  end

  defp link_href(doc, rel) do
    Floki.find(doc, "link[rel='#{rel}']")
    |> first_attr("href")
  end

  defp first_attr([], _key), do: nil

  defp first_attr([{_tag, attrs, _} | _], key) do
    Enum.find_value(attrs, fn
      {^key, v} when v != "" -> v
      _ -> nil
    end)
  end

  defp first_attr(_, _), do: nil

  defp extract_schema_types(doc) do
    doc
    |> Floki.find("script[type='application/ld+json']")
    |> Enum.flat_map(fn {_tag, _attrs, children} ->
      raw =
        children
        |> Enum.filter(&is_binary/1)
        |> Enum.join("")
        |> String.trim()

      case Jason.decode(raw) do
        {:ok, data} -> data |> List.wrap() |> Enum.flat_map(&schema_type_of/1)
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp schema_type_of(%{"@type" => t}) when is_binary(t), do: [t]
  defp schema_type_of(%{"@type" => list}) when is_list(list), do: list
  defp schema_type_of(_), do: []

  defp word_count(doc) do
    doc
    |> Floki.find("body")
    |> Floki.text(sep: " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  # ---- Scoring ----

  defp score(attrs) do
    issues = []
    points = 100

    {points, issues} = check_status(points, issues, attrs)
    {points, issues} = check_robots(points, issues, attrs)
    {points, issues} = check_title(points, issues, attrs)
    {points, issues} = check_meta_description(points, issues, attrs)
    {points, issues} = check_h1(points, issues, attrs)
    {points, issues} = check_canonical(points, issues, attrs)
    {points, issues} = check_response_time(points, issues, attrs)
    {points, issues} = check_word_count(points, issues, attrs)
    {points, issues} = check_image_alt(points, issues, attrs)
    {points, issues} = check_og_image(points, issues, attrs)
    {points, issues} = check_schema(points, issues, attrs)
    {points, issues} = check_title_eq_h1(points, issues, attrs)

    Map.merge(attrs, %{score: max(points, 0), issues: %{"items" => Enum.reverse(issues)}})
  end

  defp critical(points, issues, code, message),
    do:
      {points - 20, [%{"severity" => "critical", "code" => code, "message" => message} | issues]}

  defp major(points, issues, code, message),
    do: {points - 10, [%{"severity" => "major", "code" => code, "message" => message} | issues]}

  defp minor(points, issues, code, message),
    do: {points - 5, [%{"severity" => "minor", "code" => code, "message" => message} | issues]}

  defp check_status(points, issues, %{status_code: c}) when is_integer(c) and c != 200,
    do: critical(points, issues, "non_200_status", "Page returned HTTP #{c}")

  defp check_status(points, issues, _), do: {points, issues}

  defp check_robots(points, issues, %{meta_robots: r}) when is_binary(r) do
    if String.contains?(String.downcase(r), "noindex") do
      critical(
        points,
        issues,
        "noindex",
        "Page has `meta robots = #{r}` — excluded from search index"
      )
    else
      {points, issues}
    end
  end

  defp check_robots(points, issues, _), do: {points, issues}

  defp check_title(points, issues, %{title: nil}),
    do: critical(points, issues, "missing_title", "Title tag is missing")

  defp check_title(points, issues, %{title: t}) when is_binary(t) do
    len = String.length(t)

    cond do
      len < 30 ->
        major(points, issues, "title_too_short", "Title is #{len} chars (recommended 30–65)")

      len > 65 ->
        major(points, issues, "title_too_long", "Title is #{len} chars (recommended 30–65)")

      true ->
        {points, issues}
    end
  end

  defp check_title(points, issues, _), do: {points, issues}

  defp check_meta_description(points, issues, %{meta_description: nil}),
    do: major(points, issues, "missing_meta_description", "Meta description is missing")

  defp check_meta_description(points, issues, %{meta_description: m}) when is_binary(m) do
    len = String.length(m)

    cond do
      len < 70 ->
        major(
          points,
          issues,
          "meta_description_too_short",
          "Meta description is #{len} chars (recommended 70–160)"
        )

      len > 160 ->
        major(
          points,
          issues,
          "meta_description_too_long",
          "Meta description is #{len} chars (recommended 70–160)"
        )

      true ->
        {points, issues}
    end
  end

  defp check_meta_description(points, issues, _), do: {points, issues}

  defp check_h1(points, issues, %{h1_count: 0}),
    do: critical(points, issues, "missing_h1", "No `<h1>` tag found on the page")

  defp check_h1(points, issues, %{h1_count: c}) when is_integer(c) and c > 1,
    do: critical(points, issues, "multiple_h1", "Found #{c} `<h1>` tags (should be exactly 1)")

  defp check_h1(points, issues, _), do: {points, issues}

  defp check_canonical(points, issues, %{canonical: nil}),
    do: critical(points, issues, "missing_canonical", "Canonical link tag is missing")

  defp check_canonical(points, issues, _), do: {points, issues}

  defp check_response_time(points, issues, %{response_time_ms: ms})
       when is_integer(ms) and ms > 3000,
       do:
         major(
           points,
           issues,
           "slow_response",
           "Page took #{ms}ms to load (recommended < 3000ms)"
         )

  defp check_response_time(points, issues, _), do: {points, issues}

  defp check_word_count(points, issues, %{word_count: n}) when is_integer(n) and n < 150,
    do: major(points, issues, "thin_content", "Word count is #{n} (recommended > 150)")

  defp check_word_count(points, issues, _), do: {points, issues}

  defp check_image_alt(points, issues, %{image_count: ic, image_alt_count: ac})
       when is_integer(ic) and ic > 0 do
    coverage = ac / ic

    if coverage < 0.5 do
      major(
        points,
        issues,
        "missing_image_alt",
        "Only #{ac} of #{ic} images have alt text (#{round(coverage * 100)}% coverage)"
      )
    else
      {points, issues}
    end
  end

  defp check_image_alt(points, issues, _), do: {points, issues}

  defp check_og_image(points, issues, %{og_image: nil}),
    do:
      minor(
        points,
        issues,
        "missing_og_image",
        "No og:image — link previews on social will be blank"
      )

  defp check_og_image(points, issues, _), do: {points, issues}

  defp check_schema(points, issues, %{schema_types: []}),
    do: minor(points, issues, "no_schema", "No JSON-LD schema.org markup found")

  defp check_schema(points, issues, _), do: {points, issues}

  defp check_title_eq_h1(points, issues, %{title: t, h1: h})
       when is_binary(t) and is_binary(h) do
    if String.downcase(String.trim(t)) == String.downcase(String.trim(h)) do
      minor(
        points,
        issues,
        "title_equals_h1",
        "Title and H1 are identical — consider differentiating"
      )
    else
      {points, issues}
    end
  end

  defp check_title_eq_h1(points, issues, _), do: {points, issues}
end
