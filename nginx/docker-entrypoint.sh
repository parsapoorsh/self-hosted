#!/bin/sh
# Render templates (__DOMAIN__ -> DOMAIN) then start nginx.
set -eu

DOMAIN="${DOMAIN:-example.com}"
SRC="/etc/nginx/self-hosted"
RUNTIME="/etc/nginx/self-hosted-runtime"

# Avoid sed specials in domain: only allow simple DNS labels.
case "$DOMAIN" in
  *[!a-zA-Z0-9.-]* | "" | .* | *..* | *- | *-.* )
    echo "invalid DOMAIN: $DOMAIN" >&2
    exit 1
    ;;
esac

mkdir -p "$RUNTIME/snippets"

# Any *.conf under snippets that still contains __DOMAIN__ is rendered;
# static snippets are included straight from $SRC/snippets/.
sed "s/__DOMAIN__/${DOMAIN}/g" \
  "$SRC/snippets/edge-tls.conf" >"$RUNTIME/snippets/edge-tls.conf"

sed "s/__DOMAIN__/${DOMAIN}/g" \
  "$SRC/server.conf.template" >"$RUNTIME/server.conf"

echo "nginx DOMAIN=${DOMAIN} (auth/kiwix/cloud.${DOMAIN})"

exec nginx -g "daemon off;" -c /etc/nginx/self-hosted/nginx.conf
