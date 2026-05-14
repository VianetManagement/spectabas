# Spectabas Playwright Sidecar

Small Node service that fetches URLs in a real Chromium browser for
the SEO audit feature. Deployed as a **separate Render web service**
from the main Spectabas app — they communicate over HTTP via the
`PLAYWRIGHT_URL` env var on the main service.

## Endpoints

- `GET /health` → `{status: "ok", browser: "connected"|"cold", uptime_s: N}`
- `POST /audit` body `{"url": "https://example.com", "timeout_ms": 25000}`
  → `{html, status_code, final_url, response_time_ms}`

---

## Deploy to Render (step-by-step)

The sidecar deploys from this `playwright-sidecar/` subdirectory of the
main `spectabas` repo via Docker. Render auto-builds the Docker image
from the `Dockerfile` here (which is based on Microsoft's official
`mcr.microsoft.com/playwright` image with Chromium + all OS deps
pre-installed).

### 1. Create a new Web Service on Render

1. Go to the [Render Dashboard](https://dashboard.render.com/).
2. Click **New +** → **Web Service**.
3. Pick **Build and deploy from a Git repository**.
4. Select the `VianetManagement/spectabas` repo (should already be
   connected; if not, **Connect account** → authorize GitHub).
5. Click **Connect**.

### 2. Configure the service

Fill in the form exactly:

| Field | Value |
|-------|-------|
| **Name** | `spectabas-playwright` |
| **Project** | (same project as the main spectabas service) |
| **Region** | **Ohio** (match the main service to keep latency low) |
| **Branch** | `main` |
| **Root Directory** | `playwright-sidecar` ← **important** — this tells Render to use the Dockerfile in the subdirectory, not the repo root |
| **Runtime** | **Docker** (Render should auto-detect from the Dockerfile; if it shows "Node", change it to Docker) |
| **Dockerfile Path** | `./Dockerfile` (default — relative to Root Directory) |
| **Docker Build Context Directory** | `.` (default) |
| **Instance Type** | **Starter** ($7/mo) |

Why **Starter and not Free**: the free tier spins down after 15 minutes
of inactivity. Cold start is ~10 seconds (Chromium boot + npm install
isn't the issue; Render's image cache handles that, it's the JIT
warm-up). Starter stays warm and gives you the 0.5 CPU / 512MB RAM
that Chromium actually needs.

### 3. Environment variables (optional)

Under **Advanced**, you can add:

- `PLAYWRIGHT_API_KEY` — if set, the sidecar requires
  `Authorization: Bearer <key>` on every `/audit` request. Adds
  protection if the Render service URL leaks. **For v1 leave this
  unset** — the Elixir side doesn't send auth yet. We'll wire both
  ends in a follow-up; until then, Render's URL is unguessable enough
  for trust-network use.
- `DEFAULT_TIMEOUT_MS` — per-audit timeout. Default `25000` (25s).
- `USER_AGENT` — Chromium UA string. Default
  `SpectabasBot/1.0 (+https://www.spectabas.com/bot)`.

### 4. Click Create Web Service

Build takes ~3-5 minutes the first time (downloads the Playwright
Docker base image, ~1.5GB). Subsequent deploys are faster — Render
caches the base layer.

### 5. Grab the service URL

Once the deploy is green, Render assigns it a URL like:

```
https://spectabas-playwright.onrender.com
```

Copy that — you'll need it for step 6.

Smoke test it:

```bash
curl https://spectabas-playwright.onrender.com/health
# → {"status":"ok","browser":"cold","uptime_s":42}

curl -X POST https://spectabas-playwright.onrender.com/audit \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}'
# → {"html":"<!doctype html>...","status_code":200,"final_url":"https://example.com/","response_time_ms":2341}
```

The first audit after a deploy is slower (Chromium cold start, ~5s);
subsequent audits are 1-3s because the browser stays warm in process
memory.

### 6. Wire it into the main Spectabas service

1. In the Render dashboard, click into the **main `srv-d72usa4r85hc73efqgpg` Spectabas service**.
2. Go to **Environment**.
3. Add a new env var:

   | Key | Value |
   |-----|-------|
   | `PLAYWRIGHT_URL` | `https://spectabas-playwright.onrender.com` (no trailing slash) |

4. **Save Changes**. Render will restart the main web service (~1 min).

### 7. Verify in the app

1. Open `/dashboard/sites/<site_id>/seo` on the live app.
2. The amber "Headless service not configured" banner should be gone.
3. Paste any URL into the "Audit this URL" field and click Audit.
4. Within 5-10 seconds (refresh the page), an audit row should appear with a score.

If the row appears with a score of 0 and a `fetch_failed` issue, check:
- Render dashboard → spectabas-playwright service → Logs — look for
  errors from the sidecar.
- The URL you pasted is reachable from the public internet (the
  sidecar can't reach localhost or private network URLs).

---

## What it does under the hood

- **One Chromium instance, hot.** Started lazily on first `/audit`,
  reused across requests. New `BrowserContext` per audit (clean
  cookies + storage) so audits don't leak state between sites.
- **Best-effort wait.** `domcontentloaded` (DOM parsed) + up to 5s of
  `networkidle` (no in-flight requests for 500ms) — captures React /
  Vue / Next.js JS-rendered content. The networkidle cap avoids
  hanging on SSE / WebSocket pages that never reach true idle.
- **Resource blocking.** Drops images, fonts, and media at the route
  layer — we only care about the rendered DOM for SEO analysis. Saves
  ~50% per-audit time + bandwidth. Stylesheets still load because
  they affect what content actually renders (display:none rules etc).
- **Graceful shutdown.** SIGINT / SIGTERM close the browser cleanly
  so Render's deploy rollover doesn't leave zombie Chromium processes.

## Resource notes

| Plan | RAM | Concurrent audits | $/mo |
|------|-----|-------------------|------|
| Free | 512MB | 1 (with cold-start lag) | $0 |
| Starter | 512MB | 1-2 | $7 |
| Standard | 2GB | 4-6 | $25 |

Starter is fine for crawl budgets ≤ 1000/week. Above that, bump to
Standard or run audits serially via Oban queue concurrency cap.

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

Local-dev requires Chromium installed via `npx playwright install
chromium` after `npm install`. The Render Docker build doesn't need
this — Chromium is in the base image.

## Updating Playwright

1. Bump `playwright` version in `package.json`.
2. Bump the `mcr.microsoft.com/playwright:vX.Y.Z-jammy` tag in
   `Dockerfile` to **the same version**. Mismatched versions = Chromium
   binary not found at runtime.
3. Push to main. Render auto-builds + redeploys.
