# syntax=docker/dockerfile:1
FROM python:3.12-slim AS adapter

ARG APP_VERSION=0.1.0
LABEL org.opencontainers.image.title="Warp Kie.ai Endpoint Adapter"
LABEL org.opencontainers.image.description="OpenAI-compatible HTTPS adapter for Kie.ai Claude models in Warp."
LABEL org.opencontainers.image.version="${APP_VERSION}"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV ADAPTER_BIND_HOST=0.0.0.0
ENV ADAPTER_PORT=8787
ENV ADAPTER_HOSTNAME=warp-kie-adapter
ENV CERT_DIR=/app/certs

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN useradd --create-home --shell /usr/sbin/nologin appuser

COPY adapter.py start_adapter.sh make_https_cert.sh adapterctl.sh README.md LICENSE CHANGELOG.md ./
COPY scripts ./scripts
COPY docker/docker-entrypoint.sh /usr/local/bin/warp-kie-docker-entrypoint

RUN chmod +x \
    /usr/local/bin/warp-kie-docker-entrypoint \
    /app/start_adapter.sh \
    /app/make_https_cert.sh \
    /app/adapterctl.sh \
    /app/scripts/tunnel_service.py \
  && mkdir -p /app/certs /data \
  && chown -R appuser:appuser /app /data

USER appuser
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import ssl,urllib.request; urllib.request.urlopen('https://localhost:8787/v1/healthz', context=ssl._create_unverified_context(), timeout=4).read()"

ENTRYPOINT ["warp-kie-docker-entrypoint"]
CMD ["adapter"]

FROM adapter AS tunnel
HEALTHCHECK NONE

USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl \
  && arch="$(dpkg --print-architecture)" \
  && case "${arch}" in \
       amd64) cf_arch="amd64" ;; \
       arm64) cf_arch="arm64" ;; \
       armhf) cf_arch="arm" ;; \
       *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
     esac \
  && curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" -o /usr/local/bin/cloudflared \
  && chmod +x /usr/local/bin/cloudflared \
  && rm -rf /var/lib/apt/lists/*

USER appuser
CMD ["tunnel"]
