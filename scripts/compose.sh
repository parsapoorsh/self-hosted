#!/usr/bin/env bash
# docker compose wrapper: refresh derived secrets, then run compose with both env files.
# After `up -d`, wait for bootstraps and run smoke-check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

./scripts/sync-secrets.sh

# Nexus Alpine repos need a stable RSA key (PEM). Create once on the host.
ensure_nexus_alpine_key() {
  local key="${ROOT}/cert/alpine.key"
  if [[ -f "${key}" ]]; then
    return 0
  fi
  mkdir -p "${ROOT}/cert"
  echo "compose: creating ${key}"
  openssl genrsa 2048 2>/dev/null \
    | openssl pkcs8 -topk8 -nocrypt -out "${key}"
  chmod 600 "${key}"
}
ensure_nexus_alpine_key

# Primary domain TLS material (nginx fails hard without it).
require_domain_cert() {
  local domain="${DOMAIN:-}"
  if [[ -z "${domain}" && -f .env ]]; then
    # shellcheck disable=SC1091
    domain="$(set -a; source .env; set +a; printf '%s' "${DOMAIN:-}")"
  fi
  domain="${domain:-example.com}"
  local dir="${ROOT}/cert/${domain}"
  if [[ -f "${dir}/fullchain.pem" && -f "${dir}/privkey.pem" ]]; then
    return 0
  fi
  echo "compose: missing cert/${domain}/{fullchain,privkey}.pem" >&2
  echo "compose: run ./scripts/self-signed.sh  (or place real LE certs there)" >&2
  exit 1
}

COMPOSE=(docker compose --env-file .env --env-file .env.secrets)

cmd=""
detach=0
for arg in "$@"; do
  case "${arg}" in
    -d|--detach) detach=1 ;;
    -*)
      ;;
    *)
      if [[ -z "${cmd}" ]]; then
        cmd="${arg}"
      fi
      ;;
  esac
done

# Fail before docker starts so nginx does not crash-loop on missing DOMAIN cert.
case "${cmd}" in
  up|start|restart) require_domain_cert ;;
esac

"${COMPOSE[@]}" "$@"
status=$?

if [[ "${status}" -eq 0 && "${cmd}" == "up" && "${detach}" -eq 1 ]]; then
  echo "compose: running smoke-check (bootstraps can take a few minutes)..."
  ./scripts/smoke-check.sh || status=$?
fi

exit "${status}"
