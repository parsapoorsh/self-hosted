#!/usr/bin/env bash
# Generate a self-signed TLS cert tree shaped like Let's Encrypt live certs:
#
#   cert/<domain>/
#     cert.pem       leaf certificate
#     chain.pem      issuer (self-signed CA) certificate
#     fullchain.pem  leaf + chain
#     privkey.pem    leaf private key
#
# SANs: apex + one-level wildcard (auth/kiwix/www/... under DOMAIN).
#   DNS: <domain>
#   DNS: *.<domain>
#
# Usage:
#   ./scripts/self-signed.sh [domain]
#   DOMAIN=example.com ./scripts/self-signed.sh
#
# Default domain is example.com. Re-run to replace certs.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_ROOT="${CERT_ROOT:-$ROOT_DIR/cert}"
DAYS="${DAYS:-825}"
# ECDSA P-256 (prime256v1). Browsers/nginx share cipher suites for this;
# Ed25519 certs often hit SSL_ERROR_NO_CYPHER_OVERLAP in Firefox.
EC_CURVE="${EC_CURVE:-P-256}"

DOMAIN="${1:-${DOMAIN:-example.com}}"
OUT_DIR="$CERT_ROOT/$DOMAIN"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR"

gen_ec_key() {
  openssl genpkey \
    -algorithm EC \
    -pkeyopt "ec_paramgen_curve:$EC_CURVE" \
    -out "$1" 2>/dev/null
}

# Local CA so chain.pem / fullchain.pem match a real LE-style layout.
gen_ec_key "$WORK_DIR/ca.key"
openssl req \
  -x509 \
  -new \
  -nodes \
  -key "$WORK_DIR/ca.key" \
  -sha256 \
  -days "$DAYS" \
  -subj "/CN=self-hosted local CA" \
  -out "$WORK_DIR/ca.pem"

gen_ec_key "$OUT_DIR/privkey.pem"
# 644 so the nginx container user can read the key from the mounted cert/ tree.
# Host protection is the gitignored cert/ directory, not the file mode.
chmod 644 "$OUT_DIR/privkey.pem"

cat >"$WORK_DIR/leaf.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $DOMAIN

[v3_req]
basicConstraints = CA:FALSE
# digitalSignature only: ECDSA is a signing key (no keyEncipherment)
keyUsage = digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
EOF

if [[ "$DOMAIN" == "localhost" ]]; then
  # Prefer scripts/gen-localhost-cert.sh (single cert + stable CA for all *.localhost).
  cat >>"$WORK_DIR/leaf.cnf" <<EOF
DNS.3 = www.localhost
DNS.4 = auth.localhost
DNS.5 = cloud.localhost
DNS.6 = nexus.localhost
DNS.7 = kiwix.localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF
fi

openssl req \
  -new \
  -key "$OUT_DIR/privkey.pem" \
  -config "$WORK_DIR/leaf.cnf" \
  -out "$WORK_DIR/leaf.csr"

openssl x509 \
  -req \
  -in "$WORK_DIR/leaf.csr" \
  -CA "$WORK_DIR/ca.pem" \
  -CAkey "$WORK_DIR/ca.key" \
  -CAcreateserial \
  -out "$OUT_DIR/cert.pem" \
  -days "$DAYS" \
  -sha256 \
  -extfile "$WORK_DIR/leaf.cnf" \
  -extensions v3_req

cp "$WORK_DIR/ca.pem" "$OUT_DIR/chain.pem"
cat "$OUT_DIR/cert.pem" "$OUT_DIR/chain.pem" >"$OUT_DIR/fullchain.pem"

# Keep the CA key next to the certs so you can re-issue the same chain later.
# Do not commit this directory.
cp "$WORK_DIR/ca.key" "$OUT_DIR/ca.key"
chmod 600 "$OUT_DIR/ca.key"
cp "$WORK_DIR/ca.pem" "$OUT_DIR/ca.pem"

echo "wrote $OUT_DIR"
ls -la "$OUT_DIR"
openssl x509 -in "$OUT_DIR/cert.pem" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
  || openssl x509 -in "$OUT_DIR/cert.pem" -noout -subject -issuer -dates
