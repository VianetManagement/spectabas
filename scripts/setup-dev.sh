#!/usr/bin/env bash
#
# Bootstrap a Spectabas dev environment on a fresh Debian/Ubuntu box.
#
# What this does:
#   1. Installs system build deps + Postgres + git/curl + GitHub CLI
#   2. Installs asdf + Erlang 27.2 + Elixir 1.18.2-otp-27 + Node 22.13.0
#   3. Generates an SSH key (if absent), authenticates with GitHub,
#      registers the key with your GitHub account
#   4. Clones github.com:VianetManagement/spectabas → ~/Claude/spectabas
#   5. Installs Hex/Rebar, fetches mix deps
#   6. Creates Postgres dev + test DBs (user "postgres", pass "postgres")
#   7. Runs `mix ecto.setup` and `mix test` as a smoke check
#
# What it does NOT do (one-time manual steps below):
#   - Copy your Claude `memory/` directory from your old machine
#   - Set ClickHouse env vars (analytics/test suite don't need a local CH)
#   - Set production secrets (R2, MaxMind, Anthropic, Render, etc.)
#
# Idempotent: re-running skips steps that are already done.
#
# Usage:
#   bash setup-dev.sh
#
# Tested on Debian 12 / 13 (trixie) + Ubuntu 22.04 / 24.04.

set -euo pipefail

REPO_URL="${REPO_URL:-git@github.com:VianetManagement/spectabas.git}"
WORK_DIR="${WORK_DIR:-${HOME}/Claude/spectabas}"
ASDF_DIR="${ASDF_DIR:-${HOME}/.asdf}"
ASDF_VERSION="${ASDF_VERSION:-v0.14.1}"
PG_USER="postgres"
PG_PASS="postgres"
GIT_NAME="${GIT_NAME:-Jeff at Vianet}"
GIT_EMAIL="${GIT_EMAIL:-jeff@vianet.us}"

bold() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[33m!! %s\033[0m\n" "$*"; }
die() { printf "\033[31mxx %s\033[0m\n" "$*" >&2; exit 1; }

# --- Preflight ---

[[ "$EUID" -ne 0 ]] || die "Run as a normal user with sudo access, not as root."
command -v sudo >/dev/null || die "sudo is required."
[[ -f /etc/debian_version ]] || warn "This script targets Debian/Ubuntu. Continuing anyway."

# --- 1. System packages ---

bold "Installing system packages (sudo will prompt for password)"
sudo apt-get update
sudo apt-get install -y \
  build-essential autoconf m4 \
  libncurses-dev libssl-dev libxslt1-dev libffi-dev \
  unixodbc-dev xsltproc fop libxml2-utils \
  libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev \
  inotify-tools \
  curl git ca-certificates gnupg \
  postgresql postgresql-contrib

# --- 2. asdf ---

if [[ ! -d "$ASDF_DIR" ]]; then
  bold "Installing asdf $ASDF_VERSION"
  git clone --depth 1 --branch "$ASDF_VERSION" https://github.com/asdf-vm/asdf.git "$ASDF_DIR"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] && ! grep -q "asdf.sh" "$rc" && \
      printf '\n. "%s/asdf.sh"\n' "$ASDF_DIR" >> "$rc"
  done
else
  bold "asdf already installed at $ASDF_DIR"
fi

# shellcheck source=/dev/null
. "$ASDF_DIR/asdf.sh"
export PATH="$ASDF_DIR/shims:$ASDF_DIR/bin:$PATH"

bold "Adding asdf plugins"
asdf plugin add erlang  https://github.com/asdf-vm/asdf-erlang.git  2>/dev/null || true
asdf plugin add elixir  https://github.com/asdf-vm/asdf-elixir.git  2>/dev/null || true
asdf plugin add nodejs  https://github.com/asdf-vm/asdf-nodejs.git  2>/dev/null || true

# --- 3. Git identity + SSH key ---

if [[ -z "$(git config --global user.name || true)" ]]; then
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  git config --global init.defaultBranch main
fi

if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  bold "Generating SSH key (ed25519)"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$HOME/.ssh/id_ed25519" -N ""
fi

# Trust github.com so the upcoming clone doesn't prompt
ssh-keyscan -t ed25519,rsa github.com 2>/dev/null >> "$HOME/.ssh/known_hosts"
sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts"

# --- 4. GitHub CLI + auth ---

if ! command -v gh >/dev/null; then
  bold "Installing GitHub CLI (gh)"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  sudo chmod a+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y gh
fi

if ! gh auth status >/dev/null 2>&1; then
  bold "Authenticating with GitHub"
  echo "    A browser will open. When prompted:"
  echo "      - Account → GitHub.com"
  echo "      - Protocol → SSH"
  echo "      - Upload SSH key → Yes (uses ~/.ssh/id_ed25519.pub)"
  echo "      - Authentication → Login with a web browser"
  gh auth login --hostname github.com --git-protocol ssh --web
else
  bold "Already authenticated with GitHub as $(gh api user --jq .login)"
fi

# Make sure the SSH key is registered with GitHub (idempotent)
if ! gh ssh-key list 2>/dev/null | grep -q "$(cut -d' ' -f2 < "$HOME/.ssh/id_ed25519.pub")"; then
  gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$(hostname)-$(date +%Y%m%d)" || \
    warn "Couldn't register SSH key automatically; add it manually at https://github.com/settings/keys"
fi

# --- 5. Clone the repo ---

if [[ ! -d "$WORK_DIR" ]]; then
  bold "Cloning $REPO_URL → $WORK_DIR"
  mkdir -p "$(dirname "$WORK_DIR")"
  git clone "$REPO_URL" "$WORK_DIR"
else
  bold "Repo already cloned at $WORK_DIR — pulling latest"
  git -C "$WORK_DIR" pull --ff-only || warn "Pull failed (local changes?). Continuing."
fi

cd "$WORK_DIR"

# --- 6. Install Erlang / Elixir / Node ---

bold "Installing toolchain from .tool-versions (Erlang build takes ~15 min, be patient)"
# Build flag that gives modern Erlang on Debian a usable WX (wx_gtk3) build
export KERL_CONFIGURE_OPTIONS="--disable-debug --without-javac --enable-wx"
asdf install
asdf reshim 2>/dev/null || true

bold "Installing Hex + Rebar"
mix local.hex --force
mix local.rebar --force

# --- 7. Postgres dev user + DBs ---

bold "Setting up Postgres dev user + databases"
sudo service postgresql start || sudo systemctl start postgresql

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_user WHERE usename = '$PG_USER'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE USER $PG_USER WITH SUPERUSER PASSWORD '$PG_PASS';"
else
  # The `postgres` superuser is created by the apt package without a known
  # password, so on a fresh box we land here and must ALTER to set one —
  # otherwise `mix ecto.setup` fails with 28P01 invalid_password.
  echo "    user $PG_USER already exists — ensuring password + SUPERUSER"
  sudo -u postgres psql -c "ALTER USER $PG_USER WITH SUPERUSER PASSWORD '$PG_PASS';"
fi

for db in spectabas_dev spectabas_test; do
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
    sudo -u postgres createdb "$db" -O "$PG_USER"
    echo "    created database $db"
  else
    echo "    database $db already exists"
  fi
done

# --- 8. Project deps + migrations ---

bold "Fetching mix deps"
mix deps.get

bold "Running ecto.setup (creates schema + runs all migrations)"
mix ecto.setup

bold "Compiling project (strict)"
mix compile --warnings-as-errors

# --- 9. Smoke test ---

bold "Running the test suite as a smoke check"
if mix test; then
  printf "\n\033[32m✓ All tests passed — dev environment is ready.\033[0m\n"
else
  warn "Some tests failed. The flaky PerformanceLive test at"
  warn "test/spectabas_web/live/performance_live_test.exs:170 is known."
  warn "Anything else is worth investigating."
fi

# --- 10. Final instructions ---

cat <<EOF

────────────────────────────────────────────────────────────────────────
Spectabas dev environment ready at: $WORK_DIR

Open a NEW shell (or \`source ~/.bashrc\`) so asdf is on PATH, then:

    cd $WORK_DIR
    mix phx.server      # → http://localhost:4000

One-time manual steps to fully pick up where you left off:

1. Copy your Claude memory from the source machine:

       rsync -av \\
         <source_host>:/home/<user>/.claude/projects/-home-<user>-Claude/memory/ \\
         $HOME/.claude/projects/-home-$USER-Claude/memory/

   (Create parent dirs first: \`mkdir -p $HOME/.claude/projects/-home-$USER-Claude\`.
    The path slug is your cwd with slashes replaced by hyphens.)

2. (Optional) Local ClickHouse — only if you want to exercise analytics
   queries locally. The 1058-test suite passes without it. Easiest path:

       docker run -d --name spectabas-ch -p 8123:8123 -p 9000:9000 \\
         clickhouse/clickhouse-server

   Then export CLICKHOUSE_URL=http://localhost:8123 before \`mix phx.server\`.

3. Production-side env vars (R2, MaxMind, RENDER_API_KEY, Anthropic,
   etc.) are NOT needed locally — they only exist on the Render service.
   Read CLAUDE.md "Environment Variables" section for the full list if
   you ever need to mirror prod behavior locally.

Re-running this script is safe — every step is idempotent.
────────────────────────────────────────────────────────────────────────
EOF
