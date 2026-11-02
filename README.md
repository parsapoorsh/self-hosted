# self-hosted

Docker Compose stack behind nginx: **Authelia** (SSO), **Nextcloud**, **Nexus Repository**, **Kiwix**, and a small landing page. One human admin account is shared across the apps.

## Services

| Host | Service |
|------|---------|
| `www.<DOMAIN>` / apex | Landing page (`static/`) |
| `auth.<DOMAIN>` | Authelia (OIDC IdP) |
| `cloud.<DOMAIN>` | Nextcloud (OIDC via Authelia) |
| `nexus.<DOMAIN>` | Nexus UI (OIDC via oauth2-proxy + Rut Auth) |
| `kiwix.<DOMAIN>` | Kiwix (optional Anubis bot check) |

Localhost aliases use the same names under `*.localhost` (for example `https://nexus.localhost/`).

Package/registry traffic on Nexus (`/repository/`, `/v2/`) stays on Nexus basic auth or anonymous access. The browser UI is gated by Authelia.

## Requirements

- Docker with Compose v2
- Ports `80` / `443` free (or set `HTTP_PORT` / `HTTPS_PORT` in `.env`)
- OpenSSL (localhost cert scripts)

## Quick start

```bash
cp .env.example .env
# edit DOMAIN, APP_SCHEME, POSTGRES_PASSWORD, KEYCLOAK_ADMIN_PASSWORD

./scripts/compose.sh up -d
```

`./scripts/compose.sh` refreshes gitignored `.env.secrets` from `.env`, runs `docker compose` with both files, then runs `./scripts/smoke-check.sh` after `up -d`. Prefer it over bare `docker compose` so internal secrets stay in sync and boot is verified.

First boot can take a few minutes (Authelia config, Nextcloud install, Nexus catalog). Re-check anytime with:

```bash
./scripts/smoke-check.sh
```

### Login

Use the single admin from `.env`:

- **Username:** `KEYCLOAK_ADMIN` (default `admin`)
- **Password:** `KEYCLOAK_ADMIN_PASSWORD`

(`KEYCLOAK_*` names are kept so existing `.env` files keep working; the IdP is Authelia.)

That account works for:

- Authelia portal (`auth.<DOMAIN>`)
- Nextcloud (local admin + Authelia OIDC)
- Nexus UI (Authelia OIDC) and Nexus REST basic auth

Nexus bootstrap (every start) also:

- accepts the Community EULA
- enables anonymous read access
- creates Rut Auth for Authelia SSO
- applies `nexus/catalog.json` (blob stores + hosted/proxy/group repos)

## Configuration

### Root `.env` (you edit this)

| Variable | Purpose |
|----------|---------|
| `DOMAIN` | Apex domain; subdomains are `auth` / `cloud` / `nexus` / `kiwix` / `www` |
| `APP_SCHEME` | `http` or `https` for OIDC redirect URLs |
| `POSTGRES_PASSWORD` | Postgres superuser (infrastructure only) |
| `KEYCLOAK_ADMIN` | Shared app admin username |
| `KEYCLOAK_ADMIN_PASSWORD` | Shared app admin password |

Optional: `HTTP_PORT`, `HTTPS_PORT`.

### Derived secrets (do not commit)

`./scripts/sync-secrets.sh` writes `.env.secrets` (gitignored):

- App DB role passwords (from `POSTGRES_PASSWORD`)
- Authelia session / storage / OIDC HMAC secrets (from `POSTGRES_PASSWORD`)
- OIDC client secrets and oauth2-proxy cookie secret (from `KEYCLOAK_ADMIN_PASSWORD`)

Tracked `*/env` files hold non-secret service constants only.

### Per-service constants

| Path | Notes |
|------|--------|
| `authelia/env` | OIDC client IDs |
| `nextcloud/env` | Postgres/redis hosts, OIDC provider id |
| `nexus/env` | JVM heap/direct caps, Rut Auth header name |
| `nexus/oauth2-*.env` | oauth2-proxy behavior (DOMAIN vs localhost) |
| `postgres/env` | Default role/db names |
| `nginx/` | Edge templates and snippets |

## TLS

### Production-style domain

```bash
./scripts/self-signed.sh          # cert/<DOMAIN>/ with *.DOMAIN SAN
# or place real certs at cert/<DOMAIN>/{fullchain,privkey}.pem
```

Set `APP_SCHEME=https` when the edge is HTTPS end-to-end for browsers.

### Localhost

One cert covers the whole `*.localhost` tree:

```bash
./scripts/gen-localhost-cert.sh
./scripts/trust-localhost-ca.sh   # trust cert/localhost/ca.pem once on this machine
```

Nginx also creates the localhost cert on first start if `cert/` is writable.

## Day-to-day

```bash
./scripts/compose.sh ps
./scripts/compose.sh logs -f authelia
./scripts/compose.sh restart nexus
./scripts/compose.sh down
```

### Authelia users

File-backend accounts (OIDC logins) are managed with:

```bash
./scripts/authelia-users.py list
./scripts/authelia-users.py add alice --email alice@example.com
./scripts/authelia-users.py set-password alice
./scripts/authelia-users.py remove alice
./scripts/authelia-users.py sync-admin   # re-apply KEYCLOAK_ADMIN* from .env
```

Needs Authelia running and host `PyYAML` (`python3 -m pip install --user pyyaml`). Passwords are hashed inside the Authelia container. The users file lives on the `authelia_data` volume and survives restarts; only a missing file is re-seeded with the shared admin on first boot.

Full wipe (containers **and** named volumes):

```bash
./scripts/reset.sh
```

Add a Postgres app DB on an already-initialized volume:

```bash
./scripts/pg-app-db.sh <db> <user> <password>
```

## How SSO is wired

1. **Authelia** boots via `authelia/docker-entrypoint.sh`:
   - Seeds file user DB with shared admin on first boot (later edits via `scripts/authelia-users.py`)
   - Writes OIDC clients `nextcloud` + `nexus`
   - Serves portal + OIDC on `auth.<DOMAIN>` and `auth.localhost`
2. **Nextcloud** hook `nextcloud/hooks/before-starting/99-oidc.sh` registers `user_oidc` against Authelia.
3. **Nexus** UI:
   - nginx `auth_request` → **oauth2-proxy** → Authelia
   - proxy sets `X-Remote-User`; Nexus **Rut Auth** maps that to a Nexus user
   - `nexus/bootstrap.sh` sets admin password, Rut capability, realms, and catalog repos

## Layout

```
docker-compose.yml
.env / .env.example          # human settings
.env.secrets                 # generated, gitignored
authelia/                    # IdP + runtime config entrypoint
nextcloud/                   # FPM app + OIDC hook
nexus/                       # repo manager + oauth2-proxy env + catalog
nginx/                       # edge TLS and vhosts
postgres/ redis/             # shared data plane
kiwix/ anubis/ static/       # zim server, bot check, landing
scripts/                     # compose wrapper, certs, reset
cert/                        # TLS material (gitignored)
```

## Notes

- Do not commit `.env` or `.env.secrets`.
- Changing `KEYCLOAK_ADMIN_PASSWORD` regenerates OIDC secrets on the next `./scripts/compose.sh` run; Authelia rebuilds client hashes and the user password on start. DB role passwords follow `POSTGRES_PASSWORD` and stay stable when only the admin password changes.
- Nexus first start is heavy; healthchecks allow a long `start_period`.
- Authelia typically uses ~30–80 MiB RAM.
- Nexus is still a large Java app; `nexus/env` caps heap at 768 MiB + 512 MiB direct (~1 GiB RSS typical). Bump those if you see OOMs.
