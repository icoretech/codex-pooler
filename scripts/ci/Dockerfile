FROM node:26.13.1-bookworm-slim AS node
FROM elixir:1.20.5-otp-29-slim@sha256:85b39770dd49e943ce86f2a8dcf7fc64c909c8df902d7dc8e69f405ecaab3769

ARG HELM_VERSION=v4.3.2
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates cmake curl git libsctp1 lsof procps python3 ripgrep tar tzdata docker-cli docker-compose \
    && architecture="$(dpkg --print-architecture)" \
    && curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-${architecture}.tar.gz" \
    && curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-${architecture}.tar.gz.sha256sum" \
    && sha256sum -c "helm-${HELM_VERSION}-linux-${architecture}.tar.gz.sha256sum" \
    && tar -xzf "helm-${HELM_VERSION}-linux-${architecture}.tar.gz" \
    && install -m 0755 "linux-${architecture}/helm" /usr/local/bin/helm \
    && rm -rf /var/lib/apt/lists/* "linux-${architecture}" helm-*.tar.gz* \
    && mix local.hex --force && mix local.rebar --force \
    && elixir --version && node --version && helm version --short && docker compose version

WORKDIR /workspace
