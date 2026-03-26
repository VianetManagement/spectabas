# Build stage
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bookworm-20241016-slim AS build

RUN apt-get update -y && apt-get install -y build-essential git curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile

# Build assets
COPY assets assets
COPY priv priv
COPY lib lib

RUN mix assets.deploy

# Compile and build release
RUN mix compile
RUN mix release

# Runtime stage
FROM debian:bookworm-slim AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV=prod
ENV PHX_SERVER=true

COPY --from=build --chown=nobody:root /app/_build/prod/rel/spectabas ./

# Copy GeoIP and ASN data
COPY --from=build --chown=nobody:root /app/priv/asn_lists ./priv/asn_lists
# Note: mmdb files must be added at deploy time or via volume mount

USER nobody

CMD ["/app/bin/server"]
