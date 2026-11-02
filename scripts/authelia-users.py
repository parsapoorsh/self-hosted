#!/usr/bin/env python3
"""Manage Authelia file-backend users for this compose stack.

Users live in the authelia_data volume at /data/users_database.yml.
Password hashes are generated with the Authelia container CLI.

Examples:
  ./scripts/authelia-users.py list
  ./scripts/authelia-users.py add alice --email alice@example.com
  ./scripts/authelia-users.py add bob --password 's3cret' --group users
  ./scripts/authelia-users.py set-password alice
  ./scripts/authelia-users.py remove bob
  ./scripts/authelia-users.py sync-admin
"""

from __future__ import annotations

import argparse
import getpass
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "authelia-users: need PyYAML (python3 -m pip install --user pyyaml)",
        file=sys.stderr,
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
USERS_PATH = "/data/users_database.yml"
USERNAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")


def die(msg: str, code: int = 1) -> None:
    print(f"authelia-users: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_dotenv(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip("'").strip('"')
        env[key] = val
    return env


def compose_cmd() -> list[str]:
    env_file = ROOT / ".env"
    secrets = ROOT / ".env.secrets"
    if not env_file.is_file():
        die(f"missing {env_file} (copy .env.example)")
    if not secrets.is_file():
        subprocess.run(
            [str(ROOT / "scripts" / "sync-secrets.sh")],
            cwd=str(ROOT),
            check=True,
        )
    return [
        "docker",
        "compose",
        "--env-file",
        str(env_file),
        "--env-file",
        str(secrets),
        "-f",
        str(ROOT / "docker-compose.yml"),
    ]


def compose_run(
    args: list[str],
    *,
    check: bool = True,
    capture: bool = True,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    cmd = compose_cmd() + args
    return subprocess.run(
        cmd,
        cwd=str(ROOT),
        check=check,
        capture_output=capture,
        text=True,
        input=input_text,
    )


def ensure_authelia_running() -> None:
    proc = compose_run(
        ["ps", "--status", "running", "-q", "authelia"],
        check=False,
    )
    if proc.returncode != 0 or not (proc.stdout or "").strip():
        die("authelia is not running (./scripts/compose.sh up -d authelia)")


def hash_password(password: str) -> str:
    """Hash with Authelia's argon2 helper inside the running container."""
    proc = compose_run(
        [
            "exec",
            "-T",
            "authelia",
            "authelia",
            "crypto",
            "hash",
            "generate",
            "argon2",
            "--password",
            password,
        ],
        check=False,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        die(f"password hash failed: {err}")
    for line in (proc.stdout or "").splitlines():
        if line.startswith("Digest: "):
            return line[len("Digest: ") :].strip()
    die("password hash produced no Digest line")


def read_users_file() -> dict:
    ensure_authelia_running()
    proc = compose_run(
        ["exec", "-T", "authelia", "cat", USERS_PATH],
        check=False,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        die(f"cannot read {USERS_PATH}: {err}")
    data = yaml.safe_load(proc.stdout) or {}
    if not isinstance(data, dict):
        die("users database root must be a mapping")
    users = data.get("users")
    if users is None:
        data["users"] = {}
    elif not isinstance(users, dict):
        die("users database 'users' must be a mapping")
    return data


def write_users_file(data: dict, *, restart: bool = True) -> None:
    ensure_authelia_running()
    body = yaml.safe_dump(
        data,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
    )
    # Write via container shell so volume ownership stays correct.
    proc = compose_run(
        [
            "exec",
            "-T",
            "authelia",
            "sh",
            "-c",
            f"cat >{USERS_PATH}.tmp && mv {USERS_PATH}.tmp {USERS_PATH} && chmod 600 {USERS_PATH}",
        ],
        check=False,
        input_text=body,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        die(f"cannot write {USERS_PATH}: {err}")
    if restart:
        print("authelia-users: restarting authelia to reload users", file=sys.stderr)
        restart_proc = compose_run(
            ["restart", "authelia"],
            check=False,
            capture=True,
        )
        if restart_proc.returncode != 0:
            err = (restart_proc.stderr or restart_proc.stdout or "").strip()
            die(f"wrote users but restart failed: {err}")


def validate_username(name: str) -> str:
    if not USERNAME_RE.match(name):
        die(
            "username must match "
            r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$"
            f" (got {name!r})"
        )
    return name


def admin_username() -> str:
    env = load_dotenv(ROOT / ".env")
    return env.get("AUTH_ADMIN") or env.get("KEYCLOAK_ADMIN") or "admin"


def admin_password() -> str:
    env = load_dotenv(ROOT / ".env")
    pw = env.get("AUTH_ADMIN_PASSWORD") or env.get("KEYCLOAK_ADMIN_PASSWORD") or ""
    if not pw:
        die("KEYCLOAK_ADMIN_PASSWORD (or AUTH_ADMIN_PASSWORD) missing in .env")
    return pw


def admin_email(username: str) -> str:
    env = load_dotenv(ROOT / ".env")
    if env.get("AUTH_ADMIN_EMAIL"):
        return env["AUTH_ADMIN_EMAIL"]
    domain = env.get("DOMAIN") or "example.com"
    return f"{username}@{domain}"


def fmt_user(name: str, rec: dict) -> str:
    display = rec.get("displayname") or rec.get("display_name") or ""
    email = rec.get("email") or ""
    groups = rec.get("groups") or []
    if isinstance(groups, list):
        groups_s = ",".join(str(g) for g in groups)
    else:
        groups_s = str(groups)
    disabled = "yes" if rec.get("disabled") else "no"
    return (
        f"{name:20}  disabled={disabled:3}  "
        f"display={display!r:20}  email={email!r:30}  groups={groups_s}"
    )


def cmd_list(_args: argparse.Namespace) -> int:
    data = read_users_file()
    users = data.get("users") or {}
    if not users:
        print("(no users)")
        return 0
    for name in sorted(users):
        rec = users[name] or {}
        if not isinstance(rec, dict):
            print(f"{name:20}  (invalid record)")
            continue
        print(fmt_user(name, rec))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    name = validate_username(args.username)
    data = read_users_file()
    users = data.get("users") or {}
    if name not in users:
        die(f"user {name!r} not found", code=2)
    rec = users[name] or {}
    if not isinstance(rec, dict):
        die(f"user {name!r} has invalid record")
    print(fmt_user(name, rec))
    # Never print password hash unless asked.
    if args.secrets:
        print(f"password_hash={rec.get('password', '')}")
    return 0


def prompt_password(twice: bool = True) -> str:
    pw = getpass.getpass("password: ")
    if not pw:
        die("empty password")
    if twice:
        pw2 = getpass.getpass("password (again): ")
        if pw != pw2:
            die("passwords do not match")
    return pw


def cmd_add(args: argparse.Namespace) -> int:
    name = validate_username(args.username)
    data = read_users_file()
    users = data.setdefault("users", {})
    if name in users and not args.force:
        die(f"user {name!r} already exists (use --force to replace)")

    password = args.password
    if not password:
        password = prompt_password()
    digest = hash_password(password)

    email = args.email
    if not email:
        env = load_dotenv(ROOT / ".env")
        domain = env.get("DOMAIN") or "example.com"
        email = f"{name}@{domain}"

    display = args.display_name or name
    groups = list(args.group) if args.group else ["users"]

    users[name] = {
        "disabled": bool(args.disabled),
        "displayname": display,
        "password": digest,
        "email": email,
        "groups": groups,
    }
    write_users_file(data)
    print(f"authelia-users: added {name}")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    name = validate_username(args.username)
    admin = admin_username()
    if name == admin and not args.force:
        die(f"refusing to remove shared admin {name!r} (pass --force to override)")

    data = read_users_file()
    users = data.get("users") or {}
    if name not in users:
        die(f"user {name!r} not found", code=2)
    del users[name]
    data["users"] = users
    write_users_file(data)
    print(f"authelia-users: removed {name}")
    return 0


def cmd_set_password(args: argparse.Namespace) -> int:
    name = validate_username(args.username)
    data = read_users_file()
    users = data.get("users") or {}
    if name not in users:
        die(f"user {name!r} not found", code=2)
    rec = users[name]
    if not isinstance(rec, dict):
        die(f"user {name!r} has invalid record")

    password = args.password
    if not password:
        password = prompt_password()
    rec["password"] = hash_password(password)
    users[name] = rec
    data["users"] = users
    write_users_file(data)
    print(f"authelia-users: updated password for {name}")
    return 0


def cmd_sync_admin(_args: argparse.Namespace) -> int:
    """Upsert the shared admin from .env (password + email)."""
    name = validate_username(admin_username())
    password = admin_password()
    email = admin_email(name)
    data = read_users_file()
    users = data.setdefault("users", {})
    rec = users.get(name) if isinstance(users.get(name), dict) else {}
    groups = rec.get("groups") if isinstance(rec.get("groups"), list) else ["admins"]
    if "admins" not in groups:
        groups = ["admins", *groups]
    users[name] = {
        "disabled": False,
        "displayname": rec.get("displayname") or "Admin",
        "password": hash_password(password),
        "email": email,
        "groups": groups,
    }
    data["users"] = users
    write_users_file(data)
    print(f"authelia-users: synced admin {name}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="authelia-users",
        description="List / add / remove Authelia users for self-hosted compose.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("list", help="list users")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("show", help="show one user")
    sp.add_argument("username")
    sp.add_argument(
        "--secrets",
        action="store_true",
        help="include password hash",
    )
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("add", help="add or replace a user")
    sp.add_argument("username")
    sp.add_argument("--password", help="plain password (prompted if omitted)")
    sp.add_argument("--email")
    sp.add_argument("--display-name")
    sp.add_argument(
        "--group",
        action="append",
        default=[],
        help="group (repeatable; default: users)",
    )
    sp.add_argument("--disabled", action="store_true")
    sp.add_argument(
        "--force",
        action="store_true",
        help="replace existing user",
    )
    sp.set_defaults(func=cmd_add)

    sp = sub.add_parser("remove", help="remove a user")
    sp.add_argument("username")
    sp.add_argument(
        "--force",
        action="store_true",
        help="allow removing the shared admin",
    )
    sp.set_defaults(func=cmd_remove)

    sp = sub.add_parser("set-password", help="set a user password")
    sp.add_argument("username")
    sp.add_argument("--password", help="plain password (prompted if omitted)")
    sp.set_defaults(func=cmd_set_password)

    sp = sub.add_parser(
        "sync-admin",
        help="upsert shared admin from KEYCLOAK_ADMIN* in .env",
    )
    sp.set_defaults(func=cmd_sync_admin)

    return p


def main(argv: list[str] | None = None) -> int:
    os.chdir(ROOT)
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
