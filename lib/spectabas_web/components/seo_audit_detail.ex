defmodule SpectabasWeb.SEOAuditDetail do
  @moduledoc """
  Shared SEO audit detail rendering used on both `SEOLive`'s expanded
  row and `TransitionsLive`'s per-page SEO panel. Stateless function
  components; parent owns the wrapping container.

  Subsections:
  - `audit_summary/1` — score badge + summary line + audit-time
  - `audit_error_panel/1` — fetch-error callout (only when error set)
  - `audit_issues/1` — issue list grouped by severity
  - `audit_performance/1` — TTFB / FCP / LCP / load + page weight + req count
  - `audit_slowest_resources/1` — top 10 slowest resources table
  - `audit_resource_breakdown/1` — counts + transfer KB by resource type
  - `audit_headings/1` — heading hierarchy tree
  - `audit_metadata/1` — title/meta/canonical/og/twitter/schema/lang at a glance
  """
  use Phoenix.Component

  alias Spectabas.TypeHelpers

  attr :audit, :map, required: true

  def audit_summary(assigns) do
    ~H"""
    <div class="flex items-center gap-4 flex-wrap">
      <span class={[
        "inline-flex items-center justify-center px-4 py-2 rounded-lg text-2xl font-bold tabular-nums",
        score_class(@audit)
      ]}>
        {score_display(@audit)}
      </span>
      <div class="flex-1 min-w-0">
        <p class="text-sm text-gray-700">{summary_line(@audit)}</p>
        <p class="text-xs text-gray-400 mt-0.5">
          Audited {format_relative(@audit.captured_at)}
          <span :if={@audit.response_time_ms}>
            · sidecar response {format_response(@audit.response_time_ms)}
          </span>
          <span :if={@audit.status_code}>
            · HTTP {@audit.status_code}
          </span>
        </p>
      </div>
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_error_panel(assigns) do
    ~H"""
    <div :if={@audit.error} class="bg-rose-50 border border-rose-200 rounded p-3">
      <p class="text-xs font-semibold text-rose-900 mb-1">Fetch error</p>
      <p class="text-xs text-rose-800 font-mono break-all">{@audit.error}</p>
      <p class="text-xs text-rose-800 mt-2">
        The headless browser couldn't fetch this URL. Common causes: Cloudflare / WAF blocking the request, non-200 status, per-request timeout, or the Playwright sidecar service being unreachable. Site Settings → Content → SEO audit has a Cloudflare allow-rule recipe.
      </p>
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_issues(assigns) do
    assigns = assign(assigns, :items, issues_list(assigns.audit))

    ~H"""
    <div :if={@items != []}>
      <p class="text-xs font-semibold text-gray-700 mb-2">Issues to fix</p>
      <ul class="space-y-1.5">
        <li
          :for={issue <- @items}
          class={[
            "border-l-4 pl-3 py-1.5",
            case issue["severity"] do
              "critical" -> "border-rose-500 bg-rose-50"
              "major" -> "border-amber-500 bg-amber-50"
              _ -> "border-gray-300 bg-gray-50"
            end
          ]}
        >
          <span class="text-[10px] font-semibold uppercase tracking-wide text-gray-500 mr-2">
            {issue["severity"]}
          </span>
          <span class="text-xs text-gray-800">{issue["message"]}</span>
        </li>
      </ul>
    </div>
    <div :if={@items == [] and !@audit.error} class="text-xs text-emerald-700">
      ✓ No issues detected.
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_performance(assigns) do
    perf = get_in(assigns.audit, [Access.key(:extras), "performance"]) || %{}
    nav = Map.get(perf, "nav") || %{}
    paint = Map.get(perf, "paint") || %{}
    lcp = Map.get(perf, "lcp_ms")
    resources = Map.get(perf, "resources") || []
    total_weight = resources |> Enum.map(&Map.get(&1, "transfer_size", 0)) |> Enum.sum()

    assigns =
      assign(assigns,
        nav: nav,
        paint: paint,
        lcp: lcp,
        resources: resources,
        total_weight: total_weight
      )

    ~H"""
    <div :if={@nav != %{} or @lcp}>
      <p class="text-xs font-semibold text-gray-700 mb-2">Performance</p>
      <div class="grid grid-cols-3 md:grid-cols-6 gap-2 text-center">
        <.perf_metric label="DNS" value_ms={Map.get(@nav, "dns")} thresholds={{50, 150}} />
        <.perf_metric label="TCP" value_ms={Map.get(@nav, "tcp")} thresholds={{50, 200}} />
        <.perf_metric label="TLS" value_ms={Map.get(@nav, "tls")} thresholds={{100, 300}} />
        <.perf_metric label="TTFB" value_ms={Map.get(@nav, "ttfb")} thresholds={{800, 1800}} />
        <.perf_metric label="FCP" value_ms={Map.get(@paint, "fcp")} thresholds={{1800, 3000}} />
        <.perf_metric label="LCP" value_ms={@lcp} thresholds={{2500, 4000}} />
      </div>

      <div class="grid grid-cols-3 gap-2 mt-3 text-center">
        <div class="bg-gray-50 rounded p-2">
          <p class="text-[10px] text-gray-500 uppercase">DOM</p>
          <p class="text-sm font-bold tabular-nums">
            {format_ms(Map.get(@nav, "dom_content_loaded"))}
          </p>
        </div>
        <div class="bg-gray-50 rounded p-2">
          <p class="text-[10px] text-gray-500 uppercase">Load</p>
          <p class="text-sm font-bold tabular-nums">{format_ms(Map.get(@nav, "load"))}</p>
        </div>
        <div class="bg-gray-50 rounded p-2">
          <p class="text-[10px] text-gray-500 uppercase">Protocol</p>
          <p class="text-sm font-bold uppercase">{Map.get(@nav, "protocol") || "—"}</p>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-2 mt-3 text-center">
        <div class={[
          "rounded p-2",
          page_weight_class(@total_weight)
        ]}>
          <p class="text-[10px] text-gray-500 uppercase">Page weight (transfer)</p>
          <p class="text-sm font-bold tabular-nums">{format_bytes(@total_weight)}</p>
        </div>
        <div class={[
          "rounded p-2",
          request_count_class(length(@resources))
        ]}>
          <p class="text-[10px] text-gray-500 uppercase">Requests</p>
          <p class="text-sm font-bold tabular-nums">{length(@resources)}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_slowest_resources(assigns) do
    resources = get_in(assigns.audit, [Access.key(:extras), "performance", "resources"]) || []

    slowest =
      resources
      |> Enum.sort_by(&Map.get(&1, "duration_ms", 0), :desc)
      |> Enum.take(10)

    assigns = assign(assigns, :slowest, slowest)

    ~H"""
    <div :if={@slowest != []}>
      <p class="text-xs font-semibold text-gray-700 mb-2">Slowest resources</p>
      <div class="bg-gray-50 rounded overflow-hidden">
        <table class="min-w-full text-xs">
          <thead class="bg-gray-100">
            <tr>
              <th class="px-3 py-1.5 text-left text-[10px] font-medium text-gray-500 uppercase">
                URL
              </th>
              <th class="px-3 py-1.5 text-left text-[10px] font-medium text-gray-500 uppercase">
                Type
              </th>
              <th class="px-3 py-1.5 text-right text-[10px] font-medium text-gray-500 uppercase">
                Duration
              </th>
              <th class="px-3 py-1.5 text-right text-[10px] font-medium text-gray-500 uppercase">
                Size
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <tr :for={r <- @slowest} class="hover:bg-white">
              <td class="px-3 py-1.5 font-mono text-[10px] truncate max-w-md" title={r["url"]}>
                {short_url(r["url"])}
              </td>
              <td class="px-3 py-1.5 text-[10px]">
                <span class={[
                  "inline-block px-1.5 py-0.5 rounded font-medium",
                  resource_type_class(r["type"])
                ]}>
                  {r["type"]}
                </span>
              </td>
              <td class="px-3 py-1.5 text-right tabular-nums font-medium">
                {format_ms(r["duration_ms"])}
              </td>
              <td class="px-3 py-1.5 text-right tabular-nums text-gray-500">
                {format_bytes(r["transfer_size"])}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_resource_breakdown(assigns) do
    resources = get_in(assigns.audit, [Access.key(:extras), "performance", "resources"]) || []

    grouped =
      resources
      |> Enum.group_by(&Map.get(&1, "type", "other"))
      |> Enum.map(fn {type, rs} ->
        %{
          type: type,
          count: length(rs),
          total_size: Enum.sum(Enum.map(rs, &Map.get(&1, "transfer_size", 0))),
          total_duration: Enum.sum(Enum.map(rs, &Map.get(&1, "duration_ms", 0)))
        }
      end)
      |> Enum.sort_by(& &1.total_size, :desc)

    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div :if={@grouped != []}>
      <p class="text-xs font-semibold text-gray-700 mb-2">Resource breakdown</p>
      <div class="bg-gray-50 rounded overflow-hidden">
        <table class="min-w-full text-xs">
          <thead class="bg-gray-100">
            <tr>
              <th class="px-3 py-1.5 text-left text-[10px] font-medium text-gray-500 uppercase">
                Type
              </th>
              <th class="px-3 py-1.5 text-right text-[10px] font-medium text-gray-500 uppercase">
                Count
              </th>
              <th class="px-3 py-1.5 text-right text-[10px] font-medium text-gray-500 uppercase">
                Transfer
              </th>
              <th class="px-3 py-1.5 text-right text-[10px] font-medium text-gray-500 uppercase">
                Time
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <tr :for={g <- @grouped}>
              <td class="px-3 py-1.5">
                <span class={[
                  "inline-block px-1.5 py-0.5 rounded font-medium text-[10px]",
                  resource_type_class(g.type)
                ]}>
                  {g.type}
                </span>
              </td>
              <td class="px-3 py-1.5 text-right tabular-nums">{g.count}</td>
              <td class="px-3 py-1.5 text-right tabular-nums">{format_bytes(g.total_size)}</td>
              <td class="px-3 py-1.5 text-right tabular-nums">{format_ms(g.total_duration)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_headings(assigns) do
    headings = get_in(assigns.audit, [Access.key(:extras), "headings"]) || %{}
    h1 = Map.get(headings, "h1", [])
    h2 = Map.get(headings, "h2", [])
    h3 = Map.get(headings, "h3", [])

    assigns = assign(assigns, h1: h1, h2: h2, h3: h3)

    ~H"""
    <div :if={@h1 != [] or @h2 != [] or @h3 != []}>
      <p class="text-xs font-semibold text-gray-700 mb-2">Heading hierarchy</p>
      <div class="bg-gray-50 rounded p-3 text-xs space-y-1">
        <div :for={h <- @h1} class="text-gray-900 font-semibold">
          <span class="text-rose-600 font-mono text-[10px] mr-2">H1</span>{h}
        </div>
        <div :for={h <- @h2} class="text-gray-800 pl-4">
          <span class="text-amber-600 font-mono text-[10px] mr-2">H2</span>{h}
        </div>
        <div :for={h <- @h3} class="text-gray-700 pl-8">
          <span class="text-indigo-600 font-mono text-[10px] mr-2">H3</span>{h}
        </div>
      </div>
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_metadata(assigns) do
    extras = Map.get(assigns.audit, :extras) || %{}
    twitter = Map.get(extras, "twitter_card", %{})
    assigns = assign(assigns, extras: extras, twitter: twitter)

    ~H"""
    <div>
      <p class="text-xs font-semibold text-gray-700 mb-2">Page metadata</p>
      <dl class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-1.5 text-xs">
        <.metadata_row label="Title" value={@audit.title} />
        <.metadata_row label="Title length" value={length_str(@audit.title)} />
        <.metadata_row label="Meta description" value={@audit.meta_description} />
        <.metadata_row label="Meta length" value={length_str(@audit.meta_description)} />
        <.metadata_row label="H1" value={@audit.h1} />
        <.metadata_row label="Canonical" value={@audit.canonical} mono={true} />
        <.metadata_row label="Robots" value={@audit.meta_robots} />
        <.metadata_row label="HTML lang" value={Map.get(@extras, "lang_attribute")} mono={true} />
        <.metadata_row label="Viewport meta" value={Map.get(@extras, "viewport_meta")} mono={true} />
        <.metadata_row label="HTTPS" value={if Map.get(@extras, "https"), do: "yes", else: "no"} />
        <.metadata_row label="OG title" value={@audit.og_title} />
        <.metadata_row label="OG description" value={@audit.og_description} />
        <.metadata_row label="OG image" value={@audit.og_image} mono={true} />
        <.metadata_row label="Twitter card" value={Map.get(@twitter, "card")} />
        <.metadata_row label="Twitter title" value={Map.get(@twitter, "title")} />
        <.metadata_row label="Twitter image" value={Map.get(@twitter, "image")} mono={true} />
        <.metadata_row label="Schema types" value={schema_types_str(@audit.schema_types)} />
        <.metadata_row label="Word count" value={@audit.word_count} />
        <.metadata_row label="Image alt coverage" value={alt_pct(@audit)} />
        <.metadata_row
          label="Internal / External links"
          value={"#{@audit.internal_link_count || 0} / #{@audit.external_link_count || 0}"}
        />
      </dl>
    </div>
    """
  end

  # ---- Small components ----

  attr :label, :string, required: true
  attr :value_ms, :integer, default: nil
  attr :thresholds, :any, default: {1000, 2500}

  defp perf_metric(assigns) do
    {good, ok} = assigns.thresholds
    cls = perf_class(assigns.value_ms, good, ok)
    assigns = assign(assigns, :cls, cls)

    ~H"""
    <div class={["rounded p-2", @cls]}>
      <p class="text-[10px] text-gray-500 uppercase">{@label}</p>
      <p class="text-sm font-bold tabular-nums">{format_ms(@value_ms)}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp metadata_row(assigns) do
    ~H"""
    <div class="contents">
      <dt class="text-gray-500">{@label}</dt>
      <dd class={[
        "text-gray-900 truncate",
        if(@mono, do: "font-mono text-[11px]", else: "")
      ]}>
        {format_value(@value)}
      </dd>
    </div>
    """
  end

  # ---- Helpers ----

  defp score_class(%{error: e}) when is_binary(e) and e != "",
    do: "bg-gray-200 text-gray-700"

  defp score_class(%{score: nil}), do: "bg-gray-100 text-gray-500"

  defp score_class(%{score: s}) when is_integer(s) do
    cond do
      s >= 80 -> "bg-emerald-100 text-emerald-800"
      s >= 60 -> "bg-amber-100 text-amber-800"
      true -> "bg-rose-100 text-rose-800"
    end
  end

  defp score_display(%{error: e}) when is_binary(e) and e != "", do: "Failed"
  defp score_display(%{score: nil}), do: "—"
  defp score_display(%{score: s}), do: to_string(s)

  defp issues_list(%{issues: %{"items" => items}}) when is_list(items), do: items
  defp issues_list(_), do: []

  defp summary_line(%{error: e}) when is_binary(e) and e != "",
    do: "Fetch failed — see error below."

  defp summary_line(audit) do
    items = issues_list(audit)

    case items do
      [] ->
        "No SEO issues detected."

      _ ->
        breakdown = Enum.frequencies_by(items, &Map.get(&1, "severity"))
        crit = Map.get(breakdown, "critical", 0)
        major = Map.get(breakdown, "major", 0)
        minor = Map.get(breakdown, "minor", 0)

        parts =
          [
            crit > 0 && "#{crit} critical",
            major > 0 && "#{major} major",
            minor > 0 && "#{minor} minor"
          ]
          |> Enum.filter(&is_binary/1)

        Enum.join(parts, ", ") <> " — see issues below."
    end
  end

  defp format_relative(nil), do: "—"

  defp format_relative(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp format_response(nil), do: "—"
  defp format_response(ms) when ms < 1000, do: "#{ms}ms"
  defp format_response(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_ms(nil), do: "—"
  defp format_ms(0), do: "—"
  defp format_ms(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_ms(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(other), do: format_ms(TypeHelpers.to_num(other))

  defp format_bytes(nil), do: "—"
  defp format_bytes(0), do: "—"
  defp format_bytes(b) when b < 1024, do: "#{b}B"
  defp format_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1024, 1)}KB"
  defp format_bytes(b), do: "#{Float.round(b / 1_048_576, 2)}MB"

  defp perf_class(nil, _, _), do: "bg-gray-100"
  defp perf_class(0, _, _), do: "bg-gray-100"

  defp perf_class(ms, good, ok) when is_integer(ms) do
    cond do
      ms <= good -> "bg-emerald-50"
      ms <= ok -> "bg-amber-50"
      true -> "bg-rose-50"
    end
  end

  defp perf_class(_, _, _), do: "bg-gray-100"

  defp page_weight_class(b) when is_integer(b) do
    cond do
      b > 5_000_000 -> "bg-rose-50"
      b > 3_000_000 -> "bg-amber-50"
      b > 0 -> "bg-emerald-50"
      true -> "bg-gray-100"
    end
  end

  defp page_weight_class(_), do: "bg-gray-100"

  defp request_count_class(n) when is_integer(n) do
    cond do
      n > 100 -> "bg-amber-50"
      n > 0 -> "bg-emerald-50"
      true -> "bg-gray-100"
    end
  end

  defp request_count_class(_), do: "bg-gray-100"

  defp resource_type_class("script"), do: "bg-amber-100 text-amber-800"
  defp resource_type_class("css"), do: "bg-blue-100 text-blue-800"
  defp resource_type_class("link"), do: "bg-blue-100 text-blue-800"
  defp resource_type_class("img"), do: "bg-emerald-100 text-emerald-800"
  defp resource_type_class("image"), do: "bg-emerald-100 text-emerald-800"
  defp resource_type_class("font"), do: "bg-purple-100 text-purple-800"
  defp resource_type_class("xmlhttprequest"), do: "bg-indigo-100 text-indigo-800"
  defp resource_type_class("fetch"), do: "bg-indigo-100 text-indigo-800"
  defp resource_type_class(_), do: "bg-gray-100 text-gray-700"

  defp short_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: h, path: p} when is_binary(p) ->
        "#{h || ""}#{String.slice(p, 0, 80)}"

      _ ->
        String.slice(url, 0, 100)
    end
  end

  defp short_url(_), do: ""

  defp length_str(nil), do: "—"
  defp length_str(""), do: "—"
  defp length_str(s) when is_binary(s), do: "#{String.length(s)} chars"
  defp length_str(_), do: "—"

  defp schema_types_str([]), do: "—"
  defp schema_types_str(nil), do: "—"
  defp schema_types_str(list) when is_list(list), do: Enum.join(list, ", ")
  defp schema_types_str(_), do: "—"

  defp alt_pct(%{image_count: ic, image_alt_count: ac}) when is_integer(ic) and ic > 0 do
    "#{round(ac / ic * 100)}% (#{ac}/#{ic})"
  end

  defp alt_pct(_), do: "—"

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp format_value(v), do: v
end
