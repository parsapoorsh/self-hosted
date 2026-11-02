#!/usr/bin/env bash
# Install cert/localhost/ca.pem as a trusted CA on this machine.
# After this, https://*.localhost (one cert, one CA) should not prompt per subdomain.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA="${1:-$ROOT_DIR/cert/localhost/ca.pem}"

if [[ ! -f "$CA" ]]; then
  echo "missing CA: $CA" >&2
  echo "generate first: ./scripts/gen-localhost-cert.sh" >&2
  exit 1
fi

NAME="self-hosted-localhost-ca"
echo "using CA: $CA"

# --- system trust (curl, Chrome/Chromium on Linux, many tools) ---
if [[ "$(uname -s)" == "Linux" ]]; then
  if command -v update-ca-certificates >/dev/null 2>&1; then
    # Debian/Ubuntu
    DEST="/usr/local/share/ca-certificates/${NAME}.crt"
    echo "install system CA -> $DEST (sudo)"
    sudo cp "$CA" "$DEST"
    sudo update-ca-certificates
  elif command -v update-ca-trust >/dev/null 2>&1; then
    # Fedora/RHEL
    DEST="/etc/pki/ca-trust/source/anchors/${NAME}.crt"
    echo "install system CA -> $DEST (sudo)"
    sudo cp "$CA" "$DEST"
    sudo update-ca-trust extract
  else
    echo "no update-ca-certificates / update-ca-trust; skip system store" >&2
  fi
elif [[ "$(uname -s)" == "Darwin" ]]; then
  echo "install into macOS login keychain (sudo may prompt)"
  sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    "$CA" || security add-trusted-cert -d -r trustRoot \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    "$CA"
fi

# --- NSS (Firefox, some Chromium) ---
# User DBs: ~/.pki/nssdb and Firefox profiles.
trust_nss_db() {
  local db="$1"
  [[ -d "$db" ]] || return 0
  command -v certutil >/dev/null 2>&1 || return 0
  echo "NSS trust: $db"
  certutil -D -d "sql:$db" -n "$NAME" >/dev/null 2>&1 || true
  certutil -A -d "sql:$db" -t "C,," -n "$NAME" -i "$CA"
}

if command -v certutil >/dev/null 2>&1; then
  trust_nss_db "$HOME/.pki/nssdb"
  # Firefox profiles
  for prof in "$HOME"/.mozilla/firefox/*.default* "$HOME"/.mozilla/firefox/*.default-release; do
    [[ -d "$prof" ]] || continue
    trust_nss_db "$prof"
  done
else
  echo "certutil not found (package libnss3-tools / nss); Firefox may need manual import:"
  echo "  Settings -> Certificates -> Authorities -> Import -> $CA"
  echo "  enable \"Trust this CA to identify websites\""
fi

echo
echo "done. restart the browser, then open any https://*.localhost host once."
echo "You should not get a new warning per subdomain."
