---
title: Nexus
page_title: Nexus · nexus.${domain}
---

# Package mirrors

Base host: **https://nexus.${domain}**

Pull packages through the paths below. No login is required for normal installs (anonymous pull).

---

## Cargo (Rust)

```bash
mkdir -p "${CARGO_HOME:-$HOME/.cargo}"
cat > "${CARGO_HOME:-$HOME/.cargo}/config.toml" <<'EOF'
[source.crates-io]
replace-with = "nexus"

[source.nexus]
registry = "sparse+https://nexus.${domain}/repository/cargo/"
EOF
```

---

## Pip / uv / poetry (Python)

```bash
python3 -m pip config set global.index-url https://nexus.${domain}/repository/pypi/simple
python3 -m pip config set global.trusted-host nexus.${domain}

python3 -m pip install requests --index-url https://nexus.${domain}/repository/pypi/simple

export UV_INDEX_URL=https://nexus.${domain}/repository/pypi/simple

poetry source add --priority=primary nexus https://nexus.${domain}/repository/pypi/simple
```

---

## Docker

```bash
docker pull nexus.${domain}/repository/docker/library/nginx:alpine
docker pull nexus.${domain}/repository/ghcr/OWNER/IMAGE:TAG
docker pull nexus.${domain}/repository/k8s/pause:3.9
docker pull nexus.${domain}/repository/quay/prometheus/prometheus:latest
```

| Registry | Pull prefix |
|----------|-------------|
| Docker Hub | `nexus.${domain}/repository/docker/…` |
| GHCR | `nexus.${domain}/repository/ghcr/…` |
| Kubernetes | `nexus.${domain}/repository/k8s/…` |
| Quay | `nexus.${domain}/repository/quay/…` |

---

## npm / yarn / pnpm

```bash
npm config set registry https://nexus.${domain}/repository/npm/
yarn config set registry https://nexus.${domain}/repository/npm/
pnpm config set registry https://nexus.${domain}/repository/npm/
```

Node distributions:

```bash
export NODEJS_ORG_MIRROR=https://nexus.${domain}/repository/nodejs/
```

---

## Go

```bash
export GOPROXY=https://nexus.${domain}/repository/go/
export GOSUMDB="sum.golang.org https://nexus.${domain}/repository/go-sum/"

go env -w GOPROXY=https://nexus.${domain}/repository/go/
go env -w GOSUMDB="sum.golang.org https://nexus.${domain}/repository/go-sum/"
```

---

## NuGet (.NET)

```bash
dotnet nuget add source https://nexus.${domain}/repository/nuget/index.json --name nexus
```

---

## Composer (PHP)

```bash
composer config -g repos.packagist composer https://nexus.${domain}/repository/composer/
composer clear-cache
composer install
```

---

## APT (Debian / Ubuntu / Kali)

See **[APT](apt.html)** for full steps.

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://nexus.${domain}/repository/apt/key.asc \
  | sudo tee /etc/apt/keyrings/nexus-apt-group.asc >/dev/null

echo 'deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt jammy main universe' \
  | sudo tee /etc/apt/sources.list.d/nexus-apt.list

sudo apt-get update
```

---

## Alpine (apk)

```bash
printf '%s\n' \
  https://nexus.${domain}/repository/alpine/v3.20/main \
  https://nexus.${domain}/repository/alpine/v3.20/community \
  | sudo tee /etc/apk/repositories

apk update
```

---

## Hugging Face

```bash
export HF_ENDPOINT=https://nexus.${domain}/repository/huggingface-upstream
```

---

## Quick check

```bash
curl -fsS -o /dev/null -w "%{http_code}\n" https://nexus.${domain}/repository/pypi/simple/pip/
curl -fsS -o /dev/null -w "%{http_code}\n" https://nexus.${domain}/repository/npm/lodash
curl -fsS -o /dev/null -w "%{http_code}\n" https://nexus.${domain}/repository/cargo/config.json
curl -fsS -o /dev/null -w "%{http_code}\n" https://nexus.${domain}/repository/apt/
```

---

## Path map

| Ecosystem | URL |
|-----------|-----|
| Cargo | `https://nexus.${domain}/repository/cargo/` |
| PyPI | `https://nexus.${domain}/repository/pypi/simple` |
| npm | `https://nexus.${domain}/repository/npm/` |
| Go | `https://nexus.${domain}/repository/go/` |
| Go sum | `https://nexus.${domain}/repository/go-sum/` |
| NuGet | `https://nexus.${domain}/repository/nuget/index.json` |
| Composer | `https://nexus.${domain}/repository/composer/` |
| Alpine | `https://nexus.${domain}/repository/alpine/…` |
| APT | `https://nexus.${domain}/repository/apt/` |
| Docker | `nexus.${domain}/repository/docker/…` |
| Node dist | `https://nexus.${domain}/repository/nodejs/` |
