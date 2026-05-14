# Spectabas Playwright Sidecar

Small Node service that renders pages in a real Chromium browser for
the SEO audit feature. The Elixir app calls this over HTTP to fetch
the rendered HTML of a customer URL.

## Endpoints

- `GET /health` — liveness check
- `POST /audit` — body: `{"url": "https://example.com", "timeout_ms": 25000}` →
  returns `{html, status_code, final_url, response_time_ms}`

## Deployment (Render)

1. **Create a new Web Service** from this directory (`playwright-sidecar/`).
2. **Environment:** `Node`. Render auto-detects.
3. **Build command:** `npm install` (the `postinstall` script downloads
   the Chromium binary via `playwright install --with-deps`).
4. **Start command:** `node server.js`
5. **Plan:** Starter ($7/mo) recommended. The free tier sleeps after 15 min
   of inactivity and the cold start (Chromium boot) makes the first audit
   per session take 15-20s. Starter stays warm.
6. **Env vars:**
   - `PLAYWRIGHT_API_KEY` (optional) — if set, the sidecar requires
     `Authorization: Bearer <key>` on every `/audit` call. Set the same
     value on the Elixir side via TODO (not wired yet — out-of-band trust
     for v1, since the sidecar runs on the same Render team).
   - `DEFAULT_TIMEOUT_MS` (optional, default 25000)
   - `USER_AGENT` (optional, default `SpectabasBot/1.0 (+https://www.spectabas.com/bot)`)
7. **Set the Render service URL** as `PLAYWRIGHT_URL` on the main
   `srv-d72usa4r85hc73efqgpg` Spectabas web service. The Elixir
   `Spectabas.SEO.HeadlessClient` reads this env var.

## What it does

- Single Chromium instance kept warm across requests (cold start is
  ~3s, warm fetches are 2-5s).
- New isolated browser context per audit so cookies / storage don't
  leak between sites.
- Blocks images / fonts / media at the route layer — we only care
  about the rendered DOM for SEO analysis. Saves ~50% on per-audit
  time + bandwidth.
- Waits for `domcontentloaded` then up to 5s of `networkidle` so
  React / Vue / Next.js JS-rendered content is fully present in the
  HTML when we capture it. The `networkidle` wait is best-effort with
  a short cap so SSE / WebSocket pages don't hang.

## Local dev

```bash
cd playwright-sidecar
npm install
node server.js  # listens on :3000

# In another terminal:
curl -X POST http://localhost:3000/audit \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}'
```

## Resource notes

- Memory: ~200-400MB baseline + ~150MB per concurrent audit. Render
  Starter (512MB) handles 1-2 concurrent. For bulk-audit budgets >
  500/week, bump to Standard ($25/mo, 2GB) or run audits one-at-a-time
  via Oban's `:limit` setting on the worker queue.
- CPU: spiky. Chromium peaks 1 CPU per active audit; idle is near 0.
- Disk: Chromium binary is ~200MB. Render's image cache handles this.
