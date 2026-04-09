defmodule SpectabasWeb.DocsLive do
  use SpectabasWeb, :live_view

  @category_slugs %{
    "getting-started" => "Getting Started",
    "dashboard" => "Dashboard",
    "conversions" => "Conversions",
    "api" => "REST API",
    "admin" => "Administration"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:search, "")
     |> assign(:active_section, nil)
     |> assign(:all_sections, sections())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    category_slug = params["category"]

    if category_slug do
      category_name = @category_slugs[category_slug]

      visible =
        Enum.filter(sections(), &(&1.category == category_name))

      first_id =
        case visible do
          [%{items: [%{id: id} | _]} | _] -> id
          _ -> nil
        end

      {:noreply,
       socket
       |> assign(:page_title, "Docs: #{category_name || category_slug}")
       |> assign(:category_slug, category_slug)
       |> assign(:sections, visible)
       |> assign(:filtered_sections, visible)
       |> assign(:active_section, socket.assigns.active_section || first_id)}
    else
      {:noreply,
       socket
       |> assign(:page_title, "Documentation")
       |> assign(:category_slug, nil)
       |> assign(:sections, sections())
       |> assign(:filtered_sections, sections())
       |> assign(:active_section, socket.assigns.active_section || "getting-started")}
    end
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket), do: do_search(query, socket)
  def handle_event("search", %{"value" => query}, socket), do: do_search(query, socket)

  def handle_event("nav", %{"section" => section}, socket) do
    {:noreply,
     socket
     |> assign(:active_section, section)
     |> push_event("scroll-to", %{id: section})}
  end

  defp do_search(query, socket) do
    q = String.downcase(String.trim(query))
    # Always search all sections, even on index page
    all = socket.assigns.all_sections

    filtered =
      if q == "" do
        socket.assigns.sections
      else
        all
        |> Enum.map(fn section ->
          matching_items =
            Enum.filter(section.items, fn item ->
              String.contains?(String.downcase(item.title), q) ||
                String.contains?(String.downcase(item.body), q)
            end)

          %{section | items: matching_items}
        end)
        |> Enum.reject(&(&1.items == []))
      end

    {:noreply, socket |> assign(:search, query) |> assign(:filtered_sections, filtered)}
  end

  defp category_slug_for(category_name) do
    Enum.find_value(@category_slugs, "getting-started", fn {slug, name} ->
      if name == category_name, do: slug
    end)
  end

  defp category_description("Getting Started"),
    do: "Installation, tracker setup, and JavaScript API reference."

  defp category_description("Dashboard"),
    do: "All analytics pages: pages, sources, geography, devices, visitors, and more."

  defp category_description("Conversions"),
    do: "Goals, funnels, revenue attribution, ROAS, ad integrations, buyer patterns."

  defp category_description("REST API"),
    do: "Authentication, endpoints for stats, ecommerce, visitor identification."

  defp category_description("Administration"),
    do: "Site settings, user roles, email reports, spam filtering, 2FA."

  defp category_description(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-56px)]">
      <%!-- Sidebar (only on category pages) --%>
      <aside
        :if={@category_slug}
        class="hidden lg:flex lg:flex-col lg:w-64 bg-white border-r border-gray-200 flex-shrink-0"
      >
        <div class="p-4 border-b border-gray-200">
          <.link navigate={~p"/docs"} class="text-xs text-indigo-600 hover:text-indigo-800">
            &larr; All Docs
          </.link>
          <h2 class="text-sm font-semibold text-gray-900 mt-1">
            {@filtered_sections |> List.first(%{}) |> Map.get(:category, "Documentation")}
          </h2>
        </div>
        <nav class="flex-1 p-3 overflow-y-auto space-y-1">
          <div :for={section <- @filtered_sections}>
            <button
              :for={item <- section.items}
              phx-click="nav"
              phx-value-section={item.id}
              class={[
                "block w-full text-left px-2 py-1 text-sm rounded-md",
                if(@active_section == item.id,
                  do: "bg-indigo-50 text-indigo-700 font-medium",
                  else: "text-gray-600 hover:bg-gray-50"
                )
              ]}
            >
              {item.title}
            </button>
          </div>
        </nav>
      </aside>

      <%!-- Content --%>
      <main class="flex-1 overflow-y-auto bg-gray-50">
        <div class="max-w-4xl mx-auto px-6 py-8">
          <%!-- Search bar --%>
          <div class="mb-8">
            <input
              type="text"
              phx-keyup="search"
              phx-debounce="200"
              name="q"
              value={@search}
              placeholder="Search all documentation..."
              class="block w-full rounded-lg border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500 py-2.5 px-4"
            />
            <p :if={@search != "" && @filtered_sections == []} class="text-sm text-gray-500 mt-3">
              No results for "{@search}"
            </p>
          </div>

          <%!-- Search results (cross-category, shown with category links) --%>
          <div :if={@search != "" && !@category_slug}>
            <div :for={section <- @filtered_sections}>
              <div :for={item <- section.items}>
                <.link
                  navigate={"/docs/#{category_slug_for(section.category)}##{item.id}"}
                  class="block mb-4 bg-white rounded-lg shadow-sm border border-gray-200 p-4 hover:border-indigo-300 transition-colors"
                >
                  <h3 class="font-semibold text-gray-900">{item.title}</h3>
                  <p class="text-xs text-indigo-600 mt-0.5">{section.category}</p>
                </.link>
              </div>
            </div>
          </div>

          <%!-- Index: category cards (when not searching) --%>
          <div :if={!@category_slug && @search == ""}>
            <h1 class="text-2xl font-bold text-gray-900 mb-2">Documentation</h1>
            <p class="text-sm text-gray-500 mb-8">
              Choose a section to get started, or search above.
            </p>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.link
                :for={
                  {slug, name} <- [
                    {"getting-started", "Getting Started"},
                    {"dashboard", "Dashboard"},
                    {"conversions", "Conversions"},
                    {"api", "REST API"},
                    {"admin", "Administration"}
                  ]
                }
                navigate={~p"/docs/#{slug}"}
                class="bg-white rounded-lg shadow-sm border border-gray-200 p-6 hover:border-indigo-300 hover:shadow transition-all"
              >
                <h2 class="text-lg font-semibold text-gray-900">{name}</h2>
                <p class="text-sm text-gray-500 mt-1">
                  {category_description(name)}
                </p>
                <p class="text-xs text-indigo-600 mt-3">
                  {Enum.find(@all_sections, %{items: []}, &(&1.category == name)).items |> length()} articles &rarr;
                </p>
              </.link>
            </div>
          </div>

          <%!-- Category content --%>
          <div :if={@category_slug}>
            <%!-- Mobile: jump-to-section --%>
            <div :if={@search == ""} class="lg:hidden mb-6">
              <.link
                navigate={~p"/docs"}
                class="text-xs text-indigo-600 hover:text-indigo-800 mb-2 block"
              >
                &larr; All Docs
              </.link>
              <select
                phx-change="nav"
                name="section"
                class="block w-full rounded-lg border-gray-300 text-sm py-2.5 focus:border-indigo-500 focus:ring-indigo-500"
              >
                <option value="" disabled selected>Jump to section...</option>
                <%= for section <- @filtered_sections do %>
                  <optgroup label={section.category}>
                    <%= for item <- section.items do %>
                      <option value={item.id}>{item.title}</option>
                    <% end %>
                  </optgroup>
                <% end %>
              </select>
            </div>

            <div :for={section <- @filtered_sections}>
              <div :for={item <- section.items}>
                <article id={item.id} class="mb-12 scroll-mt-8">
                  <h2 class="text-2xl font-bold text-gray-900 mb-1">{item.title}</h2>
                  <p class="text-xs text-gray-500 uppercase mb-4">{section.category}</p>
                  <div class="prose prose-sm prose-indigo max-w-none">
                    <div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
                      {raw(render_markdown(item.body))}
                    </div>
                  </div>
                </article>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @doc false
  # Public for testing
  def render_markdown_public(text), do: render_markdown(text)

  # Simple markdown-ish rendering (no external dep)
  # First extracts fenced code blocks (which may contain blank lines),
  # then splits remaining text on blank lines for block-level parsing.
  defp render_markdown(text) do
    text
    |> extract_blocks()
    |> Enum.map(&render_block/1)
    |> Enum.join("\n")
  end

  # Split text into blocks, preserving fenced code blocks intact
  defp extract_blocks(text) do
    # Split all lines and walk them, grouping fenced code blocks
    lines = String.split(text, "\n")

    {blocks, current, in_code} =
      Enum.reduce(lines, {[], [], false}, fn line, {blocks, current, in_code} ->
        trimmed = String.trim(line)

        cond do
          # Opening code fence
          !in_code && String.starts_with?(trimmed, "```") ->
            # Flush any accumulated non-code lines as separate blocks
            blocks = flush_text_blocks(blocks, current)
            {blocks, [line], true}

          # Closing code fence
          in_code && trimmed == "```" ->
            code_block = Enum.reverse([line | current]) |> Enum.join("\n")
            {[code_block | blocks], [], false}

          # Inside code fence — accumulate (even blank lines)
          in_code ->
            {blocks, [line | current], true}

          # Blank line outside code — flush current block
          trimmed == "" ->
            blocks = flush_text_blocks(blocks, current)
            {blocks, [], false}

          # Normal line — accumulate
          true ->
            {blocks, [line | current], false}
        end
      end)

    # Flush any remaining lines (handles unclosed code blocks too)
    blocks = flush_text_blocks(blocks, current)
    _ = in_code

    Enum.reverse(blocks)
  end

  defp flush_text_blocks(blocks, []), do: blocks

  defp flush_text_blocks(blocks, lines) do
    block = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    if block == "", do: blocks, else: [block | blocks]
  end

  defp render_block(block) do
    block = String.trim(block)

    cond do
      String.starts_with?(block, "### ") ->
        "<h4 class=\"text-base font-semibold text-gray-900 mt-6 mb-2\">#{render_inline(escape(String.trim_leading(block, "### ")))}</h4>"

      String.starts_with?(block, "## ") ->
        "<h3 class=\"text-lg font-semibold text-gray-900 mt-6 mb-2\">#{render_inline(escape(String.trim_leading(block, "## ")))}</h3>"

      String.starts_with?(block, "```") ->
        # Extract code: strip opening/closing fences and language tag
        lines = String.split(block, "\n")
        # First line is ```language, last line is ```
        inner = lines |> Enum.drop(1) |> Enum.drop(-1)
        # Strip common leading whitespace (heredoc indentation)
        code = dedent(inner)
        code_id = "code-#{:erlang.phash2(code)}"

        """
        <div class="relative my-3">
          <pre class="bg-gray-900 text-gray-100 rounded-lg p-4 pr-16 text-xs overflow-x-auto"><code id="#{code_id}">#{escape(code)}</code></pre>
          <button onclick="navigator.clipboard.writeText(document.getElementById('#{code_id}').textContent);this.textContent='Copied!';setTimeout(()=>this.textContent='Copy',1500)" class="absolute top-2 right-2 px-2 py-1 bg-gray-700 text-gray-300 rounded text-xs hover:bg-gray-600 hover:text-white">Copy</button>
        </div>
        """

      String.starts_with?(block, "- ") ->
        items =
          block
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn line ->
            "<li class=\"ml-4\">#{render_inline(escape(String.trim_leading(line, "- ")))}</li>"
          end)
          |> Enum.join()

        "<ul class=\"list-disc space-y-1 my-2 text-gray-700\">#{items}</ul>"

      Regex.match?(~r/^\d+\.\s/, block) ->
        items =
          block
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn line ->
            text = Regex.replace(~r/^\d+\.\s+/, line, "")
            "<li class=\"ml-4\">#{render_inline(escape(text))}</li>"
          end)
          |> Enum.join()

        "<ol class=\"list-decimal space-y-1 my-2 text-gray-700 pl-4\">#{items}</ol>"

      String.starts_with?(block, "| ") ->
        render_table(block)

      String.starts_with?(block, "> ") ->
        content =
          block
          |> String.split("\n")
          |> Enum.map(fn line ->
            line |> String.trim() |> String.trim_leading("> ") |> escape() |> render_inline()
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("<br/>")

        "<div class=\"border-l-4 border-indigo-400 bg-indigo-50 px-4 py-3 my-3 text-sm text-indigo-800\">#{content}</div>"

      block == "---" ->
        "<hr class=\"my-6 border-gray-200\" />"

      true ->
        text = block |> escape() |> render_inline()
        "<p class=\"text-gray-700 my-2 leading-relaxed\">#{text}</p>"
    end
  end

  defp render_inline(text) do
    text
    |> String.replace(
      ~r/`([^`]+)`/,
      "<code class=\"bg-gray-100 text-indigo-700 px-1 py-0.5 rounded text-xs font-mono\">\\1</code>"
    )
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> render_links()
  end

  # Render markdown links: [text](url) — external links open in new tab
  defp render_links(text) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, text, fn _, label, url ->
      if String.starts_with?(url, "http") do
        "<a href=\"#{url}\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"text-indigo-600 hover:text-indigo-800 underline\">#{label}</a>"
      else
        "<a href=\"#{url}\" class=\"text-indigo-600 hover:text-indigo-800 underline\">#{label}</a>"
      end
    end)
  end

  defp render_table(block) do
    rows =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn row -> String.starts_with?(row, "|-") || row == "" end)

    [header | body] = rows

    header_cells =
      header |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    header_html =
      Enum.map(
        header_cells,
        &"<th class=\"px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-gray-50\">#{render_inline(escape(&1))}</th>"
      )
      |> Enum.join()

    body_html =
      Enum.map(body, fn row ->
        cells = row |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        tds =
          Enum.map(
            cells,
            &"<td class=\"px-3 py-2 text-sm text-gray-700\">#{render_inline(escape(&1))}</td>"
          )
          |> Enum.join()

        "<tr class=\"border-t border-gray-100\">#{tds}</tr>"
      end)
      |> Enum.join()

    "<table class=\"min-w-full divide-y divide-gray-200 my-3 rounded-lg overflow-hidden\"><thead><tr>#{header_html}</tr></thead><tbody>#{body_html}</tbody></table>"
  end

  # Strip common leading whitespace from code block lines
  defp dedent(lines) do
    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line ->
        String.length(line) - String.length(String.trim_leading(line))
      end)
      |> Enum.min(fn -> 0 end)

    lines
    |> Enum.map(fn line ->
      if String.trim(line) == "", do: "", else: String.slice(line, min_indent..-1//1)
    end)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ---- Documentation Content ----

  defp sections do
    [
      %{
        category: "Getting Started",
        items: [
          %{
            id: "getting-started",
            title: "Quick Start Guide",
            body: """
            Welcome to Spectabas, a privacy-first web analytics platform. This guide will help you get up and running in minutes.

            ## Step 1: Create a Site

            Go to **Admin > Sites** and click **New Site**. Enter:

            - **Site Name** — a friendly name (e.g., "My Blog")
            - **Domain** — your analytics subdomain (e.g., `b.example.com`)
            - **Timezone** — your site's timezone for accurate hourly charts
            - **GDPR Mode** — "off" for cookie-based tracking, "on" for fingerprint-based

            ## Step 2: Set Up DNS

            Add a CNAME record pointing your analytics subdomain to `www.spectabas.com`:

            ```
            b.example.com  CNAME  www.spectabas.com
            ```

            If using Cloudflare, keep the proxy **off** (gray cloud) for the analytics subdomain.

            ## Step 3: Install the Tracker

            Add this snippet to your website's `<head>` tag. You'll find the exact code in **Site Settings > Tracking Snippet**.

            ```html
            <script defer data-id="YOUR_PUBLIC_KEY" src="https://b.example.com/assets/v1.js"></script>
            ```

            ### Example Placement

            ```html
            <!DOCTYPE html>
            <html>
              <head>
                <meta charset="utf-8">
                <title>Your Website</title>

                <!-- Spectabas Analytics -->
                <script defer data-id="YOUR_PUBLIC_KEY"
                  src="https://b.example.com/assets/v1.js"></script>
              </head>
              <body>
                ...
              </body>
            </html>
            ```

            The script loads asynchronously and won't slow down your page. If you use a CMS or site builder, look for a "Custom HTML" or "Header Scripts" setting.

            That's it! Pageviews will start appearing in your dashboard within seconds.

            > **Tip:** The tracker is only 8KB, loads asynchronously, and is designed to avoid ad blockers. For maximum evasion, use the [Cloudflare Worker proxy](#ad-blocker-evasion).
            """
          },
          %{
            id: "tracker-config",
            title: "Tracker Configuration",
            body: """
            The tracking script accepts several `data-` attributes for configuration:

            | Attribute | Values | Default | Description |
            |-----------|--------|---------|-------------|
            | `data-id` | string | required | Your site's public key |
            | `data-gdpr` | "on" / "off" | "off" | GDPR mode (on = fingerprint, off = cookie) |
            | `data-xd` | comma-separated domains | "" | Cross-domain tracking domains |

            ### GDPR Mode

            **GDPR Off (default):** Uses cookies for accurate visitor identification and UTM persistence. Most sites should use this mode.

            **GDPR On:** Add `data-gdpr="on"` to use fingerprint-only identification (hash of UA + screen + timezone + language) instead of cookies. No consent banner needed. IP addresses are anonymized before storage. Tracking parameters (utm, gclid, etc.) are stripped from URLs.

            **GDPR Off:** Uses a persistent cookie (`_sab`, 2-year lifetime) for more accurate visitor identification. Requires user consent in EU/UK. Full IP addresses stored. UTM parameters preserved in session storage.

            ```html
            <!-- GDPR-compliant (no cookies) -->
            <script defer data-id="KEY" src="https://b.example.com/assets/v1.js"></script>

            <!-- Full tracking with cookies (requires consent) -->
            <script defer data-id="KEY" data-gdpr="off" src="https://b.example.com/assets/v1.js"></script>
            ```

            ### Browser Fingerprinting

            Spectabas generates a browser fingerprint for each visitor using deterministic signals — no random identifiers or tracking cookies involved. The fingerprint is used for:

            - **GDPR-on mode:** The fingerprint IS the visitor identifier (no cookies set)
            - **GDPR-off mode:** Used for cross-referencing on visitor profiles (cookies handle primary identification)

            **Signals collected** (all client-side, no network requests):

            | Signal | Purpose |
            |--------|---------|
            | Browser family + major version | Stable across minor updates |
            | Screen dimensions + color depth | Hardware display characteristics |
            | Device pixel ratio | Retina/HiDPI detection |
            | Timezone + language | Regional settings |
            | Hardware concurrency + device memory | CPU/RAM fingerprint |
            | Touch points + platform | Device type identification |
            | Canvas rendering | GPU-specific pixel output from text + shapes |
            | WebGL renderer + parameters | GPU model, driver limits, extension count |
            | AudioContext parameters | Audio processing characteristics |
            | Font availability | Installed font detection via width measurement |

            The signals are hashed with MurmurHash3 using two seeds to produce a 64-bit fingerprint (collision probability ~50% at 5 billion visitors).

            **Limitations:** Visitors on identical hardware, OS, and browser (e.g., two iPhone 15s on iOS 18 Safari) will produce the same fingerprint. This is inherent to deterministic fingerprinting — it identifies device configurations, not individual people. The visitor profile page accounts for this by showing a "common device" note when more than 10 visitors share a fingerprint, rather than listing them as potential alt accounts.

            > **Privacy:** The fingerprint never leaves the browser as raw signals. Only the hash is transmitted. In GDPR-on mode, IP addresses are also anonymized before storage.

            ### Cross-Domain Tracking

            To track visitors across multiple domains as one session:

            ```html
            <script defer data-id="KEY" data-gdpr="off" data-xd="shop.example.com,blog.example.com" src="https://b.example.com/assets/v1.js"></script>
            ```

            This passes a temporary token via URL parameter (`_sabt`) when visitors click links between your domains. Only works with GDPR mode off.
            """
          },
          %{
            id: "ad-blocker-evasion",
            title: "Ad Blocker Evasion (Reverse Proxy)",
            body: """
            By default, your tracking script loads from `b.yourdomain.com` — a dedicated analytics subdomain. Most ad blockers don't target custom subdomains, but strict blocklists (like uBlock Origin in hard mode) can detect the pattern.

            The reverse proxy approach serves the tracker and beacons from **your main domain** (e.g., `www.yourdomain.com/t/...`), making them completely indistinguishable from your own application code. No ad blocker can detect this without blocking your entire site.

            ### How It Works

            | Visitor requests | Proxied to Spectabas |
            |------------------|----------------------|
            | `www.yourdomain.com/t/v1.js` | `www.spectabas.com/assets/v1.js` |
            | `www.yourdomain.com/t/c/e` | `www.spectabas.com/c/e` |
            | `www.yourdomain.com/t/c/i` | `www.spectabas.com/c/i` |
            | `www.yourdomain.com/t/c/*` | `www.spectabas.com/c/*` |

            ### Choose Your Proxy Method

            There are two approaches depending on your infrastructure:

            ---

            ### Option A: Cloudflare Worker (Recommended)

            **Use this if your site is behind Cloudflare.** This is the simplest and most reliable method — no application code changes needed, works across any hosting region, and Cloudflare-to-Render traffic is trusted (no firewall blocks).

            **Step 1: Create the Worker**

            1. In your Cloudflare dashboard, go to **Workers & Pages** in the left sidebar
            2. Click **Create** (blue button, top right)
            3. Click **Create Worker**
            4. Name it something like `analytics-proxy`
            5. Click **Deploy** to create it with the default "Hello World" code
            6. After deploy, click **Edit Code** (top right)
            7. Replace the entire contents with the code below and click **Deploy**

            ```javascript
            export default {
              async fetch(request) {
                const url = new URL(request.url);

                // Proxy tracker script
                if (url.pathname === '/t/v1.js') {
                  const resp = await fetch('https://www.spectabas.com/assets/v1.js');
                  return new Response(resp.body, {
                    headers: {
                      'content-type': 'application/javascript',
                      'cache-control': 'public, max-age=3600'
                    }
                  });
                }

                // Proxy beacon endpoints (/t/c/e, /t/c/p, /t/c/i, etc.)
                if (url.pathname.startsWith('/t/c/')) {
                  const target = 'https://www.spectabas.com'
                    + url.pathname.replace('/t', '') + url.search;
                  const resp = await fetch(target, {
                    method: request.method,
                    body: request.method === 'POST' ? request.body : undefined,
                    headers: {
                      'content-type': 'application/json',
                      'x-spectabas-real-ip': request.headers.get('cf-connecting-ip') || '',
                      'x-forwarded-for': request.headers.get('cf-connecting-ip') || '',
                      'user-agent': request.headers.get('user-agent') || ''
                    }
                  });
                  return new Response(resp.body, { status: resp.status });
                }

                // Everything else passes through to your origin server
                return fetch(request);
              }
            }
            ```

            **Step 2: Add a Route to Your Domain**

            The Worker needs to know which URLs to intercept. You do this by adding a route:

            1. Go to your Worker's page (click on the worker name in Workers & Pages)
            2. Click the **Settings** tab at the top
            3. Scroll down to **Domains & Routes**
            4. Click the **Add** button (blue "+" button)
            5. Choose **Route** (not Custom Domain)
            6. Enter:
               - **Route:** `www.yourdomain.com/t/*`
               - **Zone:** select your domain from the dropdown
               - **Failure mode:** leave as "Fail open" (if the worker errors, requests pass through normally)
            7. Click **Add Route**

            > **Important:** The route must match your main website domain exactly — e.g., `www.roommates.com/t/*` or `roommates.com/t/*` depending on which version your site uses. If your site uses both `www` and non-www, add a route for each.

            **Step 3: Update Your Tracking Snippet**

            Replace your existing tracking snippet with the proxy version. You can find the ready-to-copy proxy snippet in **Site Settings > Tracking Snippet > Proxy mode (Cloudflare)**.

            ```html
            <script defer data-id="YOUR_KEY"
              data-proxy="https://www.yourdomain.com/t"
              src="https://www.yourdomain.com/t/v1.js"></script>
            ```

            The `data-proxy` attribute tells the tracker to send beacons to `/t/c/e` instead of the analytics subdomain. The `src` loads the script from `/t/v1.js` which the Worker proxies from Spectabas.

            **Step 4: Verify It's Working**

            1. Open your website in a browser
            2. Open the Network tab in DevTools (F12)
            3. Filter for `v1.js` — it should load from `www.yourdomain.com/t/v1.js` (not `b.yourdomain.com`)
            4. Navigate to a page — you should see a POST to `www.yourdomain.com/t/c/e`
            5. Check your Spectabas dashboard — pageviews should appear within seconds

            > **Tip:** After enabling the proxy, you can keep both snippets (direct and proxy) during a transition period. Once you've verified the proxy is working, remove the direct snippet.

            ### Troubleshooting

            - **403 errors on `/t/c/e`:** If you have Cloudflare **Bot Fight Mode** enabled (Security > Bots), it will block `sendBeacon` POST requests because they can't solve JS challenges. Fix: go to **Security > WAF > Custom Rules**, create a new rule with expression `(http.request.uri.path matches "^/t/")` and action **Skip** (skip all remaining rules). This lets tracking beacons through while keeping bot protection on all other paths.

            - **Worker not triggering:** Make sure the route zone matches your domain and the route pattern includes the `/*` wildcard. Test by visiting `www.yourdomain.com/t/v1.js` directly in your browser — you should see JavaScript code.

            - **No data in dashboard:** Check that `data-id` matches your site's public key (found in Site Settings). Also verify the Worker is deployed (not still showing "Hello World").

            - **IP geolocation wrong:** The Worker forwards `cf-connecting-ip` as `x-spectabas-real-ip`. If geo data shows Cloudflare's IP location instead of the visitor's, check that the header forwarding code in the Worker matches exactly as shown above.

            > **Why Cloudflare Worker?** Server-to-server proxies (e.g., a Phoenix plug or Nginx upstream) can be blocked by Render's built-in Cloudflare DDoS protection, which returns 403 "error code: 1000" for non-browser POST requests. Cloudflare Worker requests come from Cloudflare's own IP range, which is trusted by Render's edge.

            ---

            ### Option B: Application-Level Proxy (Phoenix/Elixir)

            **Use this if your site is NOT behind Cloudflare** and is hosted on Render in the **same region** as Spectabas (Ohio). If in different regions, use Option A instead.

            This approach adds a plug to your Phoenix application that intercepts `/t/*` requests and forwards them to Spectabas via Render's private network.

            **Step 1: Create the proxy plug**

            Create `lib/your_app_web/plugs/analytics_proxy.ex`:

            ```elixir
            defmodule YourAppWeb.Plugs.AnalyticsProxy do
              import Plug.Conn

              # Use Render private network (same region only):
              @analytics_host "http://SERVICE_ID.internal:10000"
              # Or public URL if same region is not available:
              # @analytics_host "https://www.spectabas.com"

              def init(opts), do: opts

              def call(%{request_path: "/t/v1.js"} = conn, _opts) do
                proxy_get(conn, @analytics_host <> "/assets/v1.js")
              end

              def call(%{request_path: "/t/c/" <> rest} = conn, _opts) do
                target = @analytics_host <> "/c/" <> rest
                qs = conn.query_string
                url = if qs != "", do: target <> "?" <> qs, else: target
                case conn.method do
                  "GET" -> proxy_get(conn, url)
                  "POST" -> proxy_post(conn, url)
                  _ -> conn |> send_resp(405, "") |> halt()
                end
              end

              def call(conn, _opts), do: conn

              defp proxy_get(conn, url) do
                case Req.get(url) do
                  {:ok, %{status: status, body: body}} ->
                    conn
                    |> put_resp_content_type("application/javascript")
                    |> put_resp_header("cache-control", "public, max-age=3600")
                    |> send_resp(status, body)
                    |> halt()
                  _ -> conn |> send_resp(502, "") |> halt()
                end
              end

              defp proxy_post(conn, url) do
                {:ok, body, conn} = read_body(conn)
                client_ip =
                  (get_req_header(conn, "cf-connecting-ip") |> List.first())
                  || (get_req_header(conn, "x-forwarded-for") |> List.first())
                  || (:inet.ntoa(conn.remote_ip) |> to_string())

                case Req.post(url,
                       body: body,
                       headers: [
                         {"content-type", "application/json"},
                         {"x-spectabas-real-ip", client_ip},
                         {"x-forwarded-for", client_ip},
                         {"user-agent", get_req_header(conn, "user-agent") |> List.first() || ""}
                       ]) do
                  {:ok, %{status: status, body: resp_body}} ->
                    conn |> send_resp(status, resp_body || "") |> halt()
                  _ -> conn |> send_resp(502, "") |> halt()
                end
              end
            end
            ```

            **Step 2: Add to endpoint.ex** (BEFORE `Plug.Parsers`):

            ```elixir
            plug YourAppWeb.Plugs.AnalyticsProxy
            plug Plug.Parsers, ...
            ```

            **Step 3: Update tracking snippet** (same as Option A):

            ```html
            <script defer data-id="YOUR_KEY"
              data-proxy="https://www.yourdomain.com/t"
              src="https://www.yourdomain.com/t/v1.js"></script>
            ```

            > **Important:** The plug MUST be in `endpoint.ex` before `Plug.Parsers`, not in `router.ex`. If placed in the router, CSRF protection returns 403 and `Plug.Parsers` consumes the request body before the proxy can read it.

            > **Same-region requirement:** Render's private network (`SERVICE_ID.internal:10000`) only works between services in the same region. If your app is in a different region than Spectabas, requests to the public URL (`www.spectabas.com`) may be blocked by Render's Cloudflare layer with "error code: 1000". Use the Cloudflare Worker approach (Option A) instead.

            > **Req dependency:** Add `{:req, "~> 0.5"}` to your `mix.exs` deps if not already present.

            ### Data Accuracy

            Both proxy methods preserve all tracking data:

            | Data Point | How It's Preserved |
            |------------|-------------------|
            | **Client IP** | `X-Spectabas-Real-IP` header carries the real visitor IP through to Spectabas for geo enrichment |
            | **User Agent** | Forwarded in the `User-Agent` header for browser/OS/device detection |
            | **Cookies** | Set by the tracker JS on the page domain (not the script origin) — no migration needed |
            | **Click IDs** | Captured by the tracker JS from the URL — unaffected by proxy |
            | **Origin validation** | Proxy requests have no Origin/Referer headers — Spectabas allows these automatically |

            ### Choosing Between Proxy and CNAME

            | | CNAME (default) | Reverse Proxy |
            |---|---|---|
            | **Setup** | DNS record only | Cloudflare Worker or Phoenix plug |
            | **Ad blocker resistance** | Good (custom subdomain) | Excellent (same-origin, undetectable) |
            | **Strict blocklists** | Can be blocked | Cannot be blocked |
            | **Maintenance** | None | Minimal (Worker is set-and-forget) |
            | **Latency** | Direct | +1-5ms (Worker) or +10-50ms (Phoenix proxy) |

            For most sites, the CNAME approach works fine. Use the reverse proxy only if you're seeing significant traffic loss from ad blockers.
            """
          },
          %{
            id: "js-api",
            title: "JavaScript API",
            body: """
            The tracker exposes a global `window.Spectabas` object with methods for custom event tracking, visitor identification, opt-out, and ecommerce. The API is available immediately after the tracker script loads.

            All methods are fire-and-forget — they send data via `navigator.sendBeacon` (with `fetch` fallback) and never block your page. Payloads over 8KB are silently dropped.

            ---

            ### `Spectabas.track(name, props, opts)`

            Send a custom event. Custom events appear in your dashboard under **Goals** and can be used in **Funnels**.

            | Parameter | Type | Required | Description |
            |-----------|------|----------|-------------|
            | `name` | string | yes | Event name. Use lowercase with underscores (e.g. `signup_complete`). Names starting with `_` are reserved for internal events. |
            | `props` | object | no | Key-value pairs of string properties. All values are converted to strings server-side. Max 20 properties per event. |
            | `opts` | object | no | Options. `{ occurred_at: unixTimestamp }` to backdate the event (UTC seconds, must be within 7 days). |

            ```javascript
            // Basic event
            Spectabas.track("signup");

            // Event with properties
            Spectabas.track("signup", { plan: "pro", source: "pricing_page" });

            // Track a button click
            document.querySelector("#cta").addEventListener("click", function() {
              Spectabas.track("cta_click", { location: "header" });
            });

            // Track form submission
            document.querySelector("#contact-form").addEventListener("submit", function() {
              Spectabas.track("form_submit", {
                form: "contact",
                page: window.location.pathname
              });
            });

            // Track file downloads
            document.querySelectorAll("a[href$='.pdf']").forEach(function(link) {
              link.addEventListener("click", function() {
                Spectabas.track("download", { file: link.href });
              });
            });

            // Backdate an event (e.g. queued from offline)
            Spectabas.track("purchase", { plan: "pro" }, {
              occurred_at: Math.floor(Date.now() / 1000) - 3600 // 1 hour ago
            });
            ```

            ---

            ### `Spectabas.identify(traits)`

            Associate the current visitor with user traits. Traits are stored on the visitor record and visible in the **Visitor Log** and **Visitor Profile** pages. Call this after a user logs in or when you know who they are.

            | Parameter | Type | Required | Description |
            |-----------|------|----------|-------------|
            | `traits` | object | yes | Key-value pairs describing the visitor. Common keys: `email`, `user_id`, `name`, `plan`, `company`. All values are converted to strings. |

            ```javascript
            // After user logs in
            Spectabas.identify({
              email: "jane@example.com",
              user_id: "usr_123",
              plan: "enterprise"
            });

            // Identify with any custom traits
            Spectabas.identify({
              user_id: "usr_456",
              company: "Acme Inc",
              role: "admin",
              signup_date: "2026-01-15"
            });
            ```

            > **Privacy note:** Identify data is sent to your Spectabas analytics subdomain only — never to third parties. In GDPR-on mode, consider whether identifying visitors aligns with your privacy policy.

            ---

            ### `Spectabas.optOut()`

            Opt the current visitor out of all tracking. Sets a `_sab_optout` cookie (2-year expiry) that prevents the tracker from sending any events on future page loads. No data is sent after calling this method.

            ```javascript
            // Add to your privacy settings / cookie banner
            document.querySelector("#opt-out-btn").addEventListener("click", function() {
              Spectabas.optOut();
              alert("You have been opted out of analytics.");
            });
            ```

            To check if a visitor is opted out (e.g. to update UI state):

            ```javascript
            var isOptedOut = document.cookie.indexOf("_sab_optout") !== -1;
            ```

            > **Note:** There is no `optIn()` method. To reverse an opt-out, delete the `_sab_optout` cookie.

            ---

            ### `Spectabas.ecommerce.addOrder(order, opts)`

            Track a completed order. Order data appears in the **Ecommerce** dashboard with a revenue/orders chart, revenue totals, average order value, top products, and recent orders. A summary also appears on the main site dashboard.

            | Property | Type | Required | Description |
            |----------|------|----------|-------------|
            | `order_id` | string | yes | Unique order identifier. Duplicate order IDs are deduplicated. |
            | `revenue` | string | yes | Total order value (e.g. `"99.99"`). Use strings to avoid floating-point issues. |
            | `currency` | string | no | ISO 4217 currency code (e.g. `"USD"`, `"EUR"`). Defaults to site currency. |
            | `opts.occurred_at` | integer | no | Unix UTC timestamp to backdate the order (must be within 7 days). |

            ```javascript
            Spectabas.ecommerce.addOrder({
              order_id: "ORD-123",
              revenue: "149.98",
              currency: "USD"
            });

            // Backdate an order (e.g. processing a delayed webhook)
            Spectabas.ecommerce.addOrder({
              order_id: "ORD-456",
              revenue: "79.99"
            }, { occurred_at: 1711900000 });
            ```

            ---

            ### `Spectabas.ecommerce.addItem(item)`

            Track an individual line item within an order. Call once per item, after `addOrder`.

            | Property | Type | Required | Description |
            |----------|------|----------|-------------|
            | `order_id` | string | yes | Must match the `order_id` from `addOrder`. |
            | `sku` | string | yes | Product SKU or identifier. |
            | `name` | string | yes | Product display name. |
            | `price` | string | yes | Unit price as a string (e.g. `"49.99"`). |
            | `quantity` | string | no | Number of units. Defaults to `"1"`. |
            | `category` | string | no | Product category (e.g. `"Widgets"`). |

            ```javascript
            // Track each item in the order
            Spectabas.ecommerce.addItem({
              order_id: "ORD-123",
              sku: "WIDGET-BLUE",
              name: "Blue Widget",
              price: "49.99",
              quantity: "2",
              category: "Widgets"
            });

            Spectabas.ecommerce.addItem({
              order_id: "ORD-123",
              sku: "WIDGET-RED",
              name: "Red Widget",
              price: "49.99",
              quantity: "1",
              category: "Widgets"
            });
            ```

            **Full checkout example:**

            ```javascript
            // On your order confirmation / thank-you page:
            var orderId = "ORD-" + Date.now();

            Spectabas.ecommerce.addOrder({
              order_id: orderId,
              revenue: "149.97",
              currency: "USD"
            });

            cart.items.forEach(function(item) {
              Spectabas.ecommerce.addItem({
                order_id: orderId,
                sku: item.sku,
                name: item.name,
                price: String(item.price),
                quantity: String(item.qty),
                category: item.category  // optional: "new_subscription", "renewal", etc.
              });
            });
            ```

            ---

            ### SPA Support

            The tracker automatically detects single-page app navigation by patching `history.pushState` and listening for `popstate` events. A new pageview is fired on each route change with correct duration tracking for the previous page.

            **No additional configuration needed** for React, Vue, Next.js, Nuxt, Svelte, Angular, or any framework that uses the History API.

            ---

            ### Automatic Collection (No Code Required)

            The following data is collected automatically without any API calls:

            | What | How |
            |------|-----|
            | **Pageviews** | Sent on every page load and SPA navigation, rate-limited to 1 per URL per 5 seconds to prevent overcounting from rapid refreshes |
            | **Duration** | Time on page, sent when the tab is hidden or the user navigates away |
            | **Referrer** | `document.referrer` captured on each pageview |
            | **Screen size** | `screen.width` and `screen.height` |
            | **UTM parameters** | Extracted from URL and persisted in sessionStorage (GDPR-off only) |
            | **Site search** | Queries captured from `q`, `query`, `search`, `s`, `keyword` URL params |
            | **Outbound links** | Clicks on links to external domains |
            | **File downloads** | Clicks on links to downloadable files (PDF, ZIP, DOC, XLS, CSV, MP3, MP4, etc.) |
            | **Performance (RUM)** | Page load timing and Core Web Vitals (LCP, CLS, FID) via PerformanceObserver |
            | **Bot detection** | WebDriver, headless browser, and interaction signals |
            | **Form abuse** | Suspicious form submission patterns (rapid submits, paste floods, no interaction) |

            ---

            ### Script Attributes

            Configure the tracker via `data-` attributes on the script tag:

            | Attribute | Values | Default | Description |
            |-----------|--------|---------|-------------|
            | `data-id` | string | (required) | Your site's public key. Found in Site Settings. |
            | `data-gdpr` | `"on"` / `"off"` | `"off"` | GDPR mode. `"on"` uses fingerprint-only identification (no cookies). `"off"` enables cookie-based visitor tracking and UTM persistence. |
            | `data-xd` | comma-separated domains | (none) | Cross-domain tracking. List domains that share visitor identity (e.g. `"shop.example.com,blog.example.com"`). |

            ```html
            <!-- Minimal (cookie-based, recommended) -->
            <script defer data-id="YOUR_KEY" src="https://b.example.com/assets/v1.js"></script>

            <!-- GDPR-on (fingerprint-only, no cookies) -->
            <script defer data-id="YOUR_KEY" data-gdpr="on" src="https://b.example.com/assets/v1.js"></script>

            <!-- With cross-domain tracking -->
            <script defer data-id="YOUR_KEY"
              data-xd="shop.example.com,blog.example.com"
              src="https://b.example.com/assets/v1.js"></script>
            ```
            """
          }
        ]
      },
      %{
        category: "Dashboard",
        items: [
          %{
            id: "dashboard-overview",
            title: "Dashboard Overview",
            body: """
            The main dashboard shows a summary of your site's performance for the selected time period.

            ### Stat Cards

            The top row shows five key metrics:

            - **Pageviews** — total page loads
            - **Unique Visitors** — distinct visitor count
            - **Sessions** — unique browsing sessions
            - **Bounce Rate** — percentage of single-page sessions with no engagement
            - **Avg Duration** — average time visitors spend on your site

            When **Compare** is enabled (on by default), each card shows the percentage change vs the equivalent previous period. For example, if viewing "7d", it compares to the 7 days before that.

            ### Identified Users & Ecommerce

            If visitors have been identified (via the server-side identify API), an **Identified Users** card appears showing how many visitors have an associated email and what percentage of total visitors that represents.

            If **ecommerce tracking** is enabled for the site, additional cards appear: **Revenue**, **Orders**, and **Avg Order** with a link to the full ecommerce dashboard.

            ### Time Period

            Use the time controls to select a period:

            - **Today** — from midnight in your site's timezone to now, with hourly chart bars
            - **24h** — rolling 24-hour window from now, with hourly chart bars
            - **7d / 30d / 90d / 12m** — date ranges with daily chart bars

            All times and date boundaries use your site's configured timezone. A site set to `America/New_York` will show "today" starting at midnight Eastern, not midnight UTC. The "Your Sites" overview page also respects each site's timezone.

            ### Visitor Intent

            A unique Spectabas feature. Every visitor is automatically classified by their behavior:

            - **Buying** — visited pricing, checkout, or signup pages
            - **Researching** — viewed 3+ pages or came from paid ads
            - **Comparing** — came from a comparison site (G2, Capterra, etc.)
            - **Support** — visited help, contact, or documentation pages
            - **Returning** — returning visitor with direct access
            - **Browsing** — casual visitor, 1-2 pages
            - **Bot** — detected bot or datacenter traffic

            ### Segment Filters

            Filter all dashboard data by any dimension. Click **Add** in the filter bar and choose a field, operator, and value. For example: `browser is Chrome` or `ip_country is US`.

            ### Saved Segments

            Save your frequently used filter combinations as named presets. When you have active filters, click **Save current** in the filter bar, enter a name, and the segment is saved. Click a saved segment name to instantly reload those filters. Each user has their own saved segments per site. Delete a saved segment with the **x** button.
            """
          },
          %{
            id: "pages",
            title: "Pages",
            body: """
            Shows your top pages ranked by pageviews.

            **Click any page URL** to see its **Page Transitions** — where visitors came from before viewing that page, and where they went afterward.

            ### Columns

            - **Page** — the URL path
            - **Pageviews** — total views
            - **Unique Visitors** — distinct visitors
            - **Avg Duration** — average time on page
            - **Load Time** — median page load from Real User Monitoring data, color-coded: green (under 1s), amber (1-3s), red (over 3s). Shows "—" if no RUM data is available for that page yet.

            ### Row Sparklines

            Click any row in the Pages table to expand an inline sparkline chart showing that page's pageview trend over the selected time period. Click again to collapse. This lets you quickly spot trending or declining pages without leaving the table view.
            """
          },
          %{
            id: "entry-exit",
            title: "Entry & Exit Pages",
            body: """
            **Entry Pages** show where visitors land when they first arrive at your site. These are your most important landing pages — optimize them for first impressions.

            **Exit Pages** show the last page visitors view before leaving. High exit rates on a page may indicate a problem (unless it's a "thank you" or confirmation page).

            Switch between tabs to see each view.
            """
          },
          %{
            id: "transitions",
            title: "Page Transitions",
            body: """
            For any page on your site, see the navigation flow:

            - **Came from** — pages visitors viewed immediately before this page
            - **Went to** — pages visitors viewed immediately after this page

            Enter a page path (e.g., `/pricing`) and click **Analyze**. Click any page in the results to follow the flow and explore how visitors navigate your site.

            ### Performance Stats

            When RUM data is available for the analyzed page, the current page card shows real load times: **Load** (full page load), **LCP** (Largest Contentful Paint), and **FCP** (First Contentful Paint), color-coded by speed. This lets you spot slow pages without leaving the transitions view.

            > **Example:** Analyzing `/pricing` might show that 40% came from `/features` and 25% went to `/signup` — telling you your features page effectively drives pricing exploration, and pricing converts to signup.
            """
          },
          %{
            id: "performance",
            title: "Performance (RUM)",
            body: """
            Real User Monitoring measures actual page load times and Core Web Vitals from your visitors' browsers. Data is collected passively with zero impact on user experience — the tracker uses `requestIdleCallback` and `PerformanceObserver` APIs, and waits for the page to fully load before collecting.

            ### Core Web Vitals

            Google's key metrics for page experience, scored as **Good**, **Needs Work**, or **Poor** using Google's official thresholds:

            - **LCP (Largest Contentful Paint)** — how fast the main content loads. Good: under 2.5s, Poor: over 4s
            - **CLS (Cumulative Layout Shift)** — visual stability. Good: under 0.1, Poor: over 0.25
            - **FID (First Input Delay)** — interactivity responsiveness. Good: under 100ms, Poor: over 300ms

            FID requires a user interaction (click, tap, keypress) to measure. If no visitors interact before navigating away, FID data will be absent for that period — this is normal.

            ### Page Load Timing

            Median values for: **TTFB** (time to first byte), **First Paint** (first contentful paint), **DOM Ready** (DOMContentLoaded), and **Full Load** (load event complete).

            ### Performance by Device

            Compare load times across desktop, mobile, and tablet visitors. Useful for identifying if mobile users have a significantly worse experience.

            ### Slowest Pages

            Pages ranked by median load time (slowest first), with TTFB and transfer size. Click any page to see its transition flow.

            ### Performance Across the Dashboard

            Performance data is also surfaced in other dashboard views for quick reference:

            - **Pages** — each page row shows a color-coded load time pill (green under 1s, amber 1-3s, red over 3s)
            - **Transitions** — the current page card shows Load, LCP, and FCP stats when RUM data is available

            > **Tip:** Focus on pages with high traffic AND slow load times for the biggest impact. Use the Pages view to quickly spot which popular pages need optimization.
            """
          },
          %{
            id: "site-search",
            title: "Site Search",
            body: """
            Captures internal search queries automatically from URL parameters. Supports these common parameter names: `q`, `query`, `search`, `s`, `keyword`.

            **No code changes needed** — if your site's search results page uses a URL like `/search?q=widgets`, Spectabas automatically captures "widgets" as a search term.

            This tells you what visitors are looking for on your site, which can inform content creation and navigation improvements.
            """
          },
          %{
            id: "outbound-links",
            title: "Outbound Links",
            body: """
            Automatically tracks clicks on external links. When a visitor clicks a link that goes to a different domain, Spectabas records the destination domain and full URL.

            **No code changes needed** — the tracker detects outbound links automatically by comparing the link hostname against the current page hostname.

            Shows which external sites your visitors click through to, helping you understand where traffic flows after leaving your site.
            """
          },
          %{
            id: "downloads",
            title: "File Downloads",
            body: """
            Automatically tracks clicks on links to downloadable files. Supported file extensions: PDF, ZIP, DOC, DOCX, XLS, XLSX, CSV, MP3, MP4, AVI, MOV, DMG, EXE, ISO.

            **No code changes needed** — the tracker detects file download links by checking the file extension in the URL path.

            Shows which files your visitors download most, with hit counts and unique visitor counts per file.
            """
          },
          %{
            id: "custom-events",
            title: "Custom Events",
            body: """
            Browse all custom events fired via `Spectabas.track()`. Internal events (prefixed with `_`) are hidden from this view — they power features like outbound link tracking, file downloads, RUM, and form abuse detection.

            Use this page to verify your custom event implementation and see which events are most popular across your visitors.

            ```javascript
            // Events fired with Spectabas.track() appear here
            Spectabas.track("signup", { plan: "pro" });
            Spectabas.track("add_to_cart", { product: "widget" });
            ```
            """
          },
          %{
            id: "acquisition",
            title: "Acquisition",
            body: """
            Consolidated view of all traffic acquisition data with two views:

            ### Channels View (default)

            Groups all traffic into marketing channels automatically based on referrer domains and UTM parameters:

            - **Search Engines** — Google, Bing, DuckDuckGo, Yahoo, Baidu, Yandex, Ecosia, Brave
            - **Social Networks** — Facebook, Instagram, Twitter/X, LinkedIn, Reddit, TikTok, YouTube, Pinterest, Threads, Mastodon
            - **AI Assistants** — ChatGPT, Claude, Perplexity, Gemini, Copilot, Poe, You.com, Phind
            - **Email** — Gmail, Outlook, Yahoo Mail, or utm_medium=email
            - **Paid Search** — utm_medium contains cpc, ppc, paid, or paidsearch
            - **Paid Social** — utm_medium contains paid_social or paidsocial
            - **Websites** — any referrer domain not in the above categories
            - **Direct** — no referrer and no UTM parameters
            - **Other Campaigns** — UTM source set but no referrer domain

            Each channel shows visitors, sessions, pageviews, bounce rate, average duration, and pages per session. Click a channel to drill into the individual sources within it.

            ### Sources View

            Switch to the Sources view to see individual referrer domains and UTM parameters across six tabs:

            - **Referrers** — domains that link to your site (google.com, twitter.com, etc.)
            - **UTM Source** — the `utm_source` parameter from tagged URLs
            - **UTM Medium** — the `utm_medium` parameter (cpc, email, social, etc.)
            - **UTM Campaign** — the `utm_campaign` parameter (spring_sale, product_launch, etc.)
            - **UTM Term** — the `utm_term` parameter (paid search keywords)
            - **UTM Content** — the `utm_content` parameter (ad variations, A/B test labels)

            **Click any source** to see the visitors from that source in the Visitor Log. Your own site's domain is automatically filtered out.
            """
          },
          %{
            id: "campaigns",
            title: "Campaigns",
            body: """
            Create and manage UTM-tagged campaign URLs. When you share these tagged links, Spectabas automatically tracks which campaign drove the traffic.

            ### UTM Parameters

            - `utm_source` — where traffic comes from (google, newsletter, facebook)
            - `utm_medium` — the marketing medium (cpc, email, social)
            - `utm_campaign` — the campaign name (spring_sale, product_launch)
            - `utm_term` — paid search keywords (optional)
            - `utm_content` — differentiates similar content (optional)

            ### Example

            ```
            https://example.com/pricing?utm_source=google&utm_medium=cpc&utm_campaign=spring_sale
            ```

            This URL tells Spectabas: "this visitor came from a Google paid ad as part of the spring_sale campaign."
            """
          },
          %{
            id: "geography",
            title: "Geography",
            body: """
            Visitor locations with drill-down navigation:

            - **Country level** — click a country to see its regions/states
            - **Region level** — click a region to see cities
            - **City level** — most granular view

            Countries are shown with full names and ISO codes (e.g., "United States (US)").

            ### Visitor Map

            The map page shows an interactive world map with bubble markers sized by visitor count. Hover over any bubble to see the city name and visitor count.
            """
          },
          %{
            id: "devices",
            title: "Devices",
            body: """
            Three tabs showing your audience's technology:

            - **Device Type** — desktop, smartphone, tablet
            - **Browser** — Chrome, Firefox, Safari, Edge, etc.
            - **OS** — Windows, macOS, Linux, iOS, Android, etc.


            Each is a separate, deduplicated view (no duplicate "smartphone" entries).
            """
          },
          %{
            id: "network",
            title: "Network",
            body: """
            ISP and network analysis showing:

            - **Datacenter %** — traffic from cloud/hosting providers
            - **VPN %** — traffic through VPN services
            - **Tor %** — traffic through the Tor network
            - **Bot %** — detected bot traffic
            - **EU Visitors %** — traffic from EU countries (useful for GDPR awareness)


            **Click any ASN number** to see the visitors from that network in the Visitor Log.

            The ASN table shows each network's organization name, traffic volume, and type badges (DC, VPN, Tor).
            """
          },
          %{
            id: "bot-traffic",
            title: "Bot Traffic",
            body: """
            Dedicated bot analysis page showing:

            - **Bot Events** — total events from detected bots with percentage of all traffic
            - **Bot Visitors** — unique bot visitor count vs human visitors
            - **Bot Types** — breakdown by datacenter, VPN, and Tor traffic
            - **Most Targeted Pages** — which pages bots hit most frequently
            - **Top Bot User Agents** — the actual bot signatures (Googlebot, Bingbot, SEMrush, etc.)

            Bot detection uses multiple signals: UA-based detection (UAInspector), client-side signals (`navigator.webdriver`, headless browser), datacenter IP detection (ASN blocklists), and the `_bot` flag from the tracker.

            This page intentionally shows bot-only data. All other analytics pages (dashboard, channels, sources, geography, etc.) automatically exclude bot traffic from their counts.
            """
          },
          %{
            id: "visitor-log",
            title: "Visitor Log",
            body: """
            Browse individual visitor sessions with:

            - **Pages** — number of pageviews in the session
            - **Duration** — time spent on site
            - **Location** — city, region, country
            - **Device** — browser and OS
            - **Source** — referrer domain
            - **Entry Page** — first page visited


            **Click a visitor ID** to see their full profile. **Click a referrer** to filter by that source. **Click an entry page** to see its transitions.

            ### IP Address Search

            Use the search bar at the top to find all visitors who used a specific IP address. Enter an IP and click Search to see matching visitors with their first/last seen timestamps, pageview counts, and browser info. Each result links to the full visitor profile.

            You can also link directly: `/dashboard/sites/:id/visitor-log?ip=192.168.1.1`

            ### Filtering

            The visitor log accepts filters from other pages — when you click an ASN on the Network page or a source on the Sources page, you're taken here with that filter pre-applied.
            """
          },
          %{
            id: "visitor-profile",
            title: "Visitor Profiles",
            body: """
            A comprehensive view of an individual visitor including:

            ### Identity & Device
            Browser, OS, screen size, identification method (cookie vs fingerprint), GDPR mode.

            ### Location & Network
            Country, region, city, timezone, ISP/organization. Badges for datacenter, VPN, or bot traffic.

            ### Acquisition & Behavior
            Original referrer, first and last pages, UTM sources, top pages visited.

            ### IP Address History
            Shows all IP addresses the visitor has used, with location, organization, datacenter/VPN badges, event count, and last seen timestamp. Each IP is clickable — takes you to the IP search on the Visitor Log to see all other visitors who used that IP.

            ### IP Cross-Referencing
            Click the IP address to expand a panel showing:

            - Full IP enrichment data (postal code, lat/lon, ASN details)
            - **Other visitors from the same IP** — useful for identifying shared networks, offices, or potential fraud

            ### Session History
            Table of all sessions with entry/exit pages, referrer, and duration.

            ### Event Timeline
            Chronological list of every event (pageviews, custom events, duration pings) with timestamps.
            """
          },
          %{
            id: "cohort",
            title: "Cohort Retention",
            body: """
            A weekly retention grid showing what percentage of visitors return after their first visit.

            - **Rows** = cohort weeks (when visitors first appeared)
            - **Columns** = weeks since first visit (Week 0, +1w, +2w, etc.)
            - **Cells** = percentage of the cohort that returned, color-coded (darker = higher retention)

            > **Example:** If the "Mar 10" row shows 100% at Week 0, 15% at +1w, and 8% at +2w, that means 15% of visitors from that week came back the following week, and 8% came back two weeks later.

            Available in 30-day, 90-day, and 6-month views.
            """
          },
          %{
            id: "realtime",
            title: "Realtime",
            body: """
            Live feed of visitor activity from the last 5 minutes. Shows event type, page, location, device, and timestamp for each event as it happens.

            The dashboard header also shows a live visitor count with a green pulse indicator.
            """
          }
        ]
      },
      %{
        category: "REST API",
        items: [
          %{
            id: "api-auth",
            title: "API Authentication",
            body: """
            All API requests require a Bearer token in the Authorization header.

            ### Getting an API Key

            Go to **Account > Settings** and generate an API key. The key starts with `sab_live_`. The creation form lets you configure:

            - **Scopes** — checkboxes for each permission (admin:sites unchecked by default)
            - **Site restrictions** — optionally limit the key to specific sites
            - **Expiry date** — optional expiration after which the key stops working

            ### Token Scopes

            API keys use granular scopes to control access:

            | Scope | Grants access to |
            |-------|-----------------|
            | `read:stats` | GET stats, pages, sources, channels |
            | `read:visitors` | GET visitor log, visitor details |
            | `write:events` | POST events, ecommerce transactions |
            | `write:identify` | POST server-side visitor identification |
            | `admin:sites` | Site management endpoints |

            Tokens can also be **restricted to specific sites** and given an **expiry date**.

            ### Making Requests

            ```bash
            curl -H "Authorization: Bearer sab_live_YOUR_KEY" \\
              https://www.spectabas.com/api/v1/sites/1/stats
            ```

            ### Error Responses

            | Status | Meaning |
            |--------|---------|
            | 401 | Invalid or missing API key |
            | 403 | API key doesn't have access to this site or required scope |
            | 404 | Site not found |

            > **Access Logging:** All API requests are logged with request/response bodies. Logs are retained for 30 days and viewable by admins at `/admin/api-logs`.
            """
          },
          %{
            id: "api-stats",
            title: "API: Overview Stats",
            body: """
            `GET /api/v1/sites/:site_id/stats`

            Returns pageviews, unique visitors, sessions, bounce rate, and average duration.

            ### Parameters

            | Param | Type | Default | Description |
            |-------|------|---------|-------------|
            | `period` | string | "7d" | Time period: "day", "week", "month" |

            ### Example Response

            ```json
            {
              "data": {
                "pageviews": "142",
                "unique_visitors": "89",
                "total_sessions": "95",
                "bounce_rate": "45.2",
                "avg_duration": "124"
              }
            }
            ```

            > **Note:** ClickHouse returns all values as strings. Parse them as numbers in your client code.
            """
          },
          %{
            id: "api-pages",
            title: "API: Top Pages",
            body: """
            `GET /api/v1/sites/:site_id/pages`

            Returns top pages ranked by pageviews.

            ```json
            {
              "data": [
                {"url_path": "/", "pageviews": "50", "unique_visitors": "42", "avg_duration": "30"},
                {"url_path": "/pricing", "pageviews": "25", "unique_visitors": "22", "avg_duration": "90"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-sources",
            title: "API: Sources",
            body: """
            `GET /api/v1/sites/:site_id/sources`

            Returns top traffic sources.

            ```json
            {
              "data": [
                {"referrer_domain": "google.com", "utm_source": "", "utm_medium": "", "pageviews": "30", "sessions": "25"},
                {"referrer_domain": "twitter.com", "utm_source": "", "utm_medium": "", "pageviews": "12", "sessions": "10"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-countries",
            title: "API: Countries",
            body: """
            `GET /api/v1/sites/:site_id/countries`

            Returns visitor locations with country, region, and city.

            ```json
            {
              "data": [
                {"ip_country": "US", "ip_region_name": "California", "ip_city": "San Francisco", "pageviews": "20", "unique_visitors": "15"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-devices",
            title: "API: Devices",
            body: """
            `GET /api/v1/sites/:site_id/devices`

            Returns device type, browser, and OS breakdown.

            ```json
            {
              "data": [
                {"device_type": "desktop", "browser": "Chrome", "os": "macOS", "pageviews": "80", "unique_visitors": "60"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-realtime",
            title: "API: Realtime",
            body: """
            `GET /api/v1/sites/:site_id/realtime`

            Returns the number of active visitors in the last 5 minutes.

            ```json
            {
              "data": {
                "active_visitors": 3
              }
            }
            ```
            """
          },
          %{
            id: "api-identify",
            title: "Server-Side Identify",
            body: """
            `POST /api/v1/sites/:site_id/identify`

            Links an email address or user ID to an existing Spectabas visitor. Use this from your server when a user logs in to associate their identity with the anonymous visitor created by the tracker script.

            **Request body:**

            | Field | Type | Required | Description |
            |-------|------|----------|-------------|
            | `visitor_id` | string | yes | The value of the `_sab` cookie set by the tracker |
            | `email` | string | no | User's email address (stored as SHA-256 hash) |
            | `user_id` | string | no | Your internal user ID |
            | `ip` | string | no | User's real IP address (for geo enrichment) |

            ### How It Works

            - A visitor browses your site. The Spectabas tracker script sets a `_sab` cookie with a unique visitor ID.
            - When the visitor logs in, your server reads the `_sab` cookie from the HTTP request.
            - Your server sends a POST to Spectabas with the cookie value + the user's email.
            - Spectabas links the email to the anonymous visitor record, so you can see who that visitor is in the visitor log.

            ### Example (Elixir/Phoenix)

            ```elixir
            # In your SessionController or login pipeline:
            def create(conn, %{"email" => email, "password" => password}) do
              case Accounts.authenticate(email, password) do
                {:ok, user} ->
                  # After successful login, identify the visitor in Spectabas
                  sab_cookie = conn.cookies["_sab"]

                  if sab_cookie do
                    Task.start(fn ->
                      Req.post!("https://www.spectabas.com/api/v1/sites/4/identify",
                        headers: [{"authorization", "Bearer YOUR_API_KEY"}],
                        json: %{
                          visitor_id: sab_cookie,
                          email: user.email,
                          user_id: to_string(user.id),
                          ip: to_string(:inet.ntoa(conn.remote_ip))
                        }
                      )
                    end)
                  end

                  conn
                  |> put_session(:user_id, user.id)
                  |> redirect(to: "/dashboard")

                {:error, _} ->
                  # ...
              end
            end
            ```

            ### Example (Ruby/Rails)

            ```ruby
            # In your sessions controller, after login:
            sab_cookie = cookies["_sab"]
            if sab_cookie.present?
              Thread.new do
                HTTParty.post(
                  "https://www.spectabas.com/api/v1/sites/4/identify",
                  headers: { "Authorization" => "Bearer YOUR_API_KEY",
                             "Content-Type" => "application/json" },
                  body: { visitor_id: sab_cookie,
                          email: current_user.email,
                          user_id: current_user.id.to_s,
                          ip: request.remote_ip }.to_json
                )
              end
            end
            ```

            ### Example (Node.js/Express)

            ```javascript
            // After login middleware:
            const sabCookie = req.cookies._sab;
            if (sabCookie) {
              fetch("https://www.spectabas.com/api/v1/sites/4/identify", {
                method: "POST",
                headers: {
                  "Authorization": "Bearer YOUR_API_KEY",
                  "Content-Type": "application/json"
                },
                body: JSON.stringify({
                  visitor_id: sabCookie,
                  email: req.user.email,
                  user_id: String(req.user.id),
                  ip: req.ip
                })
              }).catch(() => {}); // Fire and forget
            }
            ```

            ### Example (curl)

            ```bash
            curl -X POST https://www.spectabas.com/api/v1/sites/4/identify \\
              -H "Authorization: Bearer YOUR_API_KEY" \\
              -H "Content-Type: application/json" \\
              -d '{"visitor_id": "abc123...", "email": "user@example.com", "user_id": "42"}'
            ```

            ### Response

            ```json
            {"ok": true, "visitor_id": "uuid-...", "email_hash": "abc123..."}
            ```

            ### Important Notes

            - **The `visitor_id` is the value of the `_sab` cookie**, set automatically by the tracker script. Read it from the HTTP request cookies on your server.
            - **Email is hashed** — stored as a SHA-256 hash for privacy. The original email is kept for display in the visitor log but never exposed via the read API.
            - **Fire and forget** — wrap the API call in an async task (Task.start, Thread.new, etc.) so it doesn't block your login flow.
            - **Call on every login** — the `_sab` cookie may change (new browser, cleared cookies), so always identify on login to keep the association current.
            - **IP is optional** — if provided, it updates the visitor's geo data and known IPs list.
            """
          },
          %{
            id: "api-ecommerce-stats",
            title: "Ecommerce Stats",
            body: """
            `GET /api/v1/sites/:site_id/ecommerce`

            Returns aggregate ecommerce stats for the period.

            | Parameter | Default | Description |
            |-----------|---------|-------------|
            | `period` | `7d` | `24h`, `7d`, `30d`, or `custom` |
            | `from` | — | ISO 8601 start (required for `custom`) |
            | `to` | — | ISO 8601 end (required for `custom`) |

            ```json
            {
              "data": {
                "total_orders": 42,
                "total_revenue": 4199.58,
                "avg_order_value": 99.99,
                "min_order": 12.50,
                "max_order": 349.00
              }
            }
            ```
            """
          },
          %{
            id: "api-ecommerce-products",
            title: "Ecommerce Top Products",
            body: """
            `GET /api/v1/sites/:site_id/ecommerce/products`

            Returns top products by revenue for the period. Extracts product data from order item lists.

            ```json
            {
              "data": [
                {"name": "Pro Widget", "quantity": 156, "revenue": 9343.44},
                {"name": "Basic Widget", "quantity": 89, "revenue": 2669.11}
              ]
            }
            ```
            """
          },
          %{
            id: "api-ecommerce-orders",
            title: "Ecommerce Orders",
            body: """
            `GET /api/v1/sites/:site_id/ecommerce/orders`

            Returns the most recent 100 orders for the period, with full details.

            ```json
            {
              "data": [
                {
                  "order_id": "ORD-123",
                  "visitor_id": "abc...",
                  "revenue": 99.99,
                  "subtotal": 89.99,
                  "tax": 7.20,
                  "shipping": 2.80,
                  "discount": 0,
                  "currency": "USD",
                  "items": "[{\\"name\\":\\"Widget\\",\\"price\\":49.99,\\"quantity\\":2}]",
                  "timestamp": "2026-03-31 19:00:00"
                }
              ]
            }
            ```
            """
          },
          %{
            id: "api-ecommerce-transactions",
            title: "Record Ecommerce Transaction",
            body: """
            `POST /api/v1/sites/:site_id/ecommerce/transactions`

            Record an ecommerce transaction from your server. Use this when a purchase is completed to ensure accurate revenue tracking regardless of client-side JavaScript.

            **Request body:**

            | Field | Type | Required | Description |
            |-------|------|----------|-------------|
            | `order_id` | string | yes | Unique order identifier |
            | `revenue` | number | no | Total revenue (including tax/shipping) |
            | `visitor_id` | string | no | The `_sab` cookie value to link to a visitor |
            | `email` | string | no | Customer email — links the transaction to a Spectabas visitor profile. If `visitor_id` is also provided, identifies that visitor with this email. If only `email` is provided, looks up the visitor by email. |
            | `subtotal` | number | no | Subtotal before tax/shipping |
            | `tax` | number | no | Tax amount |
            | `shipping` | number | no | Shipping cost |
            | `discount` | number | no | Discount applied |
            | `currency` | string | no | Currency code (defaults to site currency) |
            | `items` | array | no | List of items: `[{"name": "...", "price": 9.99, "quantity": 1, "category": "..."}]`. Category is optional — use it to distinguish sub-types (e.g. "new_subscription" vs "renewal"). |
            | `occurred_at` | integer | no | Unix timestamp (UTC seconds) for when the order occurred. Must be within the last 7 days. Defaults to current time. |

            ### Example (Elixir/Phoenix)

            ```elixir
            # After successful checkout:
            Task.start(fn ->
              Req.post!("https://www.spectabas.com/api/v1/sites/4/ecommerce/transactions",
                headers: [{"authorization", "Bearer YOUR_API_KEY"}],
                json: %{
                  order_id: order.id,
                  revenue: order.total,
                  subtotal: order.subtotal,
                  tax: order.tax,
                  shipping: order.shipping,
                  discount: order.discount,
                  visitor_id: conn.cookies["_sab"],
                  email: current_user.email,
                  currency: "USD",
                  occurred_at: DateTime.to_unix(order.completed_at),
                  items: Enum.map(order.line_items, fn item ->
                    %{
                      name: item.product_name,
                      price: item.unit_price,
                      quantity: item.quantity,
                      category: item.category
                    }
                  end)
                }
              )
            end)
            ```

            When `email` is provided:
            - If `visitor_id` is also provided, the visitor is identified with that email (same as calling the identify API)
            - If only `email` is provided (no `visitor_id`), the system looks up the most recent visitor with that email
            - The transaction is then linked to that visitor, making it visible on their profile page and in the visitor log

            ### Example (curl)

            ```bash
            curl -X POST https://www.spectabas.com/api/v1/sites/4/ecommerce/transactions \\
              -H "Authorization: Bearer YOUR_API_KEY" \\
              -H "Content-Type: application/json" \\
              -d '{
                "order_id": "ORD-123",
                "revenue": 99.99,
                "visitor_id": "abc123...",
                "email": "customer@example.com",
                "occurred_at": 1711900000,
                "items": [{"name": "Widget", "price": 49.99, "quantity": 2, "category": "new"}]
              }'
            ```

            ### Response

            ```json
            {"ok": true, "order_id": "ORD-123"}
            ```

            ### JavaScript (client-side alternative)

            You can also record transactions client-side using the tracker:

            ```javascript
            spectabas.ecommerce.addOrder({
              order_id: "ORD-123",
              revenue: 99.99,
              items: [{name: "Widget", price: 49.99, quantity: 2}]
            });
            ```

            The server-side API is recommended for accuracy — it can't be blocked by ad blockers and doesn't depend on the user's browser staying on the page after checkout.
            """
          }
        ]
      },
      %{
        category: "Administration",
        items: [
          %{
            id: "user-roles",
            title: "User Roles & Permissions",
            body: """
            Spectabas has four user roles:

            | Role | Access |
            |------|--------|
            | **Superadmin** | Full access. Manage users, sites, billing, all settings. Required for 2FA setup. |
            | **Admin** | Manage sites and settings. Add/remove sites, configure tracking, invite users. |
            | **Analyst** | View all analytics data. Dashboards, reports, visitor logs, exports. Cannot change settings. |
            | **Viewer** | Read-only dashboard access for permitted sites only. |

            ### Inviting Users

            Go to **Admin > Users** and click **Invite User**. Enter their email and select a role. They'll receive an email with a link to set up their account (link expires in 48 hours).

            You can **Resend** an invitation (which revokes the old link and sends a new one) or **Revoke** it entirely.
            """
          },
          %{
            id: "site-settings",
            title: "Site Settings",
            body: """
            Each site has these configurable options:

            - **Name** — display name in the dashboard

            - **Domain** — the analytics subdomain (e.g., `b.example.com`)
            - **Timezone** — determines "today" boundaries, chart labels, and date ranges across the entire dashboard (e.g., `America/New_York`)
            - **GDPR Mode** — "on" (fingerprint, no cookies) or "off" (cookies, more accurate)
            - **Cookie Domain** — for cross-subdomain cookie sharing
            - **Cross-Domain Tracking** — enable and list domains for cross-site visitor tracking
            - **IP Blocklist** — block specific IPs from being tracked
            - **Ecommerce** — enable ecommerce tracking with currency setting
            - **Email Reports** — configured on a separate page under Tools in the sidebar

            ### User Timezone

            Each user has a personal timezone preference (set from admin pages via the timezone dropdown). This controls timestamp display on admin pages like Ingest Diagnostics and API Access Logs. Site-specific pages (dashboards, visitor log) use the site's configured timezone instead.
            """
          },
          %{
            id: "email-reports",
            title: "Email Reports",
            body: """
            Receive periodic analytics digests by email. Each user can configure their own report preferences per site.

            ### Setting Up

            Go to any site's **Settings** page and scroll to the "Email Reports" section. Choose:

            - **Frequency** — Daily, Weekly, or Monthly (or Off to disable)
            - **Send Time** — hour of day in the site's timezone (e.g., 9:00 AM)

            Reports are personal — each user with access to the site can set their own frequency and time.

            ### What's Included

            Each report email contains:

            - **Summary stats** — pageviews, visitors, sessions, bounce rate, and average duration with percentage change vs the previous equivalent period
            - **Top 5 pages** — ranked by pageviews
            - **Top 5 sources** — referrer domains ranked by pageviews
            - **Top 5 countries** — ranked by unique visitors
            - **Top 10 search keywords** — from Google Search Console / Bing Webmaster (if connected), with clicks, impressions, and position
            - **Revenue summary** — total revenue, orders, and refunds (if ecommerce is enabled)
            - **Ad spend breakdown** — spend, clicks, and impressions by platform (if ad platforms are connected)

            ### AI Weekly Insights Email

            If you've configured an AI provider in Site Settings, you'll also receive a separate **Weekly AI Insights** email every Monday morning. This uses AI to analyze all your data (traffic, SEO, revenue, ad spend) and generate prioritized action items. Configure your AI provider under Settings > AI Analysis.

            Daily reports compare today vs yesterday. Weekly reports compare the last 7 days vs the prior 7 days. Monthly reports compare this month vs last month.

            ### Unsubscribing

            Every report email includes an **Unsubscribe** link at the bottom. Clicking it immediately disables reports without requiring login. You can also set frequency to "Off" in site settings at any time.

            ### For Admins

            The Settings page shows a "Report Subscribers" table listing all users who have active email reports for the site, including their frequency, send time, and when they last received a report.
            """
          },
          %{
            id: "spam-filter",
            title: "Spam Filter",
            body: """
            Referrer spam — fake traffic from domains like semalt.com and darodar.com — is automatically filtered from your analytics. The spam filter has three layers:

            ### Built-in Blocklist

            20+ known spam domains are blocked by default. These are maintained in the codebase and apply to all sites automatically.

            ### Custom Blocklist

            Admins can add or remove custom spam domains via **Admin > Spam Filter**. Custom domains are stored in the database and apply across all sites.

            ### Auto-Detection

            A daily background job scans ClickHouse for suspicious referrer domains — those with high bot percentage (>50%), high hit counts (>100), or appearing across multiple sites. Candidates are presented on the admin page for review. They are NOT auto-blocked — an admin must approve each one.

            Spam domains are excluded from the Sources page, All Channels page, and attribution calculations. They are still visible in the Network and Bot Traffic pages for analysis purposes.
            """
          }
        ]
      },
      %{
        category: "Conversions",
        items: [
          %{
            id: "goals-funnels",
            title: "Goals & Funnels",
            body: """
            ### Goals

            Track specific visitor actions:

            - **Pageview goals** — triggered when a visitor views a specific page (supports wildcards: `/blog/*`)
            - **Custom event goals** — triggered when your JavaScript calls `Spectabas.track("event_name")`

            Goals appear on the Conversions > Goals page with total completions and conversion rate for the selected period.

            ### Funnels

            Define multi-step conversion paths to see where visitors drop off. Each step can be a pageview (URL path match) or a custom event.

            > **Example funnel:** Homepage → Features → Pricing → Signup. If 1000 visitors start at Homepage but only 50 reach Signup, you can see exactly where the drop-off happens.

            The funnel visualization shows:
            - **Step count** — visitors who reached each step
            - **Drop-off rate** — percentage that didn't continue to the next step
            - **Completion rate** — percentage that completed the entire funnel

            ### Funnel Revenue (Ecommerce)

            For sites with ecommerce enabled, funnels show the total revenue generated by visitors who reached each step. This helps you quantify the cost of drop-off — "visitors who abandoned at step 3 represent $12,000 in lost revenue."

            ### Export Abandoned Visitors

            Each funnel step has an **Export drop-off** button that downloads a CSV of visitors who reached that step but didn't continue. The CSV includes `visitor_id` and `email` (for identified visitors). Use this to build remarketing lists or trigger win-back emails.
            """
          },
          %{
            id: "ecommerce-overview",
            title: "Ecommerce Tracking",
            body: """
            Spectabas tracks ecommerce transactions, revenue, and product data when ecommerce mode is enabled for a site (Settings > Ecommerce > Enable).

            ### Dashboard Integration

            When ecommerce is enabled, the main site dashboard shows:
            - **Revenue** card — total revenue for the period with comparison
            - **Orders** card — total orders with comparison
            - **AOV** card — average order value

            ### Ecommerce Page

            The dedicated **Conversions > Ecommerce** page shows:
            - **Revenue + Orders chart** — combined bar (revenue) and line (orders) time series
            - **Top Products** — grouped by product name and category, with revenue, quantity, and AOV
            - **Recent Orders** — order list with visitor link, revenue, item count

            ### Tracking Orders

            **Client-side (JavaScript):**

            ```javascript
            Spectabas.ecommerce.addOrder({
              order_id: "ORD-123",
              revenue: "49.99",
              currency: "USD"
            });

            Spectabas.ecommerce.addItem({
              order_id: "ORD-123",
              name: "Pro Plan",
              price: "49.99",
              quantity: "1",
              category: "subscription"
            });
            ```

            **Server-side (API):**

            `POST /api/v1/sites/:id/ecommerce/transactions` with order details and optional `email` field for visitor association.

            ### Product Categories

            Items support an optional `category` field for sub-types (e.g., `new_subscription` vs `renewal`). The Top Products table groups by name + category.

            ### Email Association

            The transaction API accepts an optional `email` field. If provided with a `visitor_id`, it identifies the visitor. Orders then appear on visitor profile pages.
            """
          },
          %{
            id: "revenue-attribution",
            title: "Revenue Attribution",
            body: """
            **Conversions > Revenue Attribution**

            The central page for understanding which traffic sources generate paying customers and whether your ad spend is profitable.

            ### Source Table

            For each traffic source, you see:

            | Column | Description |
            |--------|-------------|
            | **Visitors** | Unique visitors attributed to this source |
            | **Orders** | Purchases by those visitors |
            | **Revenue** | Total revenue from those orders |
            | **AOV** | Average order value |
            | **Conv Rate** | Percentage of visitors who purchased |
            | **Rev Share** | This source's share of total revenue (bar chart) |

            All columns are **sortable** — click any header to sort ascending/descending.

            ### Paid vs Organic Split

            Sources are automatically split into paid and organic rows. Visitors who arrived via an ad click ID (gclid, msclkid, fbclid) get a separate row with a colored pill: **Google Ads** (blue), **Bing Ads** (cyan), **Meta Ads** (indigo). Organic visitors from the same source appear as a separate row without a pill. This lets you directly compare paid vs organic performance from the same traffic source.

            ### UTM Dimension Tabs

            Toggle between 5 views: **Source** (referrer domain or utm_source), **Medium** (utm_medium), **Campaign** (utm_campaign), **Term** (utm_term), **Content** (utm_content).

            When viewing by **Campaign** and ad data is available, three additional columns appear:
            - **Ad Spend** — total spend for that campaign (matched by campaign name)
            - **ROAS** — Return on Ad Spend (revenue / spend), color-coded: green (3x+), yellow (1-3x), red (<1x)
            - **CPC** — Cost per Click (spend / clicks)

            ### Attribution Models

            Three toggle options control how revenue is credited to sources:

            | Model | Behavior | Best For |
            |-------|----------|----------|
            | **First Touch** | Credits the first source that brought the visitor | Understanding discovery — what channels bring new customers |
            | **Last Touch** (default) | Credits the most recent source before purchase | Evaluating what closes — which touchpoint drove the conversion |
            | **Any Touch** | Credits every source the visitor ever touched | Full journey view — did an ad click appear anywhere in the path |

            > **Any Touch note:** A single conversion can appear under multiple sources, so totals may exceed actual revenue. This is expected — it answers "was this source involved?" not "how much credit does it get?"

            ### Ad Spend Overview

            When ad platforms are connected (Google Ads, Bing, Meta), an **Ad Spend Overview** card appears at the top:

            - **Total Spend** — aggregate ad spend across all platforms for the period
            - **Ad Revenue** — revenue from visitors who arrived via ad click IDs (gclid/msclkid/fbclid)
            - **ROAS** — ad revenue / ad spend, color-coded
            - **Ad Clicks** — total clicks from all platforms
            - **Impressions** — total ad impressions

            If multiple platforms are connected, a per-platform breakdown shows spend, revenue, ROAS, and clicks for each.

            ### Click ID Attribution

            Spectabas automatically captures ad platform click IDs from landing page URLs:

            | Click ID | Platform | How it arrives |
            |----------|----------|---------------|
            | `gclid` | Google Ads | Auto-tagging (enabled by default in Google Ads) |
            | `msclkid` | Microsoft/Bing Ads | Auto-tagging (enabled by default) |
            | `fbclid` | Meta/Facebook Ads | Appended automatically to ad click URLs |

            When a visitor lands with a click ID, every event in their session is tagged with the platform. If they later purchase, that revenue is attributed to the ad platform — giving you **platform-level ROAS** without any UTM setup required.

            Click IDs are persisted in the visitor's browser session (sessionStorage), so they survive across page navigations within the same visit.

            ### Combining Click IDs with UTM Tags

            For **campaign-level ROAS**, add UTM parameters to your ad URLs:

            - The click ID proves the visitor came from a real paid ad click
            - The `utm_campaign` parameter tells you which specific campaign

            **Google Ads URL template example:**

            ```
            {lpurl}?utm_source=google&utm_medium=cpc&utm_campaign={campaignname}
            ```

            **Bing Ads URL template:**

            ```
            {lpurl}?utm_source=bing&utm_medium=cpc&utm_campaign={CampaignName}
            ```

            **Meta Ads:** Set UTM parameters manually in your ad's URL parameters section.

            ### Ad Spend by Campaign Table

            When viewing by Source, Medium, Term, or Content (not Campaign), a separate **Ad Spend by Campaign** table appears below the main revenue table. It shows:

            | Column | Description |
            |--------|-------------|
            | Campaign | Campaign name from the ad platform |
            | Platform | Google Ads / Microsoft Ads / Meta Ads (color-coded) |
            | Spend | Total campaign spend |
            | Clicks | Ad clicks |
            | Impressions | Ad impressions |
            | CPC | Cost per click (spend / clicks) |
            | CTR | Click-through rate (clicks / impressions) |

            > **Use case:** You're spending $5,000/month on Google Ads and $2,000 on Facebook. Revenue Attribution shows Google generated $15,000 in ad-attributed revenue (3x ROAS) while Facebook generated $800 (0.4x ROAS). You'd shift budget to Google.
            """
          },
          %{
            id: "revenue-cohorts",
            title: "Revenue Cohorts",
            body: """
            **Conversions > Revenue Cohorts**

            Groups customers by their first-purchase week and tracks lifetime value over time.

            The heatmap grid shows:
            - **Rows** — cohort week (when the customer first purchased)
            - **Columns** — weeks since first purchase (Wk 0, Wk 1, Wk 2, ...)
            - **Cells** — revenue per customer in that cohort/week

            Hover over any cell to see the customer count.

            > **Use case:** "January cohort generated $4.50/customer in week 0 but only $0.80 by week 4." This tells you retention is dropping fast and you need engagement campaigns for new customers in weeks 2-3.
            """
          },
          %{
            id: "buyer-patterns",
            title: "Buyer Patterns",
            body: """
            **Conversions > Buyer Patterns**

            Compares how buyers behave differently from non-buyers.

            ### Engagement Comparison

            Side-by-side cards showing:
            - **Avg Sessions** — how many times they visit
            - **Avg Pages** — how many pages they view per session
            - **Avg Duration** — how long they stay

            Buyers typically have higher numbers across all three metrics.

            ### Page Lift Analysis

            A table of pages sorted by "lift" — how much more likely buyers are to visit each page compared to non-buyers. A lift of 2.5x means buyers are 2.5 times more likely to visit that page.

            > **Use case:** The `/pricing` page has a 4.2x lift, but `/features` has only 0.8x. This means visitors who read pricing are much more likely to buy, but the features page isn't driving conversions. You might redesign the features page or add a stronger CTA to pricing.
            """
          },
          %{
            id: "churn-risk",
            title: "Churn Risk",
            body: """
            **Audience > Churn Risk**

            Identifies existing customers whose engagement is declining, suggesting they may be about to churn (cancel subscription, stop purchasing).

            The algorithm compares each customer's engagement in the **last 14 days** vs the **prior 14 days**:
            - A customer with 10 sessions in days 15-28 but only 3 sessions in days 1-14 has a **70% session decline**
            - Customers with 50%+ decline in sessions or 70%+ decline in pages viewed are flagged

            ### Risk Levels

            - **High** (red) — 70%+ session decline
            - **Medium** (orange) — 50-70% decline
            - **Low** (yellow) — flagged but less severe

            Identified customers (with email from the identify API) are shown with their email address and linked to their visitor profile. Use this to trigger re-engagement emails or personal outreach.

            > **Only shows customers** — visitors must have at least one ecommerce order to appear here. Anonymous visitors are not tracked for churn.
            """
          },
          %{
            id: "visitor-quality",
            title: "Visitor Quality Score",
            body: """
            **Ad Effectiveness > Visitor Quality**

            Scores ad visitors (0-100) on engagement signals, grouped by platform or campaign. Answers: "Which ad sources bring genuinely engaged visitors vs low-quality traffic?"

            ### Score Components

            | Component | Weight | How it's measured |
            |-----------|--------|-------------------|
            | Pages/session | 25 pts | Normalized to 5 pages = max score |
            | Duration | 25 pts | Capped at 5 minutes = max score |
            | Non-bounce | 20 pts | Percentage that viewed more than 1 page |
            | Return visits | 15 pts | Percentage with 2+ sessions |
            | High intent | 15 pts | Percentage classified as buying/researching/comparing |

            ### Reading the Table

            - **Score > 60** (green) — high-quality traffic worth scaling
            - **Score 30-60** (yellow) — moderate quality, may need landing page optimization
            - **Score < 30** (red) — low engagement, consider pausing or restructuring

            > **Use case:** Google Ads scores 72 but Meta Ads scores 28. Meta is sending visitors who bounce immediately. Either improve Meta ad targeting/landing pages, or shift budget to Google.
            """
          },
          %{
            id: "time-to-convert",
            title: "Time to Convert",
            body: """
            **Ad Effectiveness > Time to Convert**

            Measures how many days and sessions elapse between a visitor's first ad click and their first purchase.

            ### Distribution Histogram

            Shows converter counts in time buckets: Same day, 1 day, 2-3 days, 4-7 days, 8-14 days, 15-30 days, 30+ days. A concentration in "Same day" means your ads bring ready-to-buy visitors. A spread across longer periods suggests a consideration cycle that needs nurturing.

            ### Per-Source Table

            For each platform/campaign:
            - **Avg/Median Days** — median is more useful since outliers skew the average
            - **Avg/Median Sessions** — how many visits before they buy

            > **Use case:** Google Ads visitors convert in 2.3 days (median) but Meta visitors take 8.1 days. Google brings ready-to-buy traffic. For Meta, consider retargeting campaigns to stay visible during the longer decision window.
            """
          },
          %{
            id: "ad-visitor-paths",
            title: "Ad Visitor Paths",
            body: """
            **Ad Effectiveness > Ad Visitor Paths**

            Shows the most common page sequences (first 5 pages) for visitors who arrived via ad clicks, with conversion rates per path.

            ### All Paths View

            A table of page journeys (e.g., `/landing → /pricing → /signup`) showing how many visitors took each path and what percentage converted. Paths with high conversion rates reveal your best-performing funnels.

            ### Bounce Pages View

            Landing pages where ad visitors left after viewing only one page, grouped by ad platform. High bounce rates on a landing page mean the page doesn't match the ad promise.

            > **Use case:** The path `/landing-page → /pricing → /signup` has a 12% conversion rate, but `/landing-page → /features → /about` has 0.5%. Visitors who go straight to pricing convert — add a stronger pricing CTA on your landing page.
            """
          },
          %{
            id: "ad-churn",
            title: "Ad-to-Churn Correlation",
            body: """
            **Ad Effectiveness > Ad-to-Churn**

            Cross-references which ad campaigns bring customers who stay active vs which bring customers who churn (50%+ session decline over 14-day windows).

            ### Comparison Cards

            Side-by-side ad churn rate vs organic churn rate. If ad traffic churns significantly more than organic, your ads may be attracting the wrong audience.

            ### Campaign Table

            For each platform/campaign: total visitors, churned, retained, purchased, churn rate. Color-coded: green (<25%), yellow (25-50%), red (>50%).

            > **Use case:** Google campaign "brand-terms" has 12% churn but "broad-match" has 48%. Broad match is attracting visitors who don't stick. Tighten the targeting or adjust the landing page to set better expectations.

            > **Note:** Requires at least 28 days of data. Churn detection compares the most recent 14 days to the prior 14 days for each visitor.
            """
          },
          %{
            id: "organic-lift",
            title: "Organic Lift",
            body: """
            **Ad Effectiveness > Organic Lift**

            Compares organic and direct traffic on days with high ad spend vs low ad spend. Answers: "Do my ads have a halo effect that drives more organic discovery?"

            ### How It Works

            Days are split at the median daily ad spend:
            - **High Spend Days** — above median
            - **Low Spend Days** — below median

            For each group, shows average daily organic visitors and direct visitors.

            ### Lift Calculation

            The headline shows the percentage difference: "Organic traffic is X% higher on high-spend days." A positive lift suggests ads increase brand awareness that drives organic searches.

            ### Daily Breakdown

            Full table of every day with ad spend, organic visitors, direct visitors, and a high/low spend badge.

            > **Important:** Correlation is not causation. Organic traffic may be higher on high-spend days for other reasons (seasonality, content publishing, etc.). Use this as a directional signal, not proof.

            > **Use case:** Organic traffic is 34% higher on days with above-median Google Ads spend. This suggests your ads are generating brand searches that convert organically — your true ROAS may be higher than the click-attributed number shows.
            """
          },
          %{
            id: "integration-overview",
            title: "Integration Overview",
            body: """
            Connect your advertising accounts and payment providers to track Return on Ad Spend (ROAS) and revenue directly in Spectabas. Supported platforms: **Google Ads**, **Microsoft/Bing Ads**, **Meta/Facebook Ads**, **Stripe**, and **Braintree**.

            For platform-specific setup instructions, see:
            - [Google Ads](/docs/conversions#google-ads-setup)
            - [Microsoft/Bing Ads](/docs/conversions#bing-ads-setup)
            - [Meta/Facebook Ads](/docs/conversions#meta-ads-setup)
            - [Stripe](/docs/admin#stripe-setup)
            - [Braintree](/docs/admin#braintree-setup)

            ### How It Works

            - An admin connects each ad account via OAuth2 from **Site Settings > Ad Platform Integrations**
            - Spectabas syncs daily campaign spend data (spend, clicks, impressions) every 6 hours
            - Payment providers (Stripe, Braintree) sync completed charges every 15 minutes by default (configurable)
            - The **Revenue Attribution** page joins ad spend with purchase data to calculate ROAS per campaign

            ### Connecting an Account

            - Go to your site's **Settings** page
            - Scroll to **Ad Platform Integrations**
            - Click **Configure** on the platform you want to set up
            - Enter your OAuth credentials and click **Save Credentials**
            - Click **Connect** — you'll be redirected to the ad platform to authorize access
            - After granting access, you'll be returned to Spectabas and the card will show "Connected" with the account name and last sync time

            ### What Gets Synced

            **Ad platforms** (Google, Bing, Meta) — daily campaign data:

            | Field | Description |
            |-------|-------------|
            | Campaign ID | The platform's internal campaign identifier |
            | Campaign Name | Human-readable campaign name (matched to UTM campaign values by name or ID) |
            | Spend | Total spend for the day in the account's currency |
            | Clicks | Total ad clicks |
            | Impressions | Total ad impressions |

            **Payment providers** (Stripe, Braintree) — completed charges:

            | Field | Description |
            |-------|-------------|
            | Payment/Transaction ID | Platform ID (e.g., `pi_1234...`) used as order ID |
            | Revenue | Charge amount (converted from cents) |
            | Currency | Charge currency (USD, EUR, etc.) |
            | Email | Customer email — matched to identified visitors |
            | Timestamp | When the charge was created |

            Ad platforms sync every 6 hours; payment providers (Stripe, Braintree) sync every 15 minutes by default. Frequency is configurable per integration (5 min to 24 hours). All syncs run via Oban background jobs.

            ### ROAS on Revenue Attribution

            The **Revenue Attribution** page (under Conversions) shows ad performance data in two ways:

            **Ad Spend Overview** (top of page):
            - Total spend, ad-attributed revenue, ROAS, clicks, and impressions across all platforms
            - Per-platform breakdown with color-coded ROAS (green 3x+, yellow 1-3x, red <1x)

            **Campaign tab** — additional columns:
            - **Ad Spend** — total spend for that campaign
            - **ROAS** — Return on Ad Spend (revenue / spend)
            - **CPC** — Cost per Click (spend / clicks)

            **Other tabs** — standalone Ad Spend by Campaign table with spend, clicks, impressions, CPC, and CTR.

            ### Click ID Attribution (gclid / msclkid / fbclid)

            Spectabas automatically captures ad platform click IDs from landing page URLs:

            - **gclid** — Google Ads auto-tagging
            - **msclkid** — Microsoft/Bing Ads auto-tagging
            - **fbclid** — Meta/Facebook Ads click tracking

            When a visitor arrives with a click ID, Spectabas tags them as coming from that ad platform. If that visitor later makes a purchase, the revenue is attributed to the platform. This gives you **platform-level ROAS** (e.g., "Google Ads spent $5,000, generated $15,000 revenue").

            Click IDs are persisted in the visitor's session, so they're tracked even if the visitor browses multiple pages before converting.

            > **For campaign-level ROAS:** Add UTM parameters to your ad URLs. When combined with click IDs, UTM tags tell Spectabas *which specific campaign* drove the conversion, while the click ID verifies it was a real paid click. Set up URL templates in your ad platform using `{campaignname}` or `{campaignid}` (Google), `{CampaignName}` or `{CampaignId}` (Bing), or manual UTM tags (Meta). Spectabas automatically resolves campaign IDs to human-readable names.

            ### Token Security

            - OAuth tokens are encrypted at rest using AES-256-GCM derived from your `SECRET_KEY_BASE`
            - Tokens are never logged or exposed in the UI
            - Refresh tokens are used automatically when access tokens expire
            - Disconnecting an account immediately deletes all stored tokens

            ### Sync Schedule

            - Ad spend data syncs **every 6 hours** automatically; payment providers sync **every 15 minutes** by default
            - Sync frequency is configurable per integration (5 min to 24 hours)
            - Each sync fetches **yesterday's data** from all connected platforms
            - On first connection, the **last 30 days** are backfilled
            - If a sync fails (API error, token expired), the error is shown on the settings card and retried next cycle
            - Transient network errors are automatically retried up to 3 times before reporting failure
            - Token refresh happens automatically before each sync if the token is expired

            ### Troubleshooting

            - **No "Connect" button visible** — Click **Configure** first and enter your OAuth credentials (Client ID, Client Secret, etc.). The Connect button appears after credentials are saved.
            - **"Configure" shows empty fields** — Credentials haven't been entered yet for this site. Follow the setup steps above to get credentials from the ad platform.
            - **Error status on card** — The last sync failed. Common causes: expired token (click Disconnect then reconnect), revoked permissions in the ad platform, API rate limit (will retry automatically). Transient network errors (connection closed, timeout, refused) are retried automatically up to 3 times with exponential backoff before marking as failed.
            - **No ROAS showing on Revenue Attribution** — Campaign values don't match between your UTM parameters and the ad platform. Spectabas matches `utm_campaign` to both the campaign name and campaign ID from the ad platform. If using campaign IDs in your UTM tags, verify the ID matches what's in the ad platform.
            - **Data seems outdated** — Syncs happen every 6 hours. The most recent data is from yesterday (ad platforms don't report same-day spend in real time).
            - **Disconnecting doesn't delete spend data** — Historical ad spend data in ClickHouse is retained after disconnecting. Only the OAuth tokens are deleted.
            """
          },
          %{
            id: "google-ads-setup",
            title: "Google Ads",
            body: """
            Connect Google Ads to sync daily campaign spend data and calculate ROAS in Spectabas. Requires 3 credentials: Client ID, Client Secret, and Developer Token.

            > See also: [Integration Overview](/docs/conversions#integration-overview) for ROAS, Click IDs, and sync schedule.

            ### Step 1: Create a Google Cloud project

            - Go to Google Cloud Console (`console.cloud.google.com`)
            - Click the project dropdown at the top left, then **New Project**
            - Name it something like "Spectabas Analytics" and click **Create**
            - Make sure the new project is selected in the dropdown

            ### Step 2: Enable the Google Ads API

            - In the left sidebar, go to **APIs & Services > Library**
            - Search for "Google Ads API"
            - Click on it and press **Enable**

            ### Step 3: Create OAuth credentials

            - Go to **APIs & Services > Credentials** in the left sidebar
            - Click **+ Create Credentials > OAuth 2.0 Client ID**
            - If prompted, configure the OAuth consent screen first (choose "External", fill in app name and email)
            - For Application type, select **Web application**
            - Name it "Spectabas"
            - Under **Authorized redirect URIs**, click **Add URI** and enter: `https://www.spectabas.com/auth/ad/google_ads/callback`
            - Click **Create**
            - A dialog shows your **Client ID** and **Client Secret** — copy both

            ### Step 4: Get a Developer Token

            - Sign in to Google Ads (`ads.google.com`) with the account that manages your ad campaigns
            - Go to **Tools & Settings > Setup > API Center** (or visit `ads.google.com/aw/apicenter` directly)
            - If you don't have a developer token yet, click **Apply for access**
            - Choose **Basic access** (self-approved, sufficient for Spectabas)
            - Copy your **Developer Token**

            ### Step 5: Enter in Spectabas

            - Go to your site's **Settings** page
            - Scroll to **Ad Platform Integrations > Google Ads**
            - Click **Configure**
            - Paste the Client ID, Client Secret, and Developer Token
            - Click **Save Credentials**
            - Click **Connect** to authorize

            ### Google-specific notes

            - **MCC (Manager) accounts:** If your Google Ads account is managed by an MCC, Spectabas shows an account picker after connecting. Select the specific ad account(s) to sync.
            - **Basic API access** is sufficient — you do not need Standard access for reading your own campaign data.
            - **Auto-tagging:** Google Ads appends `gclid` to landing page URLs automatically. Spectabas captures this for platform-level ROAS attribution.
            - **UTM templates:** For campaign-level ROAS, set a tracking template in Google Ads: `{lpurl}?utm_source=google&utm_medium=cpc&utm_campaign={campaignname}` (or use `{campaignid}` — Spectabas resolves campaign IDs to names automatically)

            ### Troubleshooting

            - **"Access denied" after connecting** — Make sure the Google account you authorized has access to the Google Ads account. Manager (MCC) accounts need to select the correct sub-account.
            - **No spend data after sync** — Verify the Google Ads API is enabled in Google Cloud Console. Also check that the account has active campaigns with spend in the last 30 days.
            - **Developer token pending** — Basic access tokens are usually auto-approved. If yours is still pending, check the API Center in Google Ads for status.
            """
          },
          %{
            id: "bing-ads-setup",
            title: "Microsoft/Bing Ads",
            body: """
            Connect Microsoft Advertising (Bing Ads) to sync daily campaign spend data and calculate ROAS in Spectabas. Requires 3 credentials: Client ID, Client Secret, and Developer Token.

            > See also: [Integration Overview](/docs/conversions#integration-overview) for ROAS, Click IDs, and sync schedule.

            ### Step 1: Register an app in Azure

            - Go to Azure Portal (`portal.azure.com`)
            - Search for "App registrations" in the top search bar and click it
            - Click **+ New registration**
            - Name: "Spectabas Ad Sync"
            - Supported account types: **Accounts in any organizational directory** (Multitenant)
            - Redirect URI: select **Web** and enter `https://www.spectabas.com/auth/ad/bing_ads/callback`
            - Click **Register**

            ### Step 2: Get the Client ID

            - On the app's **Overview** page, copy the **Application (client) ID** — this is your Client ID

            ### Step 3: Create a Client Secret

            - In the left sidebar, click **Certificates & secrets**
            - Click **+ New client secret**
            - Enter a description (e.g., "Spectabas") and choose an expiry (24 months recommended)
            - Click **Add**
            - Copy the **Value** (not the Secret ID) — this is your Client Secret. It's only shown once.

            ### Step 4: Get a Developer Token

            - Go to Microsoft Advertising Developer Portal (`developers.ads.microsoft.com`)
            - Sign in with your Microsoft Advertising account
            - Request a **Developer Token** if you don't have one
            - Copy the token

            ### Step 5: Enter in Spectabas

            - Go to your site's **Settings > Ad Platform Integrations > Microsoft Ads**
            - Click **Configure**
            - Paste the Client ID, Client Secret, and Developer Token
            - Click **Save Credentials**, then **Connect**

            ### Bing-specific notes

            - **Auto-tagging:** Microsoft Ads appends `msclkid` to landing page URLs. Spectabas captures this for platform-level ROAS attribution.
            - **UTM templates:** For campaign-level ROAS, set a tracking template: `{lpurl}?utm_source=bing&utm_medium=cpc&utm_campaign={CampaignName}` (or use `{CampaignId}` — Spectabas resolves campaign IDs to names automatically)
            - **Client secret expiry:** Azure app secrets expire (24 months max). Set a calendar reminder to rotate before expiry. When it expires, update the secret in Spectabas settings and reconnect.

            ### Troubleshooting

            - **"Invalid client secret"** — Azure secrets expire. Check **Certificates & secrets** in Azure Portal. If expired, create a new secret and update it in Spectabas.
            - **No spend data** — Verify the Microsoft Advertising account has active campaigns. The developer token must also be approved.
            - **"Insufficient permissions"** — The Azure app registration must use "Multitenant" account type. Single-tenant apps cannot access the Microsoft Ads API.
            """
          },
          %{
            id: "meta-ads-setup",
            title: "Meta/Facebook Ads",
            body: """
            Connect Meta (Facebook) Ads to sync daily campaign spend data and calculate ROAS in Spectabas. Requires 2 credentials: App ID and App Secret.

            > See also: [Integration Overview](/docs/conversions#integration-overview) for ROAS, Click IDs, and sync schedule.

            ### Step 1: Create a Business App

            - Go to Meta for Developers (`developers.facebook.com`) and log in with the Facebook account that manages your ads
            - Click **My Apps** in the top right, then **Create App**
            - Meta may show either a use-case flow or a type-selection flow:
            - **If you see "What do you want your app to do?"** — select **Other**, then select **Business** as the app type
            - **If you see use-case options** — select **Advertise** or **Other** and choose **Business** when prompted
            - Enter an app name (e.g., "Spectabas Analytics")
            - Associate it with your Business portfolio if prompted (this is the Business Manager account that owns your ad accounts)
            - Click **Create App**

            > **Business app type is required.** Consumer apps cannot access the Marketing API or ad insights. If you accidentally created a Consumer app, delete it and start over with Business.

            ### Step 2: Add the Marketing API product

            - On your app's dashboard, scroll to the **Add Products** section
            - Find **Marketing API** and click **Set Up**
            - This enables the ad insights endpoints — no additional configuration needed within this product
            - The Marketing API does NOT create a separate token — Spectabas uses the OAuth2 token from Facebook Login

            ### Step 3: Add Facebook Login product

            - On the same dashboard, find **Facebook Login for Business** (or **Facebook Login**) and click **Set Up**
            - Choose **Web** as the platform
            - In the left sidebar, go to **Facebook Login > Settings**
            - Under **Valid OAuth Redirect URIs**, add: `https://www.spectabas.com/auth/ad/meta_ads/callback`
            - Make sure **Client OAuth Login** and **Web OAuth Login** are both **ON**
            - Click **Save Changes**

            ### Step 4: Switch to Live Mode

            - At the top of the App Dashboard, you'll see a toggle that says **Development** or **In Development**
            - Switch it to **Live**
            - Meta may require you to complete **Business Verification** first (verify your company identity at `business.facebook.com/settings/info`)
            - If you're the only person connecting (app admin), Development Mode works, but Live Mode is needed if other team members will connect their own accounts

            ### Step 5: Get App ID and Secret

            - In the left sidebar, go to **App Settings > Basic**
            - Your **App ID** is shown at the top of the page
            - Click **Show** next to **App Secret** and copy it
            - Both values are needed for Spectabas

            ### Step 6: Enter in Spectabas

            - Go to your site's **Settings > Ad Platform Integrations > Meta Ads**
            - Click **Configure**
            - Paste the App ID and App Secret
            - Click **Save Credentials**, then **Connect**
            - You'll be redirected to Facebook to authorize — grant the `ads_read` permission when prompted
            - Spectabas will fetch your accessible ad accounts and connect

            ### Meta-specific notes

            - **No app review needed.** The `ads_read` permission works with Standard Access for reading your own ad account data. You do NOT need to submit for Advanced Access or go through Meta's app review process.
            - **Token refresh:** Spectabas exchanges the initial token for a 60-day long-lived token. The sync worker automatically refreshes this before it expires. If a token does expire, disconnect and reconnect from the Settings page.
            - **All credentials are encrypted** at rest using AES-256-GCM and stored per-site in the database. No environment variables or server access needed.
            - **fbclid:** Meta appends `fbclid` to landing page URLs. Spectabas captures this for platform-level ROAS attribution.
            - **UTM tags:** Meta does not have auto-tagging templates like Google/Bing. Add UTM parameters manually in your ad's URL parameters field.

            ### Troubleshooting

            - **"App not set up" error** — Make sure both the Marketing API and Facebook Login products are added to your app. The Marketing API product must be added even though it doesn't create its own token.
            - **"Consumer app" error** — Delete the app and recreate it as a **Business** type. Consumer apps cannot access ad insights.
            - **Token expired after 60 days** — The auto-refresh should handle this, but if it fails, disconnect and reconnect from Settings. The new token will be exchanged for another 60-day long-lived token.
            - **No ad accounts found** — The Facebook user who authorized must have access to the ad account in Business Manager. Check **Business Settings > Ad Accounts** at `business.facebook.com`.
            - **Development vs Live mode** — In Development mode, only app admins can connect. Switch to Live mode if other team members need to connect their own accounts.
            """
          }
        ]
      },
      %{
        category: "Administration",
        items: [
          %{
            id: "stripe-setup",
            title: "Stripe Integration",
            body: """
            Import Stripe charges automatically as ecommerce events. Revenue Attribution, Revenue Cohorts, Buyer Patterns, and all ecommerce dashboards populate with zero custom code.

            ### Prerequisites

            - Your site must use the [server-side Identify API](/docs/api#identify) to associate visitor sessions with customer email addresses
            - Stripe charges are matched to visitors by email — unidentified visitors' charges still sync but won't be linked to browsing behavior

            ### Step 1: Create a Restricted API Key in Stripe

            A restricted key limits Spectabas to read-only access to payment data. This is more secure than using your default secret key.

            1. Log in to the [Stripe Dashboard](https://dashboard.stripe.com)
            2. Go to **Developers > API keys** (or visit `dashboard.stripe.com/apikeys`)
            3. Click **+ Create restricted key**
            4. **Name:** Enter "Spectabas Analytics" (or any name you'll recognize)
            5. **Permissions** — set exactly these:

            | Resource | Permission | Why |
            |----------|------------|-----|
            | **Charges** | **Read** | Fetches completed payments for revenue tracking |
            | **Customers** | **Read** | Looks up customer email to match charges to visitors |
            | **Refunds** | **Read** | Tracks refunds to adjust net revenue and LTV |
            | **Subscriptions** | **Read** | Enables MRR tracking, plan breakdown, and churn detection |
            | **Prices** | **Read** | Reads plan names and pricing for subscription details |
            | **Products** | **Read** | Reads product names for subscription plan labels |
            | All others | **None** | |

            6. Click **Create key**
            7. **Copy the key immediately** — it starts with `rk_live_` and won't be shown again

            > **Why restricted?** Your default secret key (`sk_live_`) has full access to refunds, transfers, customer management, and everything else. A restricted key with read-only access to the six resources above limits Spectabas to reading payment and subscription data — it cannot modify anything in your Stripe account.

            > **Test mode:** Use a test key (`rk_test_` or `sk_test_`) to verify the integration works before going live. Test charges won't appear in your analytics.

            ### Step 2: Connect in Spectabas

            1. Go to your site's **Settings** page
            2. Scroll to the **Integrations** section
            3. Find the **Stripe** card and click **Configure**
            4. Paste your restricted API key in the "Stripe Secret Key" field
            5. Click **Save Credentials**
            6. The card shows "Connected" — click **Sync Now** to pull charges immediately

            ### Step 3: Verify

            After syncing (takes a few seconds):

            - Go to **Conversions > Revenue Attribution** — revenue from Stripe charges should appear
            - Check the **Ecommerce** page for order counts and totals
            - Stripe charges show with order IDs starting with `pi_` (Stripe PaymentIntent IDs)

            ### How the Sync Works

            Each sync (every 6 hours, or manually via Sync Now) does three things:

            **1. Charges** — Fetches all succeeded charges for the sync period. Each charge is matched to an identified visitor via email. Written to ecommerce events with charge ID as order ID. Deduplicates by charge_id.

            **2. Refunds** — Fetches refunds and updates the `refund_amount` on the corresponding charge. Net revenue (revenue minus refunds) is used in LTV calculations and Revenue Attribution. Partial refunds are supported.

            **3. Subscriptions** — Takes a daily snapshot of all active, past_due, trialing, and canceled subscriptions. Calculates MRR per subscription (yearly plans divided by 12). Powers the **MRR & Subscriptions** dashboard page.

            **Sync schedule:** Every 6 hours (today + yesterday for charges/refunds, current state for subscriptions). Click Sync Now for immediate results.

            ### What You Get

            | Feature | Where | What It Shows |
            |---------|-------|---------------|
            | **Revenue Attribution** | Conversions > Revenue Attribution | Revenue from Stripe charges attributed to traffic sources |
            | **Customer LTV** | Visitor Profile page | Lifetime value card with net revenue, order count, refund total |
            | **MRR & Subscriptions** | Conversions > MRR & Subscriptions | Current MRR, active subs, plan breakdown, churn, MRR trend |
            | **Refund Tracking** | LTV card + Revenue Attribution | Net revenue = gross revenue minus refunds |
            | **Ecommerce** | Conversions > Ecommerce | Order counts, revenue totals, top products |

            ### Important Notes

            - **Double-counting:** If you already send the same transactions via the [Transaction API](/docs/api#ecommerce), Stripe import will create duplicate revenue. Use one method per payment flow — either Stripe import OR the Transaction API, not both.
            - **Refunds:** Refunds update the original charge's `refund_amount`. Net revenue (gross - refunds) is used in LTV and attribution. Disputes are treated as refunds.
            - **MRR calculation:** Monthly plans use their amount directly. Yearly plans are divided by 12 for the monthly equivalent. Only active, trialing, and past_due subscriptions count toward MRR.
            - **Multiple Stripe accounts:** Each site can connect one Stripe account. If you process payments through multiple Stripe accounts, connect the primary one.
            - **Currency:** Charge amounts are converted from Stripe's cents format (e.g., 9999 → $99.99). Currency symbols are displayed automatically ($, €, £, etc.).
            - **Clear Data:** If you connected the wrong Stripe account or need to start fresh, click the **Clear Data** button on the Stripe integration card. This deletes all imported ecommerce events and subscription snapshots. ClickHouse DELETE is async — data disappears within a few minutes.
            """
          },
          %{
            id: "braintree-setup",
            title: "Braintree Integration",
            body: """
            Import Braintree transactions, refunds, and subscriptions — the same features as the Stripe integration, for sites that use Braintree for payments.

            ### Prerequisites

            - Your site must use the [server-side Identify API](/docs/api#identify) to associate visitor sessions with customer emails
            - You need access to the [Braintree Control Panel](https://www.braintreegateway.com/login) with API key permissions

            ### Step 1: Get Your API Credentials

            1. Log in to the **Braintree Control Panel**
            2. Go to **Settings > API** (under the gear icon)
            3. You'll see three values:

            | Credential | Where to Find | Example |
            |------------|---------------|---------|
            | **Merchant ID** | Top of the API page | `abc123def456` |
            | **Public Key** | Under "API Keys" | `9xk2n4r5th...` |
            | **Private Key** | Click "View" next to the public key | `2f8d4a9b1c...` |

            > **Sandbox vs Production:** Braintree has separate sandbox and production environments. Use production credentials for live data. Sandbox credentials will only return test transactions.

            ### Step 2: Connect in Spectabas

            1. Go to your site's **Settings** page
            2. Scroll to **Integrations** > **Braintree**
            3. Click **Configure**
            4. Enter Merchant ID, Public Key, and Private Key
            5. Click **Save Credentials**
            6. The card shows "Connected" — click **Sync Now** to pull transactions immediately

            ### Step 3: Verify

            - Go to **Conversions > Ecommerce** — Braintree transactions should appear
            - Check **Conversions > MRR & Subscriptions** — if you have Braintree subscriptions, MRR data will populate
            - Visit a customer's **Visitor Profile** to see their Lifetime Value card

            ### What Gets Synced

            | Data | Description |
            |------|-------------|
            | **Transactions** | Settled/settling transactions → ecommerce events (revenue, email, timestamp) |
            | **Refunds** | Credit transactions → updates refund_amount on original transaction |
            | **Subscriptions** | Active/past_due/canceled → daily snapshots for MRR tracking |

            ### Sync Frequency

            Default: every 15 minutes. Configurable from the integration card (5 min to 24 hours).

            > **Braintree API:** Uses XML-based search API with Basic auth. All credentials are encrypted at rest with AES-256-GCM. Read-only access — Spectabas never modifies your Braintree data.
            """
          },
          %{
            id: "search-console-setup",
            title: "Google Search Console",
            body: """
            Import search analytics data — queries, impressions, clicks, CTR, and position rankings.

            ### Setup

            **Step 1: Enable the Search Console API**

            - Go to [Google Cloud Console](https://console.cloud.google.com) and select your project (use the same project as Google Ads if you have one)
            - Navigate to **APIs & Services > Library**
            - Search for **"Google Search Console API"** (not "Search Console" — the full name)
            - Click on it and press **Enable**

            **Step 2: Create or update OAuth credentials**

            If you already have Google Ads connected, you can reuse the same Client ID and Secret — just add the new redirect URI:

            - Go to [APIs & Services > Credentials](https://console.cloud.google.com/apis/credentials)
            - Click on your existing **OAuth 2.0 Client ID** (or create a new one: **+ Create Credentials > OAuth 2.0 Client ID**, type "Web application")
            - Under **Authorized redirect URIs**, click **Add URI** and enter:
              ```
              https://www.spectabas.com/auth/ad/google_search_console/callback
              ```
            - Click **Save**
            - Copy the **Client ID** and **Client Secret** (if creating new)

            > **Important:** The redirect URI must be exactly `https://www.spectabas.com/auth/ad/google_search_console/callback` — this is different from the Google Ads redirect URI. Both can be on the same OAuth client.

            > **"OAuth client was not found" error (401)?** This means the Client ID doesn't match any OAuth client in your Google Cloud project. Double-check you're using the correct Client ID from the Credentials page, and that the Search Console API is enabled on the same project.

            **Step 3: Add your site to Google Search Console**

            If your site isn't already verified in GSC:
            - Go to [Google Search Console](https://search.google.com/search-console)
            - Click **Add Property**
            - Choose **URL prefix** and enter your site URL (e.g., `https://www.roommates.com`)
            - Complete the verification (HTML tag, DNS record, or Google Analytics method)

            **Step 4: Connect in Spectabas**

            - Go to your site's **Settings** page
            - Scroll to **Integrations > Google Search Console**
            - Click **Configure**
            - Enter the Client ID and Client Secret from Step 2
            - Click **Save Credentials**
            - Click **Connect** — you'll be redirected to Google to authorize
            - Grant the "View Search Console data" permission
            - Spectabas auto-selects the matching GSC property for your site's domain

            ### What Gets Synced

            | Field | Description |
            |-------|-------------|
            | Query | The search term the user typed |
            | Page | The URL that appeared in search results |
            | Country | Searcher's country |
            | Device | Desktop, Mobile, or Tablet |
            | Clicks | Number of clicks from this query/page |
            | Impressions | Number of times this page appeared for this query |
            | CTR | Click-through rate (clicks / impressions) |
            | Position | Average ranking position in search results |

            Data syncs daily. GSC has a 2-3 day reporting delay — today's data won't be available until 2-3 days from now.

            ### Where It Appears

            **Acquisition > Search Keywords** — top queries, top pages, sortable by any column, filterable by source (Google/Bing/All) and date range. Also shows:
            - **Position Distribution** — how many keywords rank in top 3, 4-10, 11-20, 20+
            - **Ranking Changes** — keywords with significant position changes (7d vs prior 7d)
            - **CTR Opportunities** — high-impression queries with below-average click-through rates
            - **New & Lost Keywords** — keywords that appeared or disappeared in the last 7 days

            ### Troubleshooting

            - **"OAuth client was not found" (401 invalid_client)** — The Client ID you entered doesn't match an OAuth client in your Google Cloud project. Go to [Credentials](https://console.cloud.google.com/apis/credentials) and verify the Client ID. Make sure the Search Console API is enabled on the **same project** as the OAuth client.
            - **"redirect_uri_mismatch"** — The redirect URI in your OAuth client doesn't include the GSC callback. Add `https://www.spectabas.com/auth/ad/google_search_console/callback` to the Authorized redirect URIs list. Note: this is different from the Google Ads callback URI — both can be on the same client.
            - **"No Search Console properties found"** — Your Google account doesn't own or have access to any verified GSC properties. Go to [Google Search Console](https://search.google.com/search-console), add your site, and complete verification first.
            - **"Access denied" after authorization** — Make sure the Google account you're authorizing has at least "Restricted" permission on the GSC property. Site owners and full users can authorize.
            - **No data after connecting** — GSC data has a 2-3 day reporting delay. Data from today won't appear until 2-3 days later. Click Sync Now to pull the latest available data.
            - **Using same credentials as Google Ads?** — Yes, you can use the same Client ID and Secret. Just add the GSC redirect URI to the same OAuth client. The scopes are different and requested separately during authorization.
            """
          },
          %{
            id: "bing-webmaster-setup",
            title: "Bing Webmaster",
            body: """
            Import search analytics from Bing and Yahoo search.

            ### Setup

            - Go to [Bing Webmaster Tools](https://www.bing.com/webmasters) > Settings > API access
            - Copy your API key
            - Site Settings > Integrations > Bing Webmaster > Configure
            - Paste API key > Save Credentials

            ### What Gets Synced

            Same fields as Google Search Console (queries, clicks, impressions, CTR, position) but from Bing/Yahoo search traffic.

            Data appears on the **Search Keywords** page alongside Google data. Use the source filter to view Google-only, Bing-only, or combined.
            """
          },
          %{
            id: "api-keys-setup",
            title: "API Keys",
            body: """
            Generate API keys from **Account > Settings > API Keys**.

            - Click **+ New Key**
            - Enter a name (e.g., "Production", "CI/CD")
            - Copy the key immediately — it's only shown once
            - Use the key in the `Authorization: Bearer <key>` header

            Keys can be revoked at any time. Revoked keys stop working immediately.

            > **Security:** Only the SHA-256 hash of the key is stored. The plaintext is never saved.
            """
          },
          %{
            id: "two-factor",
            title: "Two-Factor Authentication",
            body: """
            Spectabas supports two types of 2FA:

            ### TOTP (Authenticator App)

            Use any TOTP-compatible app (Google Authenticator, Authy, 1Password, Bitwarden):

            - Go to **Account > Settings > Two-Factor Authentication**
            - Click **Set Up 2FA**
            - Scan the QR code with your authenticator app
            - Enter the 6-digit code to confirm

            ### Passkeys / Security Keys

            Use a passkey (Bitwarden, 1Password, YubiKey, Touch ID, Windows Hello):

            - Go to **Account > Settings > Security Keys (Passkeys)**
            - Click **+ Add Key**
            - Follow your browser's prompt to create or select a passkey
            - Name the key for identification

            You can register multiple security keys. Each can be removed individually.

            ### Admin: Force 2FA

            Administrators can require 2FA for specific users:

            - Go to **Admin > Users**
            - Click the **Optional/Required** toggle in the Force 2FA column
            - Users with "Required" must set up 2FA before accessing the dashboard
            """
          },
          %{
            id: "visitor-intent",
            title: "Visitor Intent Detection",
            body: """
            Spectabas automatically classifies every visitor by their behavior:

            | Intent | How it's detected |
            |--------|------------------|
            | Buying | Visited /pricing, /checkout, /signup, or came from paid ad |
            | Researching | Viewed 3+ pages, or paid traffic on content pages |
            | Comparing | Came from G2, Capterra, TrustRadius, ProductHunt |
            | Support | Visited /help, /contact, /docs, /faq |
            | Returning | Prior sessions, direct access |
            | Browsing | 1-2 pages, no conversion signals |
            | Bot | Datacenter IP, headless browser, no interaction |

            ### Using Intent Data

            - **Dashboard** — intent breakdown card shows visitor counts per category
            - **Click any intent** to see those visitors in the Visitor Log
            - **Segment filter** — use `visitor_intent is buying` to filter any report
            - **Visitor profiles** — intent pill shown on each visitor
            """
          },
          %{
            id: "browser-fingerprinting",
            title: "Browser Fingerprinting",
            body: """
            Spectabas generates a unique browser fingerprint for every visitor using canvas rendering, WebGL renderer strings, AudioContext output, and 15+ additional browser signals including installed fonts, screen properties, timezone, language, and hardware concurrency.

            ### How It Works

            The fingerprint is a stable hash that **survives cookie clearing, incognito mode, and VPN changes**. Because it is derived from browser and hardware characteristics rather than stored state, it persists across sessions even when visitors take steps to reset their identity.

            ### GDPR Mode Integration

            When GDPR mode is enabled (`data-gdpr="on"`), the browser fingerprint is used as the visitor ID instead of a cookie. This means accurate visitor deduplication without storing any cookies or requiring a consent banner.

            ### Visitor Profiles

            Each visitor profile includes a **Same Browser Fingerprint** section that lists other visitor IDs sharing the same fingerprint. This reveals alt accounts, shared devices, or attempts to create multiple identities.

            ### Visitor Deduplication

            In GDPR-off mode, when a visitor's cookie is lost — whether cleared manually, expired, used in incognito mode, or from a new browser session — Spectabas uses the browser fingerprint to match them to their existing visitor record instead of creating a duplicate. This prevents inflated visitor counts in your analytics by recognizing returning visitors even without their original cookie.

            The fingerprint is stored when a visitor first arrives at your site. On subsequent visits where no cookie is present, Spectabas looks up the fingerprint to find the existing visitor record and re-associates the session. If no match is found, a new visitor record is created as usual.

            This is fully automatic and requires no configuration. It works transparently alongside cookie-based tracking to ensure your unique visitor counts remain accurate.

            ### Use Cases

            - **Alt account detection** — identify users operating multiple accounts
            - **Ban evasion** — detect banned users returning under new visitor IDs
            - **Fraud detection** — correlate suspicious activity across sessions
            - **Spam correlation** — link spam submissions to a single browser

            No configuration is needed. Browser fingerprinting is automatic for all tracked sites.
            """
          },
          %{
            id: "form-abuse-detection",
            title: "Form Abuse Detection",
            body: """
            The Spectabas tracker automatically monitors form interactions on your site and detects suspicious submission patterns without any configuration.

            ### Detected Patterns

            The tracker watches for the following abuse signals:

            - **Rapid submission** — form submitted less than 2 seconds after page load
            - **Repeated submissions** — more than 3 form submissions on a single page
            - **Excessive pasting** — more than 3 paste events detected in form fields
            - **Click flooding** — more than 10 rapid clicks in a short time window

            ### Automatic Event Firing

            When suspicious patterns are detected, the tracker automatically fires a `_form_abuse` custom event. This event appears in your dashboard alongside other custom events and includes properties describing which signals were triggered.

            ### No Configuration Required

            Form abuse detection works on any site running the Spectabas tracker. There are no data attributes to set and no JavaScript API calls to make. The tracker handles all monitoring and event firing automatically.

            ### Combined with Fingerprinting

            Form abuse events are tagged with the visitor's browser fingerprint. This means you can correlate abuse across sessions, detect serial spammers who clear cookies between submissions, and link form abuse to specific visitor profiles for investigation.

            > **Example:** A spammer submits your contact form 5 times in 10 seconds, clears cookies, and tries again. Spectabas fires `_form_abuse` events for both sessions, and the browser fingerprint links them to the same person.
            """
          }
        ]
      }
    ]
  end
end
