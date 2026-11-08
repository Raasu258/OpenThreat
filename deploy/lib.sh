# Shared helpers for deploy/install.sh, deploy/deploy.sh and deploy/ot-run.sh.
# shellcheck shell=bash
# Sourced, not executed. Expects: set -Eeuo pipefail in the caller.

OT_REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
OT_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/openthreat"
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# systemd --user needs these when entered via su/sudo instead of a login
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

DATA_UNITS=(openthreat-postgres openthreat-redis)
APP_UNITS=(openthreat-backend openthreat-frontend openthreat-worker openthreat-beat openthreat-nginx)
ALL_UNITS=("${DATA_UNITS[@]}" "${APP_UNITS[@]}")
LOCAL_IMG=localhost/openthreat   # + -backend:current / -frontend:previous ...

log()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------------ .env

# Value of KEY from .env (last occurrence wins, surrounding quotes stripped).
# Parsed, never sourced: secrets may contain shell metacharacters.
env_get() { # KEY [default]
  local v
  v="$(sed -n "s/^[[:space:]]*$1=//p" "$OT_REPO/.env" | tail -n1 \
       | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
  printf '%s' "${v:-${2:-}}"
}

load_settings() {
  [ -f "$OT_REPO/.env" ] || die ".env missing in $OT_REPO (start from .env.vps.example)"
  REGISTRY="$(env_get OT_REGISTRY ghcr.io/raasu258)"
  HTTP_PORT="$(env_get NGINX_HTTP_PORT 8082)"
  HTTPS_PORT="$(env_get NGINX_HTTPS_PORT 8443)"
  SUBNET="$(env_get OT_SUBNET 10.91.73)"   # first three octets, /24
  BACKUP_DIR="$(env_get DEPLOY_BACKUP_DIR "$HOME/openthreat-backups")"
  BACKUP_KEEP="$(env_get DEPLOY_BACKUP_KEEP 14)"
  NOTIFY_URL="$(env_get DEPLOY_NOTIFY_URL)"
  HEALTH_TIMEOUT="$(env_get DEPLOY_HEALTH_TIMEOUT 300)"   # seconds
}

# Container env files, rendered from .env into the state dir (mode 600).
# Postgres only gets its own credentials; the app gets what it needs.
render_env_files() {
  local user db pw pw_url k
  mkdir -p "$OT_STATE"; chmod 700 "$OT_STATE"
  user="$(env_get POSTGRES_USER openthreat)"
  db="$(env_get POSTGRES_DB openthreat)"
  pw="$(env_get POSTGRES_PASSWORD)"
  [ -n "$pw" ] || die "POSTGRES_PASSWORD is empty in .env"
  case "$pw" in *[!A-Za-z0-9._~-]*)   # percent-encode for the URL
    # via stdin, never argv: arguments are visible to every user in ps
    pw_url="$(printf '%s' "$pw" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')" ;;
    *) pw_url="$pw" ;;
  esac
  [ "$(env_get SECRET_KEY | wc -c)" -gt 32 ] || die "SECRET_KEY must be >= 32 chars (openssl rand -hex 32)"

  umask 077
  printf 'POSTGRES_USER=%s\nPOSTGRES_DB=%s\nPOSTGRES_PASSWORD=%s\n' "$user" "$db" "$pw" > "$OT_STATE/db.env.tmp"
  {
    printf 'DATABASE_URL=postgresql://%s:%s@postgres:5432/%s\n' "$user" "$pw_url" "$db"
    printf 'REDIS_URL=redis://redis:6379\n'
    printf 'ENVIRONMENT=%s\n' "$(env_get ENVIRONMENT production)"
    printf 'LOG_LEVEL=%s\n' "$(env_get LOG_LEVEL INFO)"
    printf 'ACCESS_TOKEN_EXPIRE_MINUTES=%s\n' "$(env_get ACCESS_TOKEN_EXPIRE_MINUTES 60)"
    printf 'SMTP_ENABLED=%s\n' "$(env_get SMTP_ENABLED false)"
    printf 'SMTP_PORT=%s\n' "$(env_get SMTP_PORT 587)"
    printf 'SMTP_FROM_NAME=%s\n' "$(env_get SMTP_FROM_NAME OpenThreat)"
    for k in SECRET_KEY CSRF_SECRET_KEY ALLOWED_ORIGINS NVD_API_KEY OLLAMA_HOST LLM_MODEL \
             SMTP_HOST SMTP_USERNAME SMTP_PASSWORD SMTP_FROM_EMAIL; do
      printf '%s=%s\n' "$k" "$(env_get "$k")"
    done
  } > "$OT_STATE/app.env.tmp"
  umask 022
  mv "$OT_STATE/db.env.tmp" "$OT_STATE/db.env"
  mv "$OT_STATE/app.env.tmp" "$OT_STATE/app.env"
}

# ----------------------------------------------------------------- units

# Render deploy/quadlet + deploy/systemd into the user's unit dirs. Prints
# the names of container units whose definition changed (to restart them).
render_units() {
  local src dst name tmp
  mkdir -p "$QUADLET_DIR" "$UNIT_DIR"
  for src in "$OT_REPO"/deploy/quadlet/* "$OT_REPO"/deploy/systemd/*; do
    name="$(basename "$src")"
    case "$src" in */quadlet/*) dst="$QUADLET_DIR/$name" ;; *) dst="$UNIT_DIR/$name" ;; esac
    tmp="$(mktemp)"
    sed -e "s#@REPO@#$OT_REPO#g" -e "s#@STATE@#$OT_STATE#g" -e "s#@SUBNET@#$SUBNET#g" \
        -e "s#@HTTP_PORT@#$HTTP_PORT#g" -e "s#@HTTPS_PORT@#$HTTPS_PORT#g" "$src" > "$tmp"
    if ! cmp -s "$tmp" "$dst" 2>/dev/null; then
      mv "$tmp" "$dst"; chmod 644 "$dst"
      case "$name" in *.container) echo "${name%.container}" ;; *.socket) echo "$name" ;; esac
    else
      rm -f "$tmp"
    fi
  done
  # units removed from the repo (e.g. after a rollback to an older commit)
  for dst in "$QUADLET_DIR"/openthreat* ; do
    [ -e "$dst" ] || continue
    [ -e "$OT_REPO/deploy/quadlet/$(basename "$dst")" ] || { rm -f "$dst"; log "removed stale unit $(basename "$dst")" >&2; }
  done
  for dst in "$UNIT_DIR"/openthreat* ; do
    [ -f "$dst" ] || continue
    name="$(basename "$dst")"
    [ -e "$OT_REPO/deploy/systemd/$name" ] && continue
    systemctl --user disable --now "$name" >/dev/null 2>&1 || true
    rm -f "$dst"; log "removed stale unit $name" >&2
  done
  systemctl --user daemon-reload
}

# Public ports are held by openthreat-nginx.socket (socket activation keeps
# the client IPs). Start it before nginx; an nginx from an older unit that
# published the ports itself must release them first.
ensure_socket() { # [restart]  - "restart" after the socket definition changed
  local sock=openthreat-nginx.socket
  [ -f "$UNIT_DIR/$sock" ] || return 0      # commit without socket activation
  systemctl --user enable "$sock" >/dev/null 2>&1 || true
  if [ "${1:-}" = restart ] || ! systemctl --user is-active --quiet "$sock"; then
    systemctl --user stop openthreat-nginx.service "$sock" 2>/dev/null || true
    systemctl --user start "$sock"
  fi
}

# ---------------------------------------------------------------- images

tag_current() { # sha-tag -> pull both images and tag them :current
  local svc
  for svc in backend frontend; do
    podman pull -q "$REGISTRY/openthreat-$svc:$1" >/dev/null || return 1
  done
  for svc in backend frontend; do
    if podman image exists "$LOCAL_IMG-$svc:current"; then
      podman tag "$LOCAL_IMG-$svc:current" "$LOCAL_IMG-$svc:previous"
    fi
    podman tag "$REGISTRY/openthreat-$svc:$1" "$LOCAL_IMG-$svc:current"
  done
}

images_exist() { # sha-tag -> 0 if both images are published
  local svc
  for svc in backend frontend; do
    podman pull -q "$REGISTRY/openthreat-$svc:$1" >/dev/null 2>&1 || return 1
  done
}

# ---------------------------------------------------------------- state

state_get() { [ -f "$OT_STATE/$1" ] && cat "$OT_STATE/$1" || true; }
state_set() { mkdir -p "$OT_STATE"; printf '%s\n' "$2" > "$OT_STATE/$1"; }

notify() { # title, message
  [ -n "${NOTIFY_URL:-}" ] || return 0
  curl -fsS -m 10 -H "Title: $1" -d "$2" "$NOTIFY_URL" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- database

# pg_dump of the running database, verified by listing its contents.
# Fails (non-zero) if no backup could be made - callers must not continue.
backup_db() { # container-name label
  local pg="$1" label="$2" file
  podman container exists "$pg" || { warn "$pg not running - no backup"; return 1; }
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  file="$BACKUP_DIR/openthreat-$(date +%Y%m%d-%H%M%S)-$label.dump"
  podman exec "$pg" sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$file.tmp" \
    || { rm -f "$file.tmp"; warn "pg_dump failed"; return 1; }
  podman exec -i "$pg" pg_restore -l < "$file.tmp" > /dev/null \
    || { rm -f "$file.tmp"; warn "backup does not verify (pg_restore -l)"; return 1; }
  mv "$file.tmp" "$file"; chmod 600 "$file"
  LAST_BACKUP="$file"
  log "backup: $file ($(du -h "$file" | cut -f1))"
  # keep the newest $BACKUP_KEEP dumps (pre-quadlet migration dump is kept separately)
  # (glob + loop instead of ls|grep: no pipefail false negatives)
  local f n=0
  for f in $(ls -1t "$BACKUP_DIR"/openthreat-*.dump 2>/dev/null || true); do
    case "$f" in *-pre-quadlet.dump) continue ;; esac
    n=$((n + 1))
    [ "$n" -le "$BACKUP_KEEP" ] || rm -f "$f"
  done
  return 0
}

db_count() { # container -> number of CVEs (or "?")
  podman exec "$1" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from vulnerabilities"' 2>/dev/null || echo "?"
}

# One-off command with the app image on the stack network (migrations,
# imports, shells). Extra podman args before --, command after.
run_app() {
  local args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  podman run --rm --network openthreat --env-file "$OT_STATE/app.env" \
    "${args[@]}" "$LOCAL_IMG-backend:current" "$@"
}

migrate_db() {
  log "migrations"
  run_app -- alembic upgrade head || return 1
  run_app -- python -m backend.migrations.run_migrations || return 1
}

# ---------------------------------------------------------------- health

health_check() { # [timeout seconds]
  local deadline=$(( $(date +%s) + ${1:-300} )) api web bad u
  while :; do
    bad=""
    for u in "${ALL_UNITS[@]}"; do
      systemctl --user is-active --quiet "$u.service" || bad="$bad $u"
    done
    if [ -f "$UNIT_DIR/openthreat-nginx.socket" ]; then
      systemctl --user is-active --quiet openthreat-nginx.socket || bad="$bad openthreat-nginx.socket"
    fi
    api="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HTTPS_PORT/health" || true)"
    web="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HTTPS_PORT/" || true)"
    if [ -z "$bad" ] && [ "$api" = 200 ] && [ "$web" = 200 ]; then
      log "health ok (api=$api web=$web, all units active)"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "health FAILED: api=$api web=$web inactive:${bad:- none}"
      for u in $bad; do journalctl --user -u "$u.service" -n 15 --no-pager 2>/dev/null | sed "s/^/  [$u] /" || true; done
      return 1
    fi
    sleep 5
  done
}
