FROM node:26.13.0-bookworm-slim AS node
FROM elixir:1.20.5-otp-29-slim

ARG HELM_VERSION=v4.3.1
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
