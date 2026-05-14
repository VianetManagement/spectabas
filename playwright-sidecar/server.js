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
      // Block heavy resources to keep audits fast — we only care about
      // the HTML/DOM, not images/fonts. Saves a few seconds per audit.
      bypassCSP: true,
    });

    // Route blocker: drop image/font/media requests. Stylesheets still
    // load because they can carry display:none or visibility:hidden
    // rules that change which content is rendered for SEO analysis.
    await context.route('**/*', (route) => {
      const type = route.request().resourceType();
      if (type === 'image' || type === 'font' || type === 'media') {
        return route.abort();
      }
      return route.continue();
    });

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

    const html = await page.content();
    const finalUrl = page.url();
    const statusCode = response ? response.status() : 0;
    const elapsed = Date.now() - started;

    res.json({
      html,
      status_code: statusCode,
      final_url: finalUrl,
      response_time_ms: elapsed,
    });
  } catch (e) {
    const elapsed = Date.now() - started;
    res.status(502).json({
      error: e.message || 'fetch_failed',
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
