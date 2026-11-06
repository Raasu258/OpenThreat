#!/usr/bin/env bash
# Pull-based deploy for OpenThreat on a rootless Podman host.
#
#   deploy/deploy.sh             deploy origin/main if it moved (used by the timer)
#   deploy/deploy.sh --force     redeploy the current target even if unchanged
#   deploy/deploy.sh --rollback  go back to the previous successful deploy
#   deploy/deploy.sh --status    show what is deployed
#
# Flow: git fetch -> pull ghcr images tagged sha-<commit> (built by CI;
# if they don't exist yet, try again next run) -> DB backup -> update
# checkout + OT_IMAGE_TAG -> migrations -> restart -> health check ->
# automatic rollback of code/images on failure.
#
# The VPS never builds anything and GitHub has no access to the VPS.
# Everything runs as the unprivileged user that owns the stack.
#
# The whole script lives in main() so bash has parsed all of it before
# `git` replaces this file during a deploy.

set -Eeuo pipefail

main() {
  REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
  cd "$REPO_DIR"

  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-openthreat}"
  COMPOSE="${PODMAN_COMPOSE:-podman-compose}"
  BRANCH="${DEPLOY_BRANCH:-main}"
  STATE_DIR="$REPO_DIR/.deploy"
  mkdir -p "$STATE_DIR"

  [ -f .env ] || die ".env missing in $REPO_DIR (see .env.vps.example)"

  REGISTRY="$(env_get OT_REGISTRY)"; REGISTRY="${REGISTRY:-ghcr.io/raasu258}"
  HTTPS_PORT="$(env_get NGINX_HTTPS_PORT)"; HTTPS_PORT="${HTTPS_PORT:-8443}"
  BACKUP_DIR="$(env_get DEPLOY_BACKUP_DIR)"; BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/openthreat}"
  BACKUP_KEEP="$(env_get DEPLOY_BACKUP_KEEP)"; BACKUP_KEEP="${BACKUP_KEEP:-14}"
  NOTIFY_URL="$(env_get DEPLOY_NOTIFY_URL)"

  # One deploy at a time (timer + manual run)
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || { log "another deploy is running, skipping"; return 0; }

  case "${1:-}" in
    --status)   status; return 0 ;;
    --rollback) rollback_to_previous; return $? ;;
    --force)    FORCE=1 ;;
    "")         FORCE=0 ;;
    *)          die "unknown option: $1" ;;
  esac

  deploy
}

# ---------------------------------------------------------------- helpers

log()  { printf '%s %s\n' "$(date -Is)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

notify() { # title, message
  [ -n "${NOTIFY_URL:-}" ] || return 0
  curl -fsS -m 10 -H "Title: $1" -d "$2" "$NOTIFY_URL" >/dev/null 2>&1 || true
}

env_get() { # KEY -> value from .env (last occurrence, surrounding quotes stripped)
  sed -n "s/^[[:space:]]*$1=//p" .env | tail -n1 | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

env_set() { # KEY VALUE -> replace or append in .env (keeps file mode)
  if grep -q "^[[:space:]]*$1=" .env; then
    sed -i "s|^[[:space:]]*$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

svc_container() { # compose service -> container id
  podman ps -q \
    --filter "label=io.podman.compose.project=$COMPOSE_PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$1" | head -n1
}

state_get() { [ -f "$STATE_DIR/$1" ] && cat "$STATE_DIR/$1" || true; }
state_set() { printf '%s\n' "$2" > "$STATE_DIR/$1"; }

images_for() { # commit -> pull both images; non-zero if any is missing
  local tag="sha-$1" svc
  for svc in backend frontend; do
    podman pull -q "$REGISTRY/openthreat-$svc:$tag" >/dev/null 2>&1 || return 1
  done
}

wait_postgres() {
  local pg
  for _ in $(seq 1 30); do
    pg="$(svc_container postgres)"
    if [ -n "$pg" ] && podman exec "$pg" sh -c 'pg_isready -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

backup_db() {
  local pg file
  pg="$(svc_container postgres)"
  if [ -z "$pg" ]; then
    log "postgres not running, skipping backup"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  file="$BACKUP_DIR/openthreat-$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short=12 HEAD).dump"
  podman exec "$pg" sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$file.tmp"
  mv "$file.tmp" "$file"; chmod 600 "$file"
  log "backup: $file ($(du -h "$file" | cut -f1))"
  LAST_BACKUP="$file"
  # keep the newest $BACKUP_KEEP dumps
  ls -1t "$BACKUP_DIR"/openthreat-*.dump 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
}

health_check() {
  local code_api code_web
  for _ in $(seq 1 45); do
    code_api="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HTTPS_PORT/health" || true)"
    code_web="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HTTPS_PORT/" || true)"
    if [ "$code_api" = 200 ] && [ "$code_web" = 200 ] && [ -n "$(svc_container celery-worker)" ]; then
      log "health ok (api=$code_api web=$code_web)"
      return 0
    fi
    sleep 4
  done
  log "health FAILED (api=$code_api web=$code_web worker=$(svc_container celery-worker))"
  return 1
}

checkout() { # commit -> move the working tree there (VPS has no local commits)
  local target="$1"
  if git merge-base --is-ancestor HEAD "$target"; then
    git merge --quiet --ff-only "$target"
  elif git merge-base --is-ancestor "$target" HEAD && [ "$(git rev-parse HEAD)" != "$target" ]; then
    die "local commits on the VPS that are not on origin/$BRANCH - push or drop them first"
  else
    # history was rewritten upstream (rebase + force-push): follow it
    log "history diverged (force-push?), resetting; old HEAD was $(git rev-parse --short=12 HEAD)"
    git reset --quiet --hard "$target"
  fi
}

switch_to() { # commit -> run that commit's images + migrations
  local commit="$1"
  env_set OT_IMAGE_TAG "sha-$commit"
  log "stopping stack"
  $COMPOSE down >/dev/null 2>&1 || true
  $COMPOSE up -d postgres redis >/dev/null
  wait_postgres || { log "postgres did not become ready"; return 1; }
  log "migrations"
  $COMPOSE run --rm backend alembic upgrade head || return 1
  $COMPOSE run --rm backend python -m backend.migrations.run_migrations || return 1
  log "starting stack"
  $COMPOSE up -d >/dev/null
  health_check
}

# --------------------------------------------------------------- commands

deploy() {
  local current target short prev_commit prev_tag
  git fetch --quiet origin "$BRANCH"
  current="$(git rev-parse HEAD)"
  target="$(git rev-parse "origin/$BRANCH")"
  short="${target:0:12}"

  if [ "$FORCE" != 1 ] && [ "$current" = "$target" ] && [ "$(env_get OT_IMAGE_TAG)" = "sha-$target" ]; then
    return 0   # nothing to do (silent, runs every few minutes)
  fi
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    die "tracked files modified on the VPS - commit them to the $BRANCH branch instead: $(git status --porcelain --untracked-files=no | tr '\n' ' ')"
  fi
  if [ "$(state_get failed)" = "$target" ] && [ "$FORCE" != 1 ]; then
    return 0   # this commit already failed and was rolled back; wait for a new one
  fi
  if ! images_for "$target"; then
    log "images for $short not in $REGISTRY yet (CI still running or failed) - retrying next run"
    return 0
  fi

  log "deploying $short (was ${current:0:12})"
  # Third-party images use moving tags (nginx:alpine, postgres:16-alpine,
  # redis:7-alpine) - refresh them so patch releases arrive with deploys.
  $COMPOSE pull nginx postgres redis >/dev/null 2>&1 || log "warning: could not refresh nginx/postgres/redis images"
  prev_commit="$current"
  prev_tag="$(env_get OT_IMAGE_TAG)"
  LAST_BACKUP=""
  backup_db

  checkout "$target"
  if switch_to "$target"; then
    state_set previous "$prev_commit $prev_tag"
    state_set current "$target"
    rm -f "$STATE_DIR/failed"
    podman image prune -f >/dev/null 2>&1 || true
    log "deployed $short"
    notify "OpenThreat deployed" "$short: $(git log -1 --format=%s "$target")"
    return 0
  fi

  log "deploy of $short FAILED - rolling back to ${prev_commit:0:12} ($prev_tag)"
  state_set failed "$target"
  git reset --quiet --hard "$prev_commit"
  env_set OT_IMAGE_TAG "$prev_tag"
  $COMPOSE down >/dev/null 2>&1 || true
  $COMPOSE up -d >/dev/null
  if health_check; then
    log "rolled back to ${prev_commit:0:12}"
  else
    log "rollback is unhealthy too - manual intervention needed"
  fi
  log "NOTE: database migrations are not reverted automatically. Backup from before the deploy: ${LAST_BACKUP:-none}"
  notify "OpenThreat deploy FAILED" "$short failed, rolled back to ${prev_commit:0:12}. Backup: ${LAST_BACKUP:-none}"
  return 1
}

rollback_to_previous() {
  local prev prev_commit prev_tag
  prev="$(state_get previous)"
  [ -n "$prev" ] || die "no previous deploy recorded"
  prev_commit="${prev%% *}"; prev_tag="${prev#* }"
  log "manual rollback to ${prev_commit:0:12} ($prev_tag)"
  backup_db
  state_set failed "$(git rev-parse HEAD)"   # don't redeploy the current commit automatically
  git reset --quiet --hard "$prev_commit"
  env_set OT_IMAGE_TAG "$prev_tag"
  $COMPOSE down >/dev/null 2>&1 || true
  $COMPOSE up -d >/dev/null
  health_check
}

status() {
  log "checkout:  $(git rev-parse --short=12 HEAD) $(git log -1 --format=%s)"
  log "image tag: $(env_get OT_IMAGE_TAG)"
  log "previous:  $(state_get previous)"
  [ -n "$(state_get failed)" ] && log "last failed commit (skipped until a new one arrives): $(state_get failed)"
  podman ps --filter "label=io.podman.compose.project=$COMPOSE_PROJECT_NAME" --format '{{.Names}}\t{{.Status}}'
}

main "$@"; exit $?
