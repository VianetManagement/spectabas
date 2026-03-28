# Build stage
FROM hexpm/elixir:1.17.3-erlang-27.2-ubuntu-jammy-20260217 AS build

RUN apt-get update -y && apt-get install -y build-essential git curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=prod

# --- Layer 1: Deps (cached unless mix.exs/mix.lock change) ---
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile

# Pre-install esbuild + tailwind binaries (cached with deps)
RUN mix esbuild.install --if-missing && mix tailwind.install --if-missing

# --- Layer 2: GeoIP + UA databases (cached separately, rarely changes) ---
# Only re-downloads when this RUN instruction changes (monthly cache bust)
# Cache key: 2026-03
RUN mkdir -p priv/geoip && \
    curl -fsSL -o /tmp/city.mmdb.gz "https://download.db-ip.com/free/dbip-city-lite-2026-03.mmdb.gz" && \
    curl -fsSL -o /tmp/asn.mmdb.gz "https://download.db-ip.com/free/dbip-asn-lite-2026-03.mmdb.gz" && \
    gunzip -c /tmp/city.mmdb.gz > priv/geoip/dbip-city-lite.mmdb && \
    gunzip -c /tmp/asn.mmdb.gz > priv/geoip/dbip-asn-lite.mmdb && \
    rm -f /tmp/*.gz

# --- Layer 3: App code (changes on every push) ---
COPY lib lib
COPY assets assets
COPY priv/static priv/static
COPY priv/repo priv/repo
COPY priv/asn_lists priv/asn_lists
COPY priv/clickhouse priv/clickhouse
COPY rel rel

RUN mix compile && \
    mix ua_inspector.download --force && \
    mix esbuild spectabas --minify && \
    mix tailwind spectabas --minify && \
    mix phx.digest && \
    mix release

# Runtime stage
FROM ubuntu:jammy AS app

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod PHX_SERVER=true

WORKDIR /app
RUN chown nobody /app
COPY --from=build --chown=nobody:root /app/_build/prod/rel/spectabas ./
USER nobody

EXPOSE 10000
CMD ["/app/bin/start"]
