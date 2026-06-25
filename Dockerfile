ARG DEBIAN_MIRROR=
ARG DEBIAN_SECURITY_MIRROR=

FROM node:26.3.1-slim AS assets_deps

ENV NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

COPY assets/package.json assets/package-lock.json ./assets/
RUN npm ci --prefix assets

FROM elixir:1.20.1-otp-28-slim AS builder

ARG DEBIAN_MIRROR
ARG DEBIAN_SECURITY_MIRROR

ENV DEBIAN_FRONTEND=noninteractive
ENV ERL_AFLAGS="+JMsingle true"
ENV MIX_ENV=prod

WORKDIR /app

RUN for file in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
    if [ -f "${file}" ] && [ -n "${DEBIAN_SECURITY_MIRROR}" ]; then \
      sed -i \
        -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|https://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|http://security.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|https://security.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        "${file}"; \
    fi; \
    if [ -f "${file}" ] && [ -n "${DEBIAN_MIRROR}" ]; then \
      sed -i \
        -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
        -e "s|https://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
        "${file}"; \
    fi; \
  done \
  && apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY --from=assets_deps /app/assets/node_modules ./assets/node_modules
COPY assets assets
COPY lib lib
COPY priv priv

RUN mix compile \
  && mix assets.deploy \
  && mix release

FROM debian:trixie-slim AS app

ARG DEBIAN_MIRROR
ARG DEBIAN_SECURITY_MIRROR

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/app
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PORT=4000

WORKDIR /app

RUN for file in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
    if [ -f "${file}" ] && [ -n "${DEBIAN_SECURITY_MIRROR}" ]; then \
      sed -i \
        -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|https://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|http://security.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        -e "s|https://security.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        "${file}"; \
    fi; \
    if [ -f "${file}" ] && [ -n "${DEBIAN_MIRROR}" ]; then \
      sed -i \
        -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
        -e "s|https://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
        "${file}"; \
    fi; \
  done \
  && apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 openssl tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --system codex_pooler \
  && useradd --system --gid codex_pooler --home-dir /app --shell /usr/sbin/nologin codex_pooler

COPY --from=builder --chown=codex_pooler:codex_pooler /app/_build/prod/rel/codex_pooler ./

USER codex_pooler

EXPOSE 4000

CMD ["/app/bin/codex_pooler", "start"]
