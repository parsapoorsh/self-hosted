#!/usr/bin/env bash
# Generate a self-signed TLS cert tree shaped like Let's Encrypt live certs:
#
#   cert/<domain>/
#     cert.pem       leaf certificate
#     chain.pem      issuer (self-signed CA) certificate
#     fullchain.pem  leaf + chain
#     privkey.pem    leaf private key
#
# Usage:
#   ./scripts/self-signed.sh [domain]
#   DOMAIN=example.com ./scripts/self-signed.sh
#
# Default domain is localhost (with 127.0.0.1 / ::1 SANs). Re-run to replace certs.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_ROOT="${CERT_ROOT:-$ROOT_DIR/cert}"
DAYS="${DAYS:-825}"
KEY_BITS="${KEY_BITS:-4096}"

DOMAIN="${1:-${DOMAIN:-localhost}}"
OUT_DIR="$CERT_ROOT/$DOMAIN"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR"

# Local CA so chain.pem / fullchain.pem match a real LE-style layout.
openssl genrsa -out "$WORK_DIR/ca.key" "$KEY_BITS" 2>/dev/null
openssl req \
  -x509 \
  -new \
  -nodes \
  -key "$WORK_DIR/ca.key" \
  -sha256 \
  -days "$DAYS" \
  -subj "/CN=self-hosted local CA" \
  -out "$WORK_DIR/ca.pem"

openssl genrsa -out "$OUT_DIR/privkey.pem" "$KEY_BITS" 2>/dev/null
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
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF

if [[ "$DOMAIN" == "localhost" ]]; then
  cat >>"$WORK_DIR/leaf.cnf" <<EOF
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
