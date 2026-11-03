---
title: Nexus
page_title: Nexus · ${domain}
---

# Package clients → Nexus on ${domain}

Point cargo, pip, Docker, npm, and the rest at this stack’s **group** repos. Catalog is `nexus/catalog.json`; bootstrap creates groups on every Nexus start.

## Base URL

```bash
export NEXUS="https://nexus.${domain}"

# Local testing only:
# export NEXUS="https://nexus.localhost"
```

- Package paths: `/repository/…` and Docker `/v2/` — **no Authelia**, anonymous pull enabled  
- Browser UI: Authelia OIDC (HTTPS; HTTP redirects to HTTPS)  
- TLS: trust `cert/${domain}/` or `./scripts/trust-localhost-ca.sh` for localhost  

Optional admin basic auth (from `.env`):

```bash
export NEXUS_USER="admin"   # KEYCLOAK_ADMIN
export NEXUS_PASS="…"       # KEYCLOAK_ADMIN_PASSWORD
```

---

## Cargo (Rust)

Group: `cargo` → `sparse+${NEXUS}/repository/cargo/`

```bash
mkdir -p "${CARGO_HOME:-$HOME/.cargo}"

cat > "${CARGO_HOME:-$HOME/.cargo}/config.toml" <<EOF
[source.crates-io]
replace-with = "nexus"

[source.nexus]
registry = "sparse+${NEXUS}/repository/cargo/"
EOF

cargo search serde --limit 1
```

---

## Pip / uv / poetry (Python)

Group: `pypi` → `${NEXUS}/repository/pypi/simple`

```bash
python3 -m pip config set global.index-url "${NEXUS}/repository/pypi/simple"
python3 -m pip config set global.trusted-host "nexus.${domain} nexus.localhost"

python3 -m pip install requests --index-url "${NEXUS}/repository/pypi/simple"

export UV_INDEX_URL="${NEXUS}/repository/pypi/simple"

poetry source add --priority=primary nexus "${NEXUS}/repository/pypi/simple"
```

Publish to `pypi-hosted` (auth required):

```bash
twine upload \
  --repository-url "${NEXUS}/repository/pypi-hosted/" \
  -u "${NEXUS_USER}" -p "${NEXUS_PASS}" \
  dist/*
```

---

## Docker

Path-based groups (no extra connector port):

| Pull prefix | Group | Typical upstream |
|-------------|--------|------------------|
| `${NEXUS#https://}/repository/docker/` | `docker` | Hub + IR mirrors (cdn.ir, Arvan, …) |
| `…/repository/ghcr/` | `ghcr` | ghcr.io |
| `…/repository/k8s/` | `k8s` | registry.k8s.io |
| `…/repository/quay/` | `quay` | quay.io |

```bash
docker pull "${NEXUS#*://}/repository/docker/library/nginx:alpine"
docker pull "${NEXUS#*://}/repository/ghcr/OWNER/IMAGE:TAG"
docker pull "${NEXUS#*://}/repository/k8s/pause:3.9"
docker pull "${NEXUS#*://}/repository/quay/prometheus/prometheus:latest"
```

```bash
echo "${NEXUS_PASS}" | docker login "${NEXUS#*://}" -u "${NEXUS_USER}" --password-stdin
```

Prefer rewriting image names to these paths over `daemon.json` registry-mirrors (this edge is path-based under `/repository/<name>/`).

Self-signed host (prefer trusting the CA):

```json
{
  "insecure-registries": ["nexus.${domain}", "nexus.localhost"]
}
```

---

## npm / yarn / pnpm

Group: `npm` → `${NEXUS}/repository/npm/`

```bash
npm config set registry "${NEXUS}/repository/npm/"
yarn config set registry "${NEXUS}/repository/npm/"
pnpm config set registry "${NEXUS}/repository/npm/"
```

Node dist (raw group `nodejs`):

```bash
export NODEJS_ORG_MIRROR="${NEXUS}/repository/nodejs/"
```

---

## Go

```bash
export GOPROXY="${NEXUS}/repository/go/"
export GOSUMDB="sum.golang.org ${NEXUS}/repository/go-sum/"

go env -w GOPROXY="${NEXUS}/repository/go/"
go env -w GOSUMDB="sum.golang.org ${NEXUS}/repository/go-sum/"
```

---

## NuGet (.NET)

```bash
dotnet nuget add source "${NEXUS}/repository/nuget/index.json" \
  --name nexus \
  --username "${NEXUS_USER}" \
  --password "${NEXUS_PASS}" \
  --store-password-in-clear-text
```

---

## Composer (PHP)

```bash
composer config -g repos.packagist composer "${NEXUS}/repository/composer/"
composer clear-cache
composer install
```

---

## APT (Debian / Ubuntu / Kali)

Full guide: **[APT](apt.html)** · `docs/APT.md`

Merged group: `https://nexus.${domain}/repository/apt/` — one path, suite on the `deb` line. Architectures **amd64** / **i386**, union of versions, group signing key.

```bash
curl -fsS "${NEXUS}/repository/apt/key.asc" \
  | sudo tee /etc/apt/keyrings/nexus-apt-group.asc >/dev/null

echo "deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy main universe" \
  | sudo tee /etc/apt/sources.list.d/nexus-apt.list
sudo apt-get update
```

---

## Alpine (apk)

```bash
NEXUS_APK="${NEXUS}/repository/alpine"
echo "${NEXUS_APK}/v3.20/main" > /etc/apk/repositories
echo "${NEXUS_APK}/v3.20/community" >> /etc/apk/repositories
apk update
```

---

## Hugging Face

```bash
export HF_ENDPOINT="${NEXUS}/repository/huggingface-upstream"
```

Confirm with a small download after the proxy is warm; exact URL joining depends on the client.

---

## Quick verification

```bash
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/repository/pypi/simple/pip/"
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/repository/npm/lodash"
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/repository/cargo/config.json"
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/repository/apt/"
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/v2/"
```

Expect Nexus status codes (`200` / `401` / `404`), not SSO HTML.

```bash
curl -sS -u "${NEXUS_USER}:${NEXUS_PASS}" \
  "${NEXUS}/service/rest/v1/repositories" | python3 -m json.tool | head
```

---

## Repo map (prefer groups)

| Ecosystem | Group | Client suffix |
|-----------|--------|----------------|
| Cargo | `cargo` | `/repository/cargo/` (sparse+) |
| PyPI | `pypi` | `/repository/pypi/simple` |
| PyPI publish | `pypi-hosted` | `/repository/pypi-hosted/` |
| npm | `npm` | `/repository/npm/` |
| Go | `go` | `/repository/go/` |
| Go sum | `go-sum` | `/repository/go-sum/` |
| NuGet | `nuget` | `/repository/nuget/index.json` |
| Composer | `composer` | `/repository/composer/` |
| Alpine | `alpine` | `/repository/alpine/<ver>/<branch>` |
| APT | `apt` (sidecar) | `/repository/apt/` + suite on `deb` |
| Docker Hub | `docker` | `/repository/docker/…` |
| GHCR | `ghcr` | `/repository/ghcr/…` |
| K8s | `k8s` | `/repository/k8s/…` |
| Quay | `quay` | `/repository/quay/…` |
| Node dist | `nodejs` | `/repository/nodejs/` |

Single-mirror proxy names are in `nexus/catalog.json` if you need one upstream instead of a group. Member order prefers **cdn.ir**, then **Arvancloud**, then other mirrors.
