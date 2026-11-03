---
title: Mirror
page_title: Mirror * mirror.${domain}
---

# Package mirrors

Base host: **https://mirror.${domain}** (Nexspence behind this name)

Pull packages through the paths below. No login is required for normal installs (anonymous pull). Group repositories merge versions from their proxy members.

---

## Cargo (Rust)

```bash
mkdir -p "${CARGO_HOME:-$HOME/.cargo}"
cat > "${CARGO_HOME:-$HOME/.cargo}/config.toml" <<'EOF'
[source.crates-io]
replace-with = "mirror"

[source.mirror]
registry = "sparse+https://mirror.${domain}/repository/cargo/"
EOF
```

---

## Pip / uv / poetry (Python)

```bash
python3 -m pip config set global.index-url https://mirror.${domain}/repository/pypi/simple
python3 -m pip config set global.trusted-host mirror.${domain}

python3 -m pip install requests --index-url https://mirror.${domain}/repository/pypi/simple

export UV_INDEX_URL=https://mirror.${domain}/repository/pypi/simple

poetry source add --priority=primary mirror https://mirror.${domain}/repository/pypi/simple
```

---

## Docker

Docker Hub via `registry-mirrors` (rewrites `docker pull nginx` and other Hub images):

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://mirror.${domain}/repository/docker"
  ]
}
EOF
sudo systemctl restart docker

docker pull nginx:alpine
```

Explicit pull path (Hub, GHCR, k8s, Quay):

```bash
docker pull mirror.${domain}/repository/docker/library/nginx:alpine
docker pull mirror.${domain}/repository/ghcr/OWNER/IMAGE:TAG
docker pull mirror.${domain}/repository/k8s/pause:3.9
docker pull mirror.${domain}/repository/quay/prometheus/prometheus:latest
```

| Registry | Pull prefix |
|----------|-------------|
| Docker Hub | `mirror.${domain}/repository/docker/...` (or `registry-mirrors` above) |
| GHCR | `mirror.${domain}/repository/ghcr/...` |
| Kubernetes | `mirror.${domain}/repository/k8s/...` |
| Quay | `mirror.${domain}/repository/quay/...` |

---

## npm / yarn / pnpm

```bash
npm config set registry https://mirror.${domain}/repository/npm/
yarn config set registry https://mirror.${domain}/repository/npm/
pnpm config set registry https://mirror.${domain}/repository/npm/
```

Node distributions:

```bash
export NODEJS_ORG_MIRROR=https://mirror.${domain}/repository/nodejs/
```

---

## Go

```bash
export GOPROXY=https://mirror.${domain}/repository/go/
export GOSUMDB="sum.golang.org https://mirror.${domain}/repository/go-sum/"

go env -w GOPROXY=https://mirror.${domain}/repository/go/
go env -w GOSUMDB="sum.golang.org https://mirror.${domain}/repository/go-sum/"
```

---

## NuGet (.NET)

```bash
dotnet nuget add source https://mirror.${domain}/repository/nuget/index.json --name mirror
```

---

## Alpine (apk)

```bash
printf '%s\n' \
  https://mirror.${domain}/repository/alpine/v3.20/main \
  https://mirror.${domain}/repository/alpine/v3.20/community \
  | sudo tee /etc/apk/repositories

apk update
```

---

## Hugging Face

```bash
export HF_ENDPOINT=https://mirror.${domain}/repository/huggingface-upstream
```

---

## Quick check

```bash
curl -fsS -o /dev/null -w "%{http_code}\n" https://mirror.${domain}/repository/pypi/simple/pip/
curl -fsS -o /dev/null -w "%{http_code}\n" https://mirror.${domain}/repository/npm/lodash
curl -fsS -o /dev/null -w "%{http_code}\n" https://mirror.${domain}/repository/cargo/config.json
```

---

## Path map

| Ecosystem | URL |
|-----------|-----|
| Cargo | `https://mirror.${domain}/repository/cargo/` |
| PyPI | `https://mirror.${domain}/repository/pypi/simple` |
| npm | `https://mirror.${domain}/repository/npm/` |
| Go | `https://mirror.${domain}/repository/go/` |
| Go sum | `https://mirror.${domain}/repository/go-sum/` |
| NuGet | `https://mirror.${domain}/repository/nuget/index.json` |
| Alpine | `https://mirror.${domain}/repository/alpine/...` |
| Docker | `mirror.${domain}/repository/docker/...` |
| Node dist | `https://mirror.${domain}/repository/nodejs/` |
