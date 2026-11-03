# Point package clients at Nexus

Replace the default upstream (crates.io, PyPI, Docker Hub, …) with this stack’s Nexus group repos. Catalog is `nexus/catalog.json`; bootstrap creates the groups on every start.

## Base URL

Set once for your machine:

```bash
# Production-style domain from .env
export NEXUS="https://nexus.$(grep -E '^DOMAIN=' .env | cut -d= -f2-)"

# Or localhost
export NEXUS="https://nexus.localhost"
```

Package traffic uses `/repository/…` and Docker `/v2/` (no Authelia). Anonymous pull is enabled. UI login stays on Authelia OIDC.

Self-signed TLS: run `./scripts/trust-localhost-ca.sh` (or trust `cert/<DOMAIN>/`) so clients accept the cert. Until then, many tools need an insecure / trusted-host flag (shown per tool).

Optional basic auth (admin from `.env`):

```bash
export NEXUS_USER="$(grep -E '^KEYCLOAK_ADMIN=' .env | cut -d= -f2-)"
export NEXUS_PASS="$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2-)"
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

# smoke
cargo search serde --limit 1
```

Project-only (no global replace): put the same `[source.*]` block in the crate’s `.cargo/config.toml`.

---

## Pip / uv / poetry (Python)

Group: `pypi` → `${NEXUS}/repository/pypi/simple`

```bash
# pip (user-wide)
python3 -m pip config set global.index-url "${NEXUS}/repository/pypi/simple"
python3 -m pip config set global.trusted-host "nexus.localhost nexus.$(grep -E '^DOMAIN=' .env | cut -d= -f2-)"

# one-shot
python3 -m pip install requests --index-url "${NEXUS}/repository/pypi/simple"

# uv
export UV_INDEX_URL="${NEXUS}/repository/pypi/simple"
# or: uv pip install requests --index-url "${NEXUS}/repository/pypi/simple"

# poetry (per project)
poetry source add --priority=primary nexus "${NEXUS}/repository/pypi/simple"
```

Publish to hosted repo `pypi-hosted` (needs auth):

```bash
python3 -m pip install twine
twine upload \
  --repository-url "${NEXUS}/repository/pypi-hosted/" \
  -u "${NEXUS_USER}" -p "${NEXUS_PASS}" \
  dist/*
```

---

## Docker

Groups (path-based, no extra connector port):

| Pull prefix | Group | Typical upstream |
|-------------|--------|------------------|
| `${NEXUS#https://}/repository/docker/` | `docker` | Docker Hub + IR mirrors |
| `…/repository/ghcr/` | `ghcr` | ghcr.io |
| `…/repository/k8s/` | `k8s` | registry.k8s.io |
| `…/repository/quay/` | `quay` | quay.io |

Host is the registry name; image path includes `/repository/<group>/…`.

```bash
# Hub-style image via docker group (library/ is Docker Hub’s official namespace)
docker pull "${NEXUS#*://}/repository/docker/library/nginx:alpine"

# ghcr
docker pull "${NEXUS#*://}/repository/ghcr/OWNER/IMAGE:TAG"

# k8s
docker pull "${NEXUS#*://}/repository/k8s/pause:3.9"

# quay
docker pull "${NEXUS#*://}/repository/quay/prometheus/prometheus:latest"
```

Optional login (anonymous pull usually enough):

```bash
echo "${NEXUS_PASS}" | docker login "${NEXUS#*://}" -u "${NEXUS_USER}" --password-stdin
```

Daemon **registry-mirrors** only work cleanly with a root `/v2/` registry. This stack exposes path-based repos under `/repository/<name>/`, so prefer rewriting image names (or compose `image:`) to the paths above rather than `daemon.json` mirrors.

Self-signed host: add to `/etc/docker/daemon.json` then `sudo systemctl restart docker`:

```json
{
  "insecure-registries": ["nexus.localhost", "nexus.example.com"]
}
```

(Use your real `DOMAIN`. Prefer trusting the CA over `insecure-registries` when you can.)

---

## npm / yarn / pnpm (Node)

Group: `npm` → `${NEXUS}/repository/npm/`

```bash
# npm (user-wide)
npm config set registry "${NEXUS}/repository/npm/"

# yarn classic
yarn config set registry "${NEXUS}/repository/npm/"

# yarn berry
yarn config set npmRegistryServer "${NEXUS}/repository/npm/"

# pnpm
pnpm config set registry "${NEXUS}/repository/npm/"

# one-shot
npm install lodash --registry "${NEXUS}/repository/npm/"
```

Strict SSL off only if the CA is not trusted yet:

```bash
npm config set strict-ssl false   # temporary; prefer trust-localhost-ca.sh
```

Node tarball mirror (raw group `nodejs`):

```bash
export NODEJS_ORG_MIRROR="${NEXUS}/repository/nodejs/"
# nvm / fnm / node-build honor variants of this; check your version manager docs
```

---

## Go

Group: `go` → `${NEXUS}/repository/go/`  
Checksum DB (raw group): `go-sum` → `${NEXUS}/repository/go-sum/`

```bash
# shell profile or direnv
export GOPROXY="${NEXUS}/repository/go/"
export GOSUMDB="sum.golang.org ${NEXUS}/repository/go-sum/"
# if sum proxy misbehaves with your TLS setup:
# export GOSUMDB=off

go env -w GOPROXY="${NEXUS}/repository/go/"
go env -w GOSUMDB="sum.golang.org ${NEXUS}/repository/go-sum/"

go mod download
```

---

## NuGet (.NET)

Group: `nuget` → `${NEXUS}/repository/nuget/index.json`

```bash
dotnet nuget remove source nuget.org 2>/dev/null || true
dotnet nuget add source "${NEXUS}/repository/nuget/index.json" \
  --name nexus \
  --username "${NEXUS_USER}" \
  --password "${NEXUS_PASS}" \
  --store-password-in-clear-text

# or keep nuget.org and prefer nexus
dotnet nuget add source "${NEXUS}/repository/nuget/index.json" --name nexus
dotnet restore --source nexus
```

Older `nuget.exe`:

```bash
nuget sources Add -Name nexus -Source "${NEXUS}/repository/nuget/index.json"
```

---

## Composer (PHP)

Group: `composer` → `${NEXUS}/repository/composer/`

```bash
composer config -g repos.packagist composer "${NEXUS}/repository/composer/"

# project-only
composer config repos.packagist composer "${NEXUS}/repository/composer/"

composer clear-cache
composer install
```

---

## APT (Debian / Ubuntu / Kali)

Full client guide: **[APT.md](APT.md)**.

Merged group (apt-group sidecar): `apt` → `${NEXUS}/repository/apt/`

One base URL; pick the suite on the `deb` line. Architectures published: **amd64**, **i386**. Metadata is the **union of versions** across Nexus apt proxies (downgrades still possible while a member has the old build). Indexes are re-signed with the group key.

```bash
# trust group key once
curl -fsS "${NEXUS}/repository/apt/key.asc" | sudo tee /etc/apt/keyrings/nexus-apt-group.asc >/dev/null

# examples (same path, different suites)
cat <<EOF | sudo tee /etc/apt/sources.list.d/nexus-apt.list
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt kali-rolling main contrib non-free non-free-firmware
EOF

sudo apt-get update
```

Suites and member order live in `nexus/catalog.json` → `aptGroup`. Individual Nexus apt proxies remain at `/repository/<name>/` (e.g. `ubuntu-cdnir`, `debian-liara`).

Merge is family-scoped (ubuntu / debian / kali members only for matching suites), capped by `maxMembersPerSuite` (default 3), and keeps a **union of versions** so pins/downgrades still work while a member has the old build.

---

## Alpine (apk)

Group: `alpine` → `${NEXUS}/repository/alpine/`

```bash
# example: v3.20 main + community
NEXUS_APK="${NEXUS}/repository/alpine"
echo "${NEXUS_APK}/v3.20/main" > /etc/apk/repositories
echo "${NEXUS_APK}/v3.20/community" >> /etc/apk/repositories

apk update
apk add curl
```

---

## Hugging Face

Proxy repo name in catalog: `huggingface-devneeds` / `huggingface-upstream` (no single group name). Point the hub client at a proxy you use, for example:

```bash
# if you add/use a dedicated group later, swap the path
export HF_ENDPOINT="${NEXUS}/repository/huggingface-upstream"
# some tools:
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HOME/.cache/huggingface}"
```

Exact path depends on how the HF client joins URLs; confirm with a small `huggingface-cli download` after the proxy is warm.

---

## Quick verification

```bash
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/repository/pypi/simple/pip/"
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/repository/npm/lodash"
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/repository/cargo/config.json"
curl -sS -o /dev/null -w "%{http_code}\n" "${NEXUS}/v2/"
```

Expect `200` / `401` / `404` from Nexus itself (not nginx SSO HTML). SSO HTML on these paths means the edge is wrong.

List repos (admin basic auth):

```bash
curl -sS -u "${NEXUS_USER}:${NEXUS_PASS}" \
  "${NEXUS}/service/rest/v1/repositories" | python3 -m json.tool | head
```

---

## Repo map (groups clients should use)

| Ecosystem | Nexus group | Client URL suffix |
|-----------|-------------|-------------------|
| Cargo | `cargo` | `/repository/cargo/` (sparse+) |
| PyPI | `pypi` | `/repository/pypi/simple` |
| PyPI publish | `pypi-hosted` | `/repository/pypi-hosted/` |
| npm | `npm` | `/repository/npm/` |
| Go modules | `go` | `/repository/go/` |
| Go checksums | `go-sum` | `/repository/go-sum/` |
| NuGet | `nuget` | `/repository/nuget/index.json` |
| Composer | `composer` | `/repository/composer/` |
| Alpine apk | `alpine` | `/repository/alpine/<ver>/<branch>` |
| APT (Debian/Ubuntu/Kali) | `apt` (sidecar) | `/repository/apt/` + suite on `deb` line |
| Docker Hub | `docker` | `/repository/docker/…` |
| GHCR | `ghcr` | `/repository/ghcr/…` |
| K8s registry | `k8s` | `/repository/k8s/…` |
| Quay | `quay` | `/repository/quay/…` |
| Node dist | `nodejs` | `/repository/nodejs/` |

Proxy-only names (mirrors, not groups) are in `nexus/catalog.json` if you need a single upstream instead of the group.
