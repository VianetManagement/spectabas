defmodule Spectabas.Workers.ProxySetupEmail do
  @moduledoc "One-shot: sends reverse proxy setup instructions for ad blocker evasion."

  use Oban.Worker, queue: :mailer, max_attempts: 1

  import Swoosh.Email
  alias Spectabas.Mailer

  @impl Oban.Worker
  def perform(_job) do
    html = proxy_setup_html()
    text = proxy_setup_text()

    email =
      new()
      |> to({"Jeff", "jeff@vianet.us"})
      |> from({"Spectabas", "noreply@spectabas.com"})
      |> subject("Spectabas Proxy Setup — Ad Blocker Evasion for roommates.com")
      |> html_body(html)
      |> text_body(text)

    case Mailer.deliver(email) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp proxy_setup_html do
    """
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 700px; margin: 0 auto; color: #1f2937; line-height: 1.6;">
      <div style="background: #7c3aed; padding: 24px 32px; border-radius: 8px 8px 0 0;">
        <h1 style="color: white; margin: 0; font-size: 22px;">Reverse Proxy Setup Guide</h1>
        <p style="color: #ddd6fe; margin: 4px 0 0; font-size: 14px;">Serve Spectabas tracking from www.roommates.com to bypass ad blockers</p>
      </div>

      <div style="padding: 32px; border: 1px solid #e5e7eb; border-top: 0; border-radius: 0 0 8px 8px;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">How It Works</h2>
        <p style="font-size: 14px;">Instead of loading the tracker from <code style="background: #f3f4f6; padding: 2px 6px; border-radius: 4px;">www.spectabas.com</code> (which ad blockers can target), you proxy it through your main domain:</p>

        <table style="width: 100%; border-collapse: collapse; font-size: 14px; margin: 16px 0;">
          <thead>
            <tr style="border-bottom: 2px solid #e5e7eb; text-align: left;">
              <th style="padding: 8px;">Visitor requests</th>
              <th style="padding: 8px;">Your server proxies to</th>
            </tr>
          </thead>
          <tbody>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px;"><code>www.roommates.com/t/v1.js</code></td>
              <td style="padding: 8px;"><code>www.spectabas.com/assets/v1.js</code></td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px;"><code>www.roommates.com/t/c/e</code></td>
              <td style="padding: 8px;"><code>www.spectabas.com/c/e</code></td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px;"><code>www.roommates.com/t/c/i</code></td>
              <td style="padding: 8px;"><code>www.spectabas.com/c/i</code></td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px;"><code>www.roommates.com/t/c/*</code></td>
              <td style="padding: 8px;"><code>www.spectabas.com/c/*</code></td>
            </tr>
          </tbody>
        </table>

        <p style="font-size: 14px;">To the browser and ad blockers, this looks like your own app code — same domain, same origin. Impossible to block without blocking your entire site.</p>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">Step 1: Add the Proxy Plug to Your Phoenix Router</h2>

        <p style="font-size: 14px;">Create a new file at <code>lib/roommates_web/plugs/analytics_proxy.ex</code> (adjust the module prefix to match your app):</p>

        <div style="background: #1e293b; color: #e2e8f0; padding: 16px; border-radius: 6px; font-family: monospace; font-size: 12px; overflow-x: auto; margin: 12px 0; line-height: 1.5;">
    <span style="color: #7dd3fc;">defmodule</span> RoommatesWeb.Plugs.AnalyticsProxy <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># Reverse proxy for Spectabas analytics.</span><br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># Forwards /t/* requests to www.spectabas.com</span><br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># so tracking is same-origin and ad-blocker-proof.</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">import</span> Plug.Conn<br>
    <br>
    &nbsp;&nbsp;<span style="color: #fbbf24;">@analytics_host</span> <span style="color: #86efac;">"https://www.spectabas.com"</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">def</span> <span style="color: #93c5fd;">init</span>(opts), <span style="color: #7dd3fc;">do</span>: opts<br>
    <br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># Proxy the tracker script</span><br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">def</span> <span style="color: #93c5fd;">call</span>(%{request_path: <span style="color: #86efac;">"/t/v1.js"</span>} = conn, _opts) <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;proxy_get(conn, <span style="color: #fbbf24;">@analytics_host</span> <> <span style="color: #86efac;">"/assets/v1.js"</span>)<br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># Proxy all beacon endpoints (/t/c/*)</span><br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">def</span> <span style="color: #93c5fd;">call</span>(%{request_path: <span style="color: #86efac;">"/t/c/"</span> <> rest} = conn, _opts) <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;target = <span style="color: #fbbf24;">@analytics_host</span> <> <span style="color: #86efac;">"/c/"</span> <> rest<br>
    &nbsp;&nbsp;&nbsp;&nbsp;qs = conn.query_string<br>
    &nbsp;&nbsp;&nbsp;&nbsp;url = <span style="color: #7dd3fc;">if</span> qs != <span style="color: #86efac;">""</span>, <span style="color: #7dd3fc;">do</span>: target <> <span style="color: #86efac;">"?"</span> <> qs, <span style="color: #7dd3fc;">else</span>: target<br>
    <br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #7dd3fc;">case</span> conn.method <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #86efac;">"GET"</span> -&gt; proxy_get(conn, url)<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #86efac;">"POST"</span> -&gt; proxy_post(conn, url)<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;_ -&gt; conn |&gt; send_resp(405, <span style="color: #86efac;">""</span>) |&gt; halt()<br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># Pass through all other requests</span><br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">def</span> <span style="color: #93c5fd;">call</span>(conn, _opts), <span style="color: #7dd3fc;">do</span>: conn<br>
    <br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">defp</span> <span style="color: #93c5fd;">proxy_get</span>(conn, url) <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #7dd3fc;">case</span> Req.get(url) <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{:ok, %{status: status, headers: headers, body: body}} -&gt;<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;conn<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;|&gt; put_resp_content_type(get_content_type(headers))<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;|&gt; put_resp_header(<span style="color: #86efac;">"cache-control"</span>, <span style="color: #86efac;">"public, max-age=3600"</span>)<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;|&gt; send_resp(status, body)<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;|&gt; halt()<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;_ -&gt;<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;conn |&gt; send_resp(502, <span style="color: #86efac;">""</span>) |&gt; halt()<br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">defp</span> <span style="color: #93c5fd;">proxy_post</span>(conn, url) <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;{:ok, body, conn} = read_body(conn)<br>
    <br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #6b7280;"># Forward client IP for accurate geo enrichment</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #6b7280;"># Cloudflare sets CF-Connecting-IP with real client IP.</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #6b7280;"># Forward it so Spectabas gets the visitor's real IP for geo.</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;client_ip =<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;(get_req_header(conn, <span style="color: #86efac;">"cf-connecting-ip"</span>) |&gt; List.first())<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;|&gt; Kernel.||(get_req_header(conn, <span style="color: #86efac;">"x-forwarded-for"</span>) |&gt; List.first())<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;|&gt; Kernel.||(:inet.ntoa(conn.remote_ip) |&gt; to_string())<br>
    <br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #7dd3fc;">case</span> Req.post(url,<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;body: body,<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;headers: [<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{<span style="color: #86efac;">"content-type"</span>, <span style="color: #86efac;">"application/json"</span>},<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{<span style="color: #86efac;">"x-spectabas-real-ip"</span>, client_ip},<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{<span style="color: #86efac;">"cf-connecting-ip"</span>, client_ip},<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{<span style="color: #86efac;">"x-forwarded-for"</span>, client_ip},<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{<span style="color: #86efac;">"user-agent"</span>, get_req_header(conn, <span style="color: #86efac;">"user-agent"</span>) |&gt; List.first() |&gt; Kernel.||(<span style="color: #86efac;">""</span>)}<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;]<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;) <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{:ok, %{status: status, body: resp_body}} -&gt;<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;conn |&gt; send_resp(status, resp_body || <span style="color: #86efac;">""</span>) |&gt; halt()<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;_ -&gt;<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;conn |&gt; send_resp(502, <span style="color: #86efac;">""</span>) |&gt; halt()<br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">defp</span> <span style="color: #93c5fd;">get_content_type</span>(headers) <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;headers<br>
    &nbsp;&nbsp;&nbsp;&nbsp;|&gt; Enum.find_value(<span style="color: #86efac;">"application/javascript"</span>, <span style="color: #7dd3fc;">fn</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{<span style="color: #86efac;">"content-type"</span>, v} -&gt; v<br>
    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;_ -&gt; <span style="color: #7dd3fc;">nil</span><br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #7dd3fc;">end</span>)<br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">end</span><br>
    <span style="color: #7dd3fc;">end</span>
        </div>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">Step 2: Add the Plug to Your Endpoint</h2>

        <p style="font-size: 14px;">In your <code>lib/roommates_web/endpoint.ex</code>, add the plug <strong>BEFORE</strong> <code>Plug.Parsers</code>:</p>

        <div style="background: #1e293b; color: #e2e8f0; padding: 16px; border-radius: 6px; font-family: monospace; font-size: 13px; overflow-x: auto; margin: 12px 0; line-height: 1.5;">
    <span style="color: #7dd3fc;">defmodule</span> RoommatesWeb.Endpoint <span style="color: #7dd3fc;">do</span><br>
    &nbsp;&nbsp;<span style="color: #7dd3fc;">use</span> Phoenix.Endpoint, otp_app: :roommates<br>
    <br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># ... session, static, etc ...</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #86efac; font-weight: bold;"># Analytics proxy — MUST be before Plug.Parsers</span><br>
    &nbsp;&nbsp;<span style="color: #86efac; font-weight: bold;">plug RoommatesWeb.Plugs.AnalyticsProxy</span><br>
    <br>
    &nbsp;&nbsp;plug Plug.Parsers,<br>
    &nbsp;&nbsp;&nbsp;&nbsp;parsers: [:urlencoded, :multipart, :json],<br>
    &nbsp;&nbsp;&nbsp;&nbsp;<span style="color: #6b7280;"># ...</span><br>
    <br>
    &nbsp;&nbsp;<span style="color: #6b7280;"># ... rest of endpoint ...</span><br>
    <span style="color: #7dd3fc;">end</span>
        </div>

        <div style="background: #fef2f2; border-left: 4px solid #ef4444; padding: 12px 16px; margin: 16px 0; font-size: 13px;">
          <strong>Critical:</strong> The plug MUST go in <code>endpoint.ex</code>, not <code>router.ex</code>. It must be placed BEFORE <code>Plug.Parsers</code> because the proxy needs to read the raw POST body. If <code>Plug.Parsers</code> runs first, it consumes the body and the proxy forwards empty payloads. Placing it in the router causes 403 errors from CSRF protection.
        </div>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">Step 3: Update Your Tracking Snippet</h2>

        <p style="font-size: 14px;">Replace your current Spectabas snippet with this one. The key change is the <code>data-proxy</code> attribute and loading the script from your own domain:</p>

        <div style="background: #1e293b; color: #e2e8f0; padding: 16px; border-radius: 6px; font-family: monospace; font-size: 13px; overflow-x: auto; margin: 12px 0; line-height: 1.5;">
    <span style="color: #6b7280;">&lt;!-- Old (can be blocked) --&gt;</span><br>
    <span style="color: #f87171; text-decoration: line-through;">&lt;script defer data-id="YOUR_KEY"<br>
    &nbsp;&nbsp;src="https://b.roommates.com/assets/v1.js"&gt;&lt;/script&gt;</span><br>
    <br>
    <span style="color: #6b7280;">&lt;!-- New (ad-blocker-proof) --&gt;</span><br>
    <span style="color: #86efac;">&lt;script defer data-id="YOUR_KEY"<br>
    &nbsp;&nbsp;data-proxy="https://www.roommates.com/t"<br>
    &nbsp;&nbsp;src="https://www.roommates.com/t/v1.js"&gt;&lt;/script&gt;</span>
        </div>

        <p style="font-size: 14px;">Just three attributes:</p>
        <ul style="font-size: 14px; padding-left: 20px;">
          <li><code>data-id</code> — your site's public key (same as before)</li>
          <li><code>data-proxy</code> — tells the tracker to send beacons to your proxy path instead of the analytics subdomain</li>
          <li><code>src</code> — loads the script from your main domain via the proxy (<code>/t/v1.js</code>)</li>
        </ul>
        <p style="font-size: 13px; color: #6b7280;">No <code>data-gdpr</code> needed — defaults to "off" (cookie-based tracking).</p>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">Step 4: Ensure Req is Available</h2>

        <p style="font-size: 14px;">The proxy plug uses <code>Req</code> for HTTP requests. If your roommates.com app doesn't already have it, add to <code>mix.exs</code>:</p>

        <div style="background: #1e293b; color: #e2e8f0; padding: 16px; border-radius: 6px; font-family: monospace; font-size: 13px; margin: 12px 0;">
    {:req, "~&gt; 0.5"}
        </div>

        <p style="font-size: 14px;">Then <code>mix deps.get</code>.</p>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">Step 5: Cloudflare WAF Exception</h2>

        <p style="font-size: 14px;">If your site uses Cloudflare, its Bot Fight Mode or Managed Challenge will block beacon POST requests to <code>/t/c/e</code> with a 403 before they reach your app. You must add a WAF skip rule:</p>

        <ol style="font-size: 14px; padding-left: 20px;">
          <li>Go to <strong>Security &gt; WAF &gt; Custom Rules</strong> in Cloudflare dashboard</li>
          <li>Create a new rule with expression: <code>(http.request.uri.path starts with "/t/")</code></li>
          <li>Action: <strong>Skip</strong> — check <strong>All remaining custom rules</strong> and <strong>All WAF Managed Rules</strong></li>
          <li>If you have <strong>Bot Fight Mode</strong> enabled (Security &gt; Bots), either disable it or upgrade to Super Bot Fight Mode which allows path-based exceptions</li>
        </ol>

        <div style="background: #fefce8; border-left: 4px solid #eab308; padding: 12px 16px; margin: 16px 0; font-size: 13px;">
          <strong>Why:</strong> Cloudflare's bot protection serves a JavaScript challenge page for POST requests. Browser <code>sendBeacon</code> and <code>fetch(keepalive)</code> cannot solve JS challenges — they are fire-and-forget. Without this exception, every tracking beacon gets eaten by Cloudflare.
        </div>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">Step 6: Deploy and Verify</h2>

        <ol style="font-size: 14px; padding-left: 20px;">
          <li>Deploy the roommates.com changes to Render</li>
          <li>Visit <code>www.roommates.com/t/v1.js</code> in your browser — you should see the Spectabas tracker JavaScript</li>
          <li>Open a page on roommates.com, check the Network tab — beacons should go to <code>www.roommates.com/t/c/e</code></li>
          <li>Check <code>/admin/ingest</code> on Spectabas — events should still flow normally</li>
          <li>Test with uBlock Origin in strict mode — tracking should still work</li>
        </ol>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">How the Proxy Preserves Data Accuracy</h2>

        <table style="width: 100%; border-collapse: collapse; font-size: 14px; margin: 12px 0;">
          <thead>
            <tr style="border-bottom: 2px solid #e5e7eb; text-align: left;">
              <th style="padding: 8px;">Data Point</th>
              <th style="padding: 8px;">How It's Preserved</th>
            </tr>
          </thead>
          <tbody>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Client IP</td>
              <td style="padding: 8px;">Proxy forwards <code>X-Spectabas-Real-IP</code> header with the real client IP. Spectabas checks this header first, bypassing Render's X-Forwarded-For overwrite. Geo enrichment uses the correct IP.</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">User Agent</td>
              <td style="padding: 8px;">Proxy forwards <code>User-Agent</code> header → browser/OS detection still works</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Cookies</td>
              <td style="padding: 8px;">The <code>_sab</code> cookie is set on the analytics subdomain. With proxy mode, cookies are still set/read by the tracker JS (same-origin). No change needed.</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Click IDs</td>
              <td style="padding: 8px;">gclid/msclkid/fbclid are captured by the tracker JS from the URL — unaffected by proxy</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Origin validation</td>
              <td style="padding: 8px;">Proxy makes server-to-server calls with no Origin/Referer/Sec-Fetch-Site headers. Spectabas's origin check allows these automatically (same as cURL or API calls).</td>
            </tr>
          </tbody>
        </table>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <h2 style="font-size: 18px; margin-bottom: 8px;">Cloudflare + Render Notes</h2>

        <ul style="font-size: 14px; padding-left: 20px;">
          <li><strong>Cloudflare IP forwarding:</strong> Since www.roommates.com is behind Cloudflare, the real client IP arrives in the <code>CF-Connecting-IP</code> header. The proxy plug reads this and forwards it to Spectabas via the trusted <code>X-Spectabas-Real-IP</code> header. Spectabas checks this custom header first, bypassing Render's X-Forwarded-For overwrite on the second hop.</li>
          <li><strong>Cloudflare Bot Fight Mode:</strong> Must be disabled or have a WAF skip rule for <code>/t/*</code> paths (see Step 5). Bot Fight Mode serves JS challenges that <code>sendBeacon</code> cannot solve.</li>
          <li><strong>Cloudflare caching:</strong> Cloudflare may cache <code>/t/v1.js</code> since it returns <code>Cache-Control: public, max-age=3600</code>. This is actually good — reduces proxy overhead. If you update the tracker, purge the Cloudflare cache or change the path.</li>
          <li><strong>Cloudflare DNS:</strong> The proxy goes directly to <code>www.spectabas.com</code> (Render's domain), bypassing Cloudflare entirely for the server-to-server hop. No DNS changes needed.</li>
          <li><strong>Render latency:</strong> The proxy adds ~10-50ms per request (internal HTTP call between Render services in the same Ohio region). This is fine for async beacons.</li>
          <li>No environment variables or Render service changes needed — it's just a plug in your existing app</li>
        </ul>

        <div style="background: #f0fdf4; border-left: 4px solid #22c55e; padding: 12px 16px; margin: 16px 0; font-size: 13px;">
          <strong>Result:</strong> Your tracking script and beacons are served from <code>www.roommates.com</code> — completely same-origin, indistinguishable from your own application code. No ad blocker can detect it without blocking your entire website.
        </div>

        <p style="font-size: 14px; margin-top: 24px; color: #6b7280;">
          Questions? Reply to this email or check the Spectabas docs.
        </p>
      </div>
    </div>
    """
  end

  defp proxy_setup_text do
    """
    SPECTABAS REVERSE PROXY SETUP — AD BLOCKER EVASION
    ====================================================

    STEP 1: Create lib/roommates_web/plugs/analytics_proxy.ex

    defmodule RoommatesWeb.Plugs.AnalyticsProxy do
      import Plug.Conn

      @analytics_host "https://www.spectabas.com"

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
          {:ok, %{status: status, headers: headers, body: body}} ->
            conn
            |> put_resp_content_type(get_content_type(headers))
            |> put_resp_header("cache-control", "public, max-age=3600")
            |> send_resp(status, body)
            |> halt()
          _ ->
            conn |> send_resp(502, "") |> halt()
        end
      end

      defp proxy_post(conn, url) do
        {:ok, body, conn} = read_body(conn)
        # Cloudflare sets CF-Connecting-IP with real client IP
        client_ip = (get_req_header(conn, "cf-connecting-ip") |> List.first())
          || (get_req_header(conn, "x-forwarded-for") |> List.first())
          || (:inet.ntoa(conn.remote_ip) |> to_string())

        case Req.post(url,
               body: body,
               headers: [
                 {"content-type", "application/json"},
                 {"x-spectabas-real-ip", client_ip},
                 {"cf-connecting-ip", client_ip},
                 {"x-forwarded-for", client_ip},
                 {"user-agent", get_req_header(conn, "user-agent") |> List.first() || ""}
               ]
             ) do
          {:ok, %{status: status, body: resp_body}} ->
            conn |> send_resp(status, resp_body || "") |> halt()
          _ ->
            conn |> send_resp(502, "") |> halt()
        end
      end

      defp get_content_type(headers) do
        headers
        |> Enum.find_value("application/javascript", fn
          {"content-type", v} -> v
          _ -> nil
        end)
      end
    end

    STEP 2: In endpoint.ex, add BEFORE Plug.Parsers (NOT in router.ex):
      plug RoommatesWeb.Plugs.AnalyticsProxy

    STEP 3: Update tracking snippet:
      <script defer data-id="YOUR_KEY"        data-proxy="https://www.roommates.com/t"
        src="https://www.roommates.com/t/v1.js"></script>

    STEP 4: Ensure Req is in mix.exs deps:
      {:req, "~> 0.5"}

    STEP 5: Cloudflare WAF Exception (if using Cloudflare):
      - Security > WAF > Custom Rules > Create Rule
      - Expression: (http.request.uri.path starts with "/t/")
      - Action: Skip — All remaining custom rules + All WAF Managed Rules
      - Also disable Bot Fight Mode (Security > Bots) or add path exception

    STEP 6: Deploy, then verify:
      - Visit www.roommates.com/t/v1.js — should see tracker JS
      - Check Network tab — beacons go to www.roommates.com/t/c/e
      - curl -X POST https://www.roommates.com/t/c/e?s=KEY -H "Content-Type: application/json" -d '{}' — should return 204
      - Test with uBlock Origin strict mode
    """
  end
end
