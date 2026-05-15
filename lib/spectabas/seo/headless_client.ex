defmodule Spectabas.SEO.HeadlessClient do
  @moduledoc """
  HTTP client wrapping the Playwright sidecar service. The sidecar
  exposes a single `POST /audit` endpoint that fetches a URL in a real
  Chromium browser, waits for network-idle, and returns the rendered
  HTML plus response metadata.

  Configured via the `PLAYWRIGHT_URL` env var (e.g.
  `https://spectabas-playwright.onrender.com`). When unset or
  unreachable, `fetch/2` returns `{:error, reason}` so the worker can
  record the failure on the audit row instead of crashing.

  The sidecar source lives in `playwright-sidecar/` at the repo root —
  deployed separately to Render. See that directory's README for
  deploy instructions.
  """

  require Logger

  @default_timeout 35_000

  @doc """
  Fetch a URL through the headless browser sidecar.

  Options:
  - `:timeout` — total request timeout in ms (default 35_000)
  - `:user_agent` — per-request UA override (default: sidecar decides)

  Returns:
  - `{:ok, %{html: _, status_code: _, response_time_ms: _, final_url: _}}`
    on success
  - `{:error, reason, %{response_time_ms: _}}` on failure (network,
    timeout, sidecar error, or upstream non-2xx)
  """
  def fetch(url, opts \\ []) when is_binary(url) do
    sidecar = Application.get_env(:spectabas, :playwright_url) || System.get_env("PLAYWRIGHT_URL")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    user_agent = Keyword.get(opts, :user_agent)

    cond do
      is_nil(sidecar) or sidecar == "" ->
        {:error, "PLAYWRIGHT_URL not configured", %{response_time_ms: 0}}

      true ->
        do_fetch(sidecar, url, timeout, user_agent)
    end
  end

  defp do_fetch(sidecar, url, timeout, user_agent) do
    started = System.monotonic_time(:millisecond)

    body =
      %{"url" => url, "timeout_ms" => timeout - 5_000}
      |> maybe_add_user_agent(user_agent)

    case Req.post(sidecar <> "/audit",
           json: body,
           receive_timeout: timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"html" => html} = b}} ->
        elapsed = System.monotonic_time(:millisecond) - started

        {:ok,
         %{
           html: html,
           status_code: Map.get(b, "status_code", 200),
           response_time_ms: Map.get(b, "response_time_ms", elapsed),
           final_url: Map.get(b, "final_url", url),
           # v6.10.52: performance field is %{nav, paint, lcp_ms,
           # resources} as captured by the sidecar's page.evaluate.
           # Older sidecars return nil here — `SEO.parse_and_score`
           # treats missing perf data as "no data, skip the perf
           # rules" rather than failing.
           performance: Map.get(b, "performance")
         }}

      {:ok, %{status: s, body: b}} ->
        Logger.warning("[SEO/HeadlessClient] sidecar returned #{s}: #{inspect(b)}")
        elapsed = System.monotonic_time(:millisecond) - started
        {:error, "Sidecar returned HTTP #{s}", %{response_time_ms: elapsed}}

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - started
        Logger.warning("[SEO/HeadlessClient] transport error: #{inspect(reason)}")
        {:error, "Headless fetch failed: #{inspect(reason)}", %{response_time_ms: elapsed}}
    end
  end

  defp maybe_add_user_agent(body, nil), do: body
  defp maybe_add_user_agent(body, ""), do: body
  defp maybe_add_user_agent(body, ua) when is_binary(ua), do: Map.put(body, "user_agent", ua)

  @doc """
  Whether the sidecar is configured at all. UI uses this to surface a
  helpful banner when SEO audits are unavailable.
  """
  def configured? do
    val = Application.get_env(:spectabas, :playwright_url) || System.get_env("PLAYWRIGHT_URL")
    is_binary(val) and val != ""
  end
end
