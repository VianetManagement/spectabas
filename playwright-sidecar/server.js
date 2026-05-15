// Spectabas Playwright sidecar — exposes a single POST /audit endpoint.
// Real-browser HTML fetch for the SEO audit feature (v6.10.47+).
//
// Single Chromium instance kept warm across requests; each request gets
// its own isolated context (clean cookies, storage) so audits don't leak
// state between sites.
//
// Auth: optional bearer token via PLAYWRIGHT_API_KEY env. The Elixir
// side (Spectabas.SEO.HeadlessClient) doesn't send auth yet — set the
// env var to empty/absent for trust-network deployments, or wire the
// token check on both sides for a public Render service.

const express = require('express');
const { chromium } = require('playwright');

const app = express();
app.use(express.json({ limit: '256kb' }));

const PORT = process.env.PORT || 3000;
const API_KEY = process.env.PLAYWRIGHT_API_KEY || '';
const DEFAULT_TIMEOUT_MS = parseInt(process.env.DEFAULT_TIMEOUT_MS || '25000', 10);

// Default UA: real-Chrome with a SpectabasBot suffix.
//
// Why Chrome-flavored: Cloudflare's Bot Fight Mode and most generic
// "block bots" filters trigger on any UA containing the literal word
// "Bot" at the start. Putting "Bot" after a real Chrome string lets
// us pass those filters while still identifying ourselves in raw
// server logs and via the +https://... contact URL.
//
// The site admin can override this per-site via Site Settings →
// Content → SEO audit → User agent. We pass that string here in the
// POST body's `user_agent` field.
const USER_AGENT =
  process.env.USER_AGENT ||
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/131.0.0.0 Safari/537.36 SpectabasBot/1.0 (+https://www.spectabas.com/bot)';

let browser = null;
let launching = null;

async function getBrowser() {
  if (browser && browser.isConnected()) return browser;
  if (launching) return launching;

  launching = chromium.launch({
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
    ],
  });

  browser = await launching;
  launching = null;
  browser.on('disconnected', () => {
    browser = null;
  });
  return browser;
}

function authOk(req) {
  if (!API_KEY) return true;
  const header = req.get('authorization') || '';
  const expected = `Bearer ${API_KEY}`;
  return header === expected;
}

app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    browser: browser && browser.isConnected() ? 'connected' : 'cold',
    uptime_s: Math.round(process.uptime()),
  });
});

app.post('/audit', async (req, res) => {
  if (!authOk(req)) return res.status(401).json({ error: 'unauthorized' });

  const url = (req.body && req.body.url) || '';
  const timeoutMs = parseInt(req.body?.timeout_ms || DEFAULT_TIMEOUT_MS, 10);
  // Per-request UA override (set by the Elixir caller from
  // sites.seo_user_agent). Falls back to the sidecar's default.
  const userAgent =
    (req.body && typeof req.body.user_agent === 'string' && req.body.user_agent.trim()) ||
    USER_AGENT;

  if (!url || !/^https?:\/\//i.test(url)) {
    return res.status(400).json({ error: 'invalid_url', detail: 'url must be http(s)' });
  }

  const started = Date.now();
  let context;
  let page;

  try {
    const b = await getBrowser();
    context = await b.newContext({
      userAgent: userAgent,
      viewport: { width: 1280, height: 1024 },
      bypassCSP: true,
    });

    // v6.10.52: dropped the image/font/media route blocker. We now
    // want the full performance picture for the waterfall/diagnosis
    // panel — blocking heavy resources would give a misleadingly fast
    // load time. Adds ~3-5s per audit but the data is accurate to
    // what real users see.

    page = await context.newPage();
    const response = await page.goto(url, {
      waitUntil: 'domcontentloaded',
      timeout: timeoutMs,
    });

    // Settle JS-rendered content (React, Vue, etc.). networkidle is
    // best-effort with a short cap so we don't hang on SSE / WS pages.
    try {
      await page.waitForLoadState('networkidle', { timeout: 5000 });
    } catch (_) {
      // ignore — most pages don't reach true networkidle, that's fine
    }

    // Capture LCP via PerformanceObserver. Browsers fire LCP candidates
    // continuously; we settle 1s after the last candidate or 3s total.
    const lcpMs = await page
      .evaluate(() => {
        return new Promise((resolve) => {
          let lcp = 0;
          let lastUpdate = performance.now();

          try {
            const obs = new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) {
                if (entry.startTime > lcp) {
                  lcp = entry.startTime;
                  lastUpdate = performance.now();
                }
              }
            });
            obs.observe({ type: 'largest-contentful-paint', buffered: true });

            const settle = setInterval(() => {
              if (performance.now() - lastUpdate > 1000) {
                clearInterval(settle);
                obs.disconnect();
                resolve(Math.round(lcp));
              }
            }, 200);

            setTimeout(() => {
              clearInterval(settle);
              obs.disconnect();
              resolve(Math.round(lcp));
            }, 3000);
          } catch (e) {
            resolve(0);
          }
        });
      })
      .catch(() => 0);

    // Single page.evaluate to pull nav + resource + paint timing in
    // one round-trip. Each performance entry is small; total payload
    // is usually < 50KB even for resource-heavy pages.
    const perfData = await page
      .evaluate(() => {
        const nav = performance.getEntriesByType('navigation')[0];
        const navTiming = nav
          ? {
              dns: Math.round(nav.domainLookupEnd - nav.domainLookupStart),
              tcp: Math.round(nav.connectEnd - nav.connectStart),
              tls:
                nav.secureConnectionStart > 0
                  ? Math.round(nav.connectEnd - nav.secureConnectionStart)
                  : 0,
              ttfb: Math.round(nav.responseStart - nav.requestStart),
              download: Math.round(nav.responseEnd - nav.responseStart),
              dom_interactive: Math.round(nav.domInteractive),
              dom_content_loaded: Math.round(nav.domContentLoadedEventEnd),
              load: Math.round(nav.loadEventEnd),
              transfer_size: nav.transferSize || 0,
              encoded_body_size: nav.encodedBodySize || 0,
              decoded_body_size: nav.decodedBodySize || 0,
              protocol: nav.nextHopProtocol || '',
            }
          : null;

        const resources = performance.getEntriesByType('resource').map((r) => ({
          url: r.name,
          type: r.initiatorType,
          duration_ms: Math.round(r.duration),
          start_ms: Math.round(r.startTime),
          transfer_size: r.transferSize || 0,
          decoded_body_size: r.decodedBodySize || 0,
          render_blocking: r.renderBlockingStatus === 'blocking',
        }));

        const paint = {};
        for (const p of performance.getEntriesByType('paint')) {
          if (p.name === 'first-paint') paint.fp = Math.round(p.startTime);
          if (p.name === 'first-contentful-paint') paint.fcp = Math.round(p.startTime);
        }

        return { nav: navTiming, resources, paint };
      })
      .catch(() => ({ nav: null, resources: [], paint: {} }));

    const html = await page.content();
    const finalUrl = page.url();
    const statusCode = response ? response.status() : 0;
    const elapsed = Date.now() - started;

    res.json({
      html,
      status_code: statusCode,
      final_url: finalUrl,
      response_time_ms: elapsed,
      performance: {
        nav: perfData.nav,
        paint: perfData.paint,
        lcp_ms: lcpMs,
        resources: perfData.resources,
      },
    });
  } catch (e) {
    const elapsed = Date.now() - started;
    // Log to stdout so the Render Logs tab shows the actual reason,
    // not just the 502 access-log line. The body is also returned to
    // the caller (Elixir side) — both paths are useful for debugging.
    console.error(
      `[/audit ${url}] ${e.name || 'Error'}: ${e.message || 'unknown'}\n${e.stack || ''}`
    );
    res.status(502).json({
      error: e.message || 'fetch_failed',
      error_name: e.name || 'Error',
      response_time_ms: elapsed,
    });
  } finally {
    if (page) try { await page.close(); } catch (_) {}
    if (context) try { await context.close(); } catch (_) {}
  }
});

app.listen(PORT, () => {
  console.log(`Spectabas Playwright sidecar listening on :${PORT}`);
});

// Graceful shutdown so Render's deploy rollover doesn't leave zombie
// Chromium processes.
['SIGINT', 'SIGTERM'].forEach((sig) => {
  process.on(sig, async () => {
    console.log(`Received ${sig}, closing browser…`);
    if (browser) try { await browser.close(); } catch (_) {}
    process.exit(0);
  });
});
