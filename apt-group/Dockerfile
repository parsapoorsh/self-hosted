FROM python:3.12-slim-bookworm

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py debver.py ./

ENV PYTHONUNBUFFERED=1 \
    APT_GROUP_LISTEN=0.0.0.0:8080 \
    APT_GROUP_KEYS_DIR=/keys \
    APT_GROUP_CATALOG=/init/catalog.json \
    APT_GROUP_NEXUS_URL=http://nexus:8081 \
    APT_GROUP_CACHE_DIR=/var/cache/apt-group

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD curl -sf http://127.0.0.1:8080/healthz || exit 1

CMD ["python3", "-u", "/app/server.py"]
