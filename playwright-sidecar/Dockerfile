# Use Microsoft's official Playwright image — Chromium + all OS deps
# (libnss3, libatk1.0, libxss1, fonts, etc.) baked in. Pinned to the
# EXACT Playwright version declared in package.json so the runtime
# binary matches the API surface.
#
# IMPORTANT: bump BOTH together when upgrading. The npm package and
# Docker image must be the same major.minor.patch. Use a non-^/~
# version in package.json (exact pin) to prevent npm from picking a
# newer version than the base image ships.
FROM mcr.microsoft.com/playwright:v1.60.0-jammy

WORKDIR /app

# Install only production deps. The Chromium binary is already inside
# the base image at /ms-playwright, so we skip the playwright postinstall
# browser download entirely.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
COPY package*.json ./
RUN npm ci --omit=dev

# Copy the server last so app code changes don't bust the npm-install
# cache layer on rebuild.
COPY server.js ./

# Render injects PORT at runtime. Default for local dev.
ENV PORT=3000
EXPOSE 3000

# Run as the non-root playwright user that's already set up in the
# base image — Chromium refuses to start as root without --no-sandbox,
# which our server.js sets anyway, but the unprivileged user is a
# better default.
USER pwuser

CMD ["node", "server.js"]
