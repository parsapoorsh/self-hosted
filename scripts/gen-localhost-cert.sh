#!/usr/bin/env bash
# One leaf cert for the whole localhost tree (not one cert per subdomain):
#
#   cert/localhost/
#     ca.pem / ca.key     local CA (trust this once - see trust-localhost-ca.sh)
#     cert.pem            leaf CN=localhost
#     fullchain.pem       leaf + ca
#     privkey.pem
#
# SANs: localhost, *.localhost, 127.0.0.1, ::1
# Reuses existing CA when present so re-running does not invalidate a trusted CA.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${CERT_ROOT:-$ROOT_DIR/cert}/localhost"
DAYS="${DAYS:-825}"
EC_CURVE="${EC_CURVE:-P-256}"
FORCE="${FORCE:-0}"

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gen_ec_key() {
  openssl genpkey \
    -algorithm EC \
    -pkeyopt "ec_paramgen_curve:$EC_CURVE" \
    -out "$1" 2>/dev/null
}

if [[ "$FORCE" != "1" && -f "$OUT/fullchain.pem" && -f "$OUT/privkey.pem" && -f "$OUT/ca.pem" ]]; then
  echo "already exists: $OUT (set FORCE=1 to recreate leaf; keeps CA if ca.key present)"
  openssl x509 -in "$OUT/cert.pem" -noout -subject -ext subjectAltName 2>/dev/null || true
  exit 0
fi

# Stable CA: reuse so trust-localhost-ca.sh only needs to run once.
if [[ -f "$OUT/ca.key" && -f "$OUT/ca.pem" ]]; then
  echo "reusing CA $OUT/ca.pem"
  cp "$OUT/ca.key" "$WORK/ca.key"
  cp "$OUT/ca.pem" "$WORK/ca.pem"
else
  echo "creating CA"
  gen_ec_key "$WORK/ca.key"
  openssl req \
    -x509 \
    -new \
    -nodes \
    -key "$WORK/ca.key" \
    -sha256 \
    -days "$DAYS" \
    -subj "/CN=self-hosted localhost CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$WORK/ca.pem"
  cp "$WORK/ca.key" "$OUT/ca.key"
  chmod 600 "$OUT/ca.key"
  cp "$WORK/ca.pem" "$OUT/ca.pem"
fi

gen_ec_key "$OUT/privkey.pem"
chmod 644 "$OUT/privkey.pem"

# Single leaf for every local name (wildcard + apex + loopback).
cat >"$WORK/leaf.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
DNS.3 = www.localhost
DNS.4 = auth.localhost
DNS.5 = cloud.localhost
DNS.6 = mirror.localhost
DNS.7 = kiwix.localhost
DNS.8 = mattermost.localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl req -new -key "$OUT/privkey.pem" -config "$WORK/leaf.cnf" -out "$WORK/leaf.csr"
openssl x509 \
  -req \
  -in "$WORK/leaf.csr" \
  -CA "$WORK/ca.pem" \
  -CAkey "$WORK/ca.key" \
  -CAcreateserial \
  -out "$OUT/cert.pem" \
  -days "$DAYS" \
  -sha256 \
  -extfile "$WORK/leaf.cnf" \
  -extensions v3_req

cp "$WORK/ca.pem" "$OUT/chain.pem"
cat "$OUT/cert.pem" "$OUT/chain.pem" >"$OUT/fullchain.pem"

echo "wrote single localhost cert (one domain tree): $OUT"
openssl x509 -in "$OUT/cert.pem" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
  || openssl x509 -in "$OUT/cert.pem" -noout -subject -issuer -dates
echo
echo "Trust the CA once so the browser stops prompting on every subdomain:"
echo "  ./scripts/trust-localhost-ca.sh"
