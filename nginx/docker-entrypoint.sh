#!/bin/sh
# Render server.conf from template (DOMAIN -> __DOMAIN__) then start nginx.
set -eu

DOMAIN="${DOMAIN:-example.com}"
TEMPLATE="/etc/nginx/self-hosted/server.conf.template"
RUNTIME_DIR="/etc/nginx/self-hosted-runtime"
RUNTIME_CONF="${RUNTIME_DIR}/server.conf"

mkdir -p "$RUNTIME_DIR"

# Avoid sed specials in domain: only allow simple DNS labels.
case "$DOMAIN" in
  *[!a-zA-Z0-9.-]* | "" | .* | *..* | *- | *-.* )
    echo "invalid DOMAIN: $DOMAIN" >&2
    exit 1
    ;;
esac

sed "s/__DOMAIN__/${DOMAIN}/g" "$TEMPLATE" >"$RUNTIME_CONF"

echo "nginx DOMAIN=${DOMAIN} (auth/kiwix/cloud.${DOMAIN})"

exec nginx -g "daemon off;" -c /etc/nginx/self-hosted/nginx.conf
