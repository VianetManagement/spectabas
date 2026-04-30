defmodule SpectabasWeb.API.WhitelistController do
  @moduledoc """
  Scraper-detector email whitelist endpoints. Equivalent to clicking the
  Whitelist / Remove from whitelist buttons on a visitor profile, but keyed
  by email (not visitor) so external services can pre-whitelist customers
  before they've ever visited.

  See `docs/scraper-labels.md` for the label sources written here.
  """

  use SpectabasWeb, :controller

  alias Spectabas.{Accounts, ScraperLabels, Sites, Visitors}
  alias SpectabasWeb.Plugs.ApiAuth
  require Logger

  @doc """
  POST /api/v1/sites/:site_id/whitelist
  Body: {"email": "user@example.com"}

  Adds the email to the site's allowlist (idempotent), flips any existing
  visitors with that email to `scraper_whitelisted = true`, clears their
  current scraper flags, and writes a `not_scraper`/`api_whitelist` label.
  """
  def create(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "write:whitelist"),
         {:ok, site, _user} <- authorize_site(conn, site_id),
         {:ok, email} <- validate_email(params["email"]) do
      case Visitors.whitelist_email(site.id, email,
             source: "api",
             added_by_user_id: conn.assigns[:current_user_id]
           ) do
        {:ok, %{visitors_updated: count}} ->
          ScraperLabels.record(%{
            site_id: site.id,
            label: "not_scraper",
            source: "api_whitelist",
            email: email,
            user_id: conn.assigns[:current_user_id],
            notes: "via API; #{count} existing visitor record(s) updated"
          })

          json(conn, %{ok: true, email: email, visitors_updated: count})

        {:error, :invalid_email} ->
          conn |> put_status(400) |> json(%{error: "invalid email"})

        {:error, reason} ->
          Logger.warning("[API:whitelist] add failed: #{inspect(reason)}")
          conn |> put_status(422) |> json(%{error: "could not add to whitelist"})
      end
    else
      error -> handle_error(conn, error)
    end
  end

  @doc """
  DELETE /api/v1/sites/:site_id/whitelist
  Body: {"email": "user@example.com"}

  Removes the email from the site's allowlist and flips any existing
  visitors with that email to `scraper_whitelisted = false`. Writes an
  `api_unwhitelist` label (note: this label is intentionally weakly
  weighted — removing an exemption is not a strong "this is a scraper"
  claim).
  """
  def delete(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "write:whitelist"),
         {:ok, site, _user} <- authorize_site(conn, site_id),
         {:ok, email} <- validate_email(params["email"]) do
      case Visitors.unwhitelist_email(site.id, email) do
        {:ok, %{visitors_updated: count}} ->
          ScraperLabels.record(%{
            site_id: site.id,
            label: "scraper",
            source: "api_unwhitelist",
            email: email,
            user_id: conn.assigns[:current_user_id],
            notes: "via API; #{count} existing visitor record(s) updated"
          })

          json(conn, %{ok: true, email: email, visitors_updated: count})

        {:error, :invalid_email} ->
          conn |> put_status(400) |> json(%{error: "invalid email"})

        {:error, reason} ->
          Logger.warning("[API:whitelist] remove failed: #{inspect(reason)}")
          conn |> put_status(422) |> json(%{error: "could not remove from whitelist"})
      end
    else
      error -> handle_error(conn, error)
    end
  end

  # ---- Helpers (same shape as StatsController) ----

  defp validate_email(nil), do: {:error, :invalid_email}
  defp validate_email(""), do: {:error, :invalid_email}

  defp validate_email(email) when is_binary(email) do
    n = email |> String.trim() |> String.downcase()

    cond do
      n == "" -> {:error, :invalid_email}
      not String.contains?(n, "@") -> {:error, :invalid_email}
      String.length(n) > 320 -> {:error, :invalid_email}
      true -> {:ok, n}
    end
  end

  defp validate_email(_), do: {:error, :invalid_email}

  defp require_scope(conn, scope) do
    if ApiAuth.has_scope?(conn, scope) do
      :ok
    else
      {:error, :insufficient_scope}
    end
  end

  defp authorize_site(conn, site_id) do
    user_id = conn.assigns[:current_user_id]
    allowed_site_ids = conn.assigns[:api_site_ids] || []

    with {:ok, site} <- fetch_site(site_id),
         {:ok, user} <- fetch_user(user_id),
         true <- Accounts.can_access_site?(user, site),
         true <- site_allowed?(site.id, allowed_site_ids) do
      {:ok, site, user}
    else
      nil -> {:error, :not_found}
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  defp site_allowed?(_site_id, []), do: true
  defp site_allowed?(site_id, allowed), do: site_id in allowed

  defp fetch_site(site_id) do
    try do
      {:ok, Sites.get_site!(site_id)}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  defp fetch_user(nil), do: {:error, :unauthorized}

  defp fetch_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :unauthorized}
      user -> {:ok, user}
    end
  end

  defp handle_error(conn, {:error, :insufficient_scope}) do
    conn |> put_status(403) |> json(%{error: "insufficient scope"})
  end

  defp handle_error(conn, {:error, :not_found}) do
    conn |> put_status(404) |> json(%{error: "site not found"})
  end

  defp handle_error(conn, {:error, :unauthorized}) do
    conn |> put_status(403) |> json(%{error: "unauthorized"})
  end

  defp handle_error(conn, {:error, :invalid_email}) do
    conn |> put_status(400) |> json(%{error: "invalid email"})
  end

  defp handle_error(conn, {:error, reason}) do
    Logger.warning("[API:whitelist] error: #{inspect(reason) |> String.slice(0, 200)}")
    conn |> put_status(500) |> json(%{error: "internal error"})
  end

  defp handle_error(conn, _) do
    conn |> put_status(500) |> json(%{error: "internal error"})
  end
end
