# Build stage — uses pre-built base with deps compiled (~30s for code-only changes)
# Base image rebuilds via GitHub Actions when mix.exs/mix.lock/config change
FROM ghcr.io/vianetmanagement/spectabas-base:latest AS build

WORKDIR /app
ENV MIX_ENV=prod

COPY lib lib
COPY assets assets
COPY priv priv
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
