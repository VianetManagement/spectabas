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

COPY config/config.exs config/prod.exs config/runtime.exs config/appsignal.exs config/
RUN mix deps.compile

# Pre-install esbuild + tailwind binaries and UA parser data (cached with deps)
RUN mix esbuild.install --if-missing && \
    mix tailwind.install --if-missing && \
    mix ua_inspector.download --force

# --- Layer 2: GeoIP databases ---
# DB-IP downloaded at build time (free, no key needed)
# MaxMind downloaded at build time if MAXMIND_LICENSE_KEY is set as build arg
# Cache key: 2026-03
ARG MAXMIND_LICENSE_KEY=""
RUN mkdir -p priv/geoip && \
    curl -fsSL -o /tmp/city.mmdb.gz "https://download.db-ip.com/free/dbip-city-lite-2026-03.mmdb.gz" && \
    curl -fsSL -o /tmp/asn.mmdb.gz "https://download.db-ip.com/free/dbip-asn-lite-2026-03.mmdb.gz" && \
    gunzip -c /tmp/city.mmdb.gz > priv/geoip/dbip-city-lite.mmdb && \
    gunzip -c /tmp/asn.mmdb.gz > priv/geoip/dbip-asn-lite.mmdb && \
    rm -f /tmp/*.gz && \
    if [ -n "$MAXMIND_LICENSE_KEY" ]; then \
      curl -fsSL -o /tmp/maxmind.tar.gz "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz" && \
      tar -xzf /tmp/maxmind.tar.gz -C /tmp && \
      cp /tmp/GeoLite2-City_*/GeoLite2-City.mmdb priv/geoip/GeoLite2-City.mmdb && \
      rm -rf /tmp/maxmind.tar.gz /tmp/GeoLite2-City_* && \
      echo "MaxMind GeoLite2-City downloaded at build time"; \
    else \
      echo "MAXMIND_LICENSE_KEY not set, will download at runtime"; \
    fi

# --- Layer 3: App code (changes on every push) ---
COPY lib lib
COPY assets assets
COPY priv/static priv/static
COPY priv/repo priv/repo
COPY priv/asn_lists priv/asn_lists
COPY priv/clickhouse priv/clickhouse
COPY rel rel

RUN mix compile && \
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
