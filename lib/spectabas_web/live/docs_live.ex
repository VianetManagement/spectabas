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

        "<pre class=\"bg-gray-900 text-gray-100 rounded-lg p-4 text-xs overflow-x-auto my-3\"><code>#{escape(code)}</code></pre>"

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

            That's it! Pageviews will start appearing in your dashboard within seconds.

            > **Tip:** The tracker is only 8KB, loads asynchronously, and is designed to avoid ad blockers.
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

            ### Cross-Domain Tracking

            To track visitors across multiple domains as one session:

            ```html
            <script defer data-id="KEY" data-gdpr="off" data-xd="shop.example.com,blog.example.com" src="https://b.example.com/assets/v1.js"></script>
            ```

            This passes a temporary token via URL parameter (`_sabt`) when visitors click links between your domains. Only works with GDPR mode off.
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
            id: "channels",
            title: "All Channels",
            body: """
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

            Each channel shows pageviews, visitors, sessions, and how many distinct sources contributed. Click a channel to drill into the Sources page.
            """
          },
          %{
            id: "sources",
            title: "Sources",
            body: """
            Shows where your traffic comes from, organized in six tabs:

            - **Referrers** — domains that link to your site (google.com, twitter.com, etc.)
            - **UTM Source** — the `utm_source` parameter from tagged URLs
            - **UTM Medium** — the `utm_medium` parameter (cpc, email, social, etc.)
            - **UTM Campaign** — the `utm_campaign` parameter (spring_sale, product_launch, etc.)
            - **UTM Term** — the `utm_term` parameter (paid search keywords)
            - **UTM Content** — the `utm_content` parameter (ad variations, A/B test labels)

            Each UTM tab only shows entries where that parameter was set — no blank rows.

            **Click any source** to see the visitors from that source in the Visitor Log.

            Your own site's domain and spectabas.com are automatically filtered out to avoid self-referrals.
            """
          },
          %{
            id: "attribution",
            title: "Channel Attribution",
            body: """
            Shows which traffic channels bring visitors, using two attribution models:

            - **First Touch** — credits the channel that first brought the visitor to your site
            - **Last Touch** — credits the most recent channel before the visitor's latest activity


            > **Example:** A visitor first finds you via Google Ads, then returns a week later via an email newsletter. First touch credits Google Ads; last touch credits the newsletter.

            Use this to understand which channels attract new visitors vs which channels drive returning engagement.
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
          },
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
            id: "ad-integrations",
            title: "Ad Platform Integrations",
            body: """
            Connect your advertising accounts to track Return on Ad Spend (ROAS) directly in Spectabas. Supported platforms: **Google Ads**, **Microsoft/Bing Ads**, and **Meta/Facebook Ads**.

            ### How It Works

            - An admin connects each ad account via OAuth2 from **Site Settings > Ad Platform Integrations**
            - Spectabas syncs daily campaign spend data (spend, clicks, impressions) every 6 hours
            - The **Revenue Attribution** page joins ad spend with purchase data to calculate ROAS per campaign

            ### Setting Up

            ### Google Ads (3 credentials: Client ID, Client Secret, Developer Token)

            **Step 1: Create a Google Cloud project**

            - Go to Google Cloud Console (`console.cloud.google.com`)
            - Click the project dropdown at the top left, then **New Project**
            - Name it something like "Spectabas Analytics" and click **Create**
            - Make sure the new project is selected in the dropdown

            **Step 2: Enable the Google Ads API**

            - In the left sidebar, go to **APIs & Services > Library**
            - Search for "Google Ads API"
            - Click on it and press **Enable**

            **Step 3: Create OAuth credentials**

            - Go to **APIs & Services > Credentials** in the left sidebar
            - Click **+ Create Credentials > OAuth 2.0 Client ID**
            - If prompted, configure the OAuth consent screen first (choose "External", fill in app name and email)
            - For Application type, select **Web application**
            - Name it "Spectabas"
            - Under **Authorized redirect URIs**, click **Add URI** and enter: `https://www.spectabas.com/auth/ad/google_ads/callback`
            - Click **Create**
            - A dialog shows your **Client ID** and **Client Secret** — copy both

            **Step 4: Get a Developer Token**

            - Sign in to Google Ads (`ads.google.com`) with the account that manages your ad campaigns
            - Go to **Tools & Settings > Setup > API Center** (or visit `ads.google.com/aw/apicenter` directly)
            - If you don't have a developer token yet, click **Apply for access**
            - Choose **Basic access** (self-approved, sufficient for Spectabas)
            - Copy your **Developer Token**

            **Step 5: Enter in Spectabas**

            - Go to your site's **Settings** page
            - Scroll to **Ad Platform Integrations > Google Ads**
            - Click **Configure**
            - Paste the Client ID, Client Secret, and Developer Token
            - Click **Save Credentials**
            - Click **Connect** to authorize

            ---

            ### Microsoft/Bing Ads (3 credentials: Client ID, Client Secret, Developer Token)

            **Step 1: Register an app in Azure**

            - Go to Azure Portal (`portal.azure.com`)
            - Search for "App registrations" in the top search bar and click it
            - Click **+ New registration**
            - Name: "Spectabas Ad Sync"
            - Supported account types: **Accounts in any organizational directory** (Multitenant)
            - Redirect URI: select **Web** and enter `https://www.spectabas.com/auth/ad/bing_ads/callback`
            - Click **Register**

            **Step 2: Get the Client ID**

            - On the app's **Overview** page, copy the **Application (client) ID** — this is your Client ID

            **Step 3: Create a Client Secret**

            - In the left sidebar, click **Certificates & secrets**
            - Click **+ New client secret**
            - Enter a description (e.g., "Spectabas") and choose an expiry (24 months recommended)
            - Click **Add**
            - Copy the **Value** (not the Secret ID) — this is your Client Secret. It's only shown once.

            **Step 4: Get a Developer Token**

            - Go to Microsoft Advertising Developer Portal (`developers.ads.microsoft.com`)
            - Sign in with your Microsoft Advertising account
            - Request a **Developer Token** if you don't have one
            - Copy the token

            **Step 5: Enter in Spectabas**

            - Go to your site's **Settings > Ad Platform Integrations > Microsoft Ads**
            - Click **Configure**
            - Paste the Client ID, Client Secret, and Developer Token
            - Click **Save Credentials**, then **Connect**

            ---

            ### Meta/Facebook Ads (2 credentials: App ID, App Secret)

            **Step 1: Create a Meta Developer App**

            - Go to Meta for Developers (`developers.facebook.com`) and log in
            - Click **My Apps** in the top right, then **Create App**
            - Select **Other** for "What do you want your app to do?"
            - Select **Business** as the app type
            - Enter an app name (e.g., "Spectabas Analytics") and click **Create App**

            **Step 2: Set up Facebook Login**

            - On the app dashboard, find **Facebook Login** and click **Set Up**
            - Choose **Web**
            - In the left sidebar, go to **Facebook Login > Settings**
            - Under **Valid OAuth Redirect URIs**, add: `https://www.spectabas.com/auth/ad/meta_ads/callback`
            - Click **Save Changes**

            **Step 3: Get App ID and Secret**

            - In the left sidebar, go to **App Settings > Basic**
            - Your **App ID** is shown at the top
            - Click **Show** next to **App Secret** and copy it

            **Step 4: Request ads_read permission**

            - In the left sidebar, go to **App Review > Permissions and Features**
            - Search for **ads_read** and click **Request** (this allows reading ad insights data)
            - Follow the review process (for Business-type apps with your own ad account, this is typically auto-approved)

            **Step 5: Enter in Spectabas**

            - Go to your site's **Settings > Ad Platform Integrations > Meta Ads**
            - Click **Configure**
            - Paste the App ID and App Secret
            - Click **Save Credentials**, then **Connect**

            > **All credentials are encrypted** at rest using AES-256-GCM and stored per-site in the database. No environment variables or server access needed. Each site can use its own OAuth apps or share credentials across sites.

            ### Connecting an Account

            - Go to your site's **Settings** page
            - Scroll to **Ad Platform Integrations**
            - Click **Configure** on the platform you want to set up
            - Enter your OAuth credentials and click **Save Credentials**
            - Click **Connect** — you'll be redirected to the ad platform to authorize access
            - After granting access, you'll be returned to Spectabas and the card will show "Connected" with the account name and last sync time

            ### What Gets Synced

            For each connected account, Spectabas pulls daily data:

            | Field | Description |
            |-------|-------------|
            | Campaign ID | The platform's internal campaign identifier |
            | Campaign Name | Human-readable campaign name (should match your UTM campaign values) |
            | Spend | Total spend for the day in the account's currency |
            | Clicks | Total ad clicks |
            | Impressions | Total ad impressions |

            Data is synced every 6 hours via an Oban background job. On first connection, the last 30 days are backfilled.

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

            > **For campaign-level ROAS:** Add UTM parameters to your ad URLs. When combined with click IDs, UTM tags tell Spectabas *which specific campaign* drove the conversion, while the click ID verifies it was a real paid click. Set up URL templates in your ad platform using `{campaignname}` (Google), `{CampaignName}` (Bing), or manual UTM tags (Meta).

            ### Token Security

            - OAuth tokens are encrypted at rest using AES-256-GCM derived from your `SECRET_KEY_BASE`
            - Tokens are never logged or exposed in the UI
            - Refresh tokens are used automatically when access tokens expire
            - Disconnecting an account immediately deletes all stored tokens

            ### Sync Schedule

            - Ad spend data syncs **every 6 hours** automatically
            - Each sync fetches **yesterday's data** from all connected platforms
            - On first connection, the **last 30 days** are backfilled
            - If a sync fails (API error, token expired), the error is shown on the settings card and retried next cycle
            - Token refresh happens automatically before each sync if the token is expired

            ### Troubleshooting

            - **No "Connect" button visible** — Click **Configure** first and enter your OAuth credentials (Client ID, Client Secret, etc.). The Connect button appears after credentials are saved.
            - **"Configure" shows empty fields** — Credentials haven't been entered yet for this site. Follow the setup steps above to get credentials from the ad platform.
            - **Error status on card** — The last sync failed. Common causes: expired token (click Disconnect then reconnect), revoked permissions in the ad platform, API rate limit (will retry automatically).
            - **No ROAS showing on Revenue Attribution** — Campaign names don't match between your UTM parameters and the ad platform. Check that `utm_campaign` values in your ad URLs exactly match the campaign names in Google/Bing/Meta.
            - **Data seems outdated** — Syncs happen every 6 hours. The most recent data is from yesterday (ad platforms don't report same-day spend in real time).
            - **Disconnecting doesn't delete spend data** — Historical ad spend data in ClickHouse is retained after disconnecting. Only the OAuth tokens are deleted.
            """
          }
        ]
      },
      %{
        category: "Administration",
        items: [
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
