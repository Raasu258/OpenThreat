#!/usr/bin/env bash
# Pull-based deploy of OpenThreat on the VPS (rootless Podman + Quadlet).
#
#   deploy/deploy.sh             deploy origin/main if it's new and CI published images
#   deploy/deploy.sh --force     redeploy origin/main even if current / previously failed
#   deploy/deploy.sh --status    what is deployed, unit and container health
#   deploy/deploy.sh --rollback  back to the previous deploy (code + images)
#
# Run by openthreat-deploy.timer every 5 minutes. Flow for a new commit:
#   images sha-<commit> on GHCR? (no -> CI not done, try next run)
#   checkout -> re-exec the new deploy.sh -> pg_dump backup (verified)
#   tag images :current (old :current -> :previous) -> render units
#   migrations -> restart app units -> health check
#   failed -> previous images + code, restart, mark commit failed
# Postgres and Redis are only restarted when their unit definition changed.
set -Eeuo pipefail
# shellcheck source=deploy/lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$OT_REPO"

BRANCH=main
FORCE=0

# One deploy at a time. flock -o: the lock fd is not inherited by anything we
# start (podman/conmon would otherwise keep the lock after we exit).
if [ -z "${OT_DEPLOY_LOCKED:-}" ]; then
  mkdir -p "$OT_STATE"
  # exit 75 = another deploy holds the lock (SuccessExitStatus in the unit)
  OT_DEPLOY_LOCKED=1 exec flock -n -E 75 -o "$OT_STATE/deploy.lock" "$0" "$@"
fi

load_settings

# Never touch a host that hasn't been migrated: a second Postgres on the
# compose stack's data volume would corrupt it.
if [ -n "$(podman ps -a -q --filter label=io.podman.compose.project=openthreat 2>/dev/null)" ]; then
  die "podman-compose containers exist - run deploy/install.sh once (it migrates them)"
fi
case "${1:-}" in --status) ;; *)
  [ -n "$(state_get deployed)" ] || die "not installed yet - run deploy/install.sh" ;;
esac

restart_units() { # unit names (without .service)
  [ $# -gt 0 ] || return 0
  log "restarting: $*"
  # --no-block + health_check instead of waiting per unit: a unit that never
  # gets healthy must not hang the deploy until TimeoutStartSec.
  systemctl --user restart --no-block "${@/%/.service}"
}

prune_images() {
  local keep_cur keep_prev
  keep_cur="sha-$(state_get deployed)"; keep_prev="sha-$(state_get previous)"
  podman images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "/openthreat-(backend|frontend):sha-" \
    | grep -v -e ":$keep_cur\$" -e ":$keep_prev\$" | xargs -r podman rmi >/dev/null 2>&1 || true
  podman image prune -f >/dev/null 2>&1 || true
}

# Activate commit $1 (code already checked out). Returns non-zero on failure.
activate() {
  local commit="$1" changed
  render_env_files
  tag_current "sha-$commit" || { log "could not pull images sha-$commit"; return 1; }
  changed="$(render_units)"
  systemctl --user start openthreat-postgres.service openthreat-redis.service
  migrate_db || { log "migrations failed"; return 1; }
  # app units always (new images); data units only if their definition changed
  # shellcheck disable=SC2046
  restart_units "${APP_UNITS[@]}" $(printf '%s\n' $changed | grep -xE 'openthreat-(postgres|redis)' || true)
  health_check "$HEALTH_TIMEOUT"
}

deploy() {
  local target current prev short
  git fetch --quiet origin "$BRANCH"
  target="$(git rev-parse "origin/$BRANCH")"; short="${target:0:12}"
  current="$(state_get deployed)"

  if [ "$target" = "$current" ] && [ "$FORCE" = 0 ]; then return 0; fi
  if [ "$target" = "$(state_get failed)" ] && [ "$FORCE" = 0 ]; then
    log "$short failed before - skipped until a newer commit (or --force)"; return 0
  fi
  if ! images_exist "sha-$target"; then
    log "images for $short not published yet (CI running or failed) - next run"; return 0
  fi
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    die "tracked files modified on the VPS - commit them to $BRANCH instead: $(git status --porcelain --untracked-files=no | tr '\n' ' ')"
  fi

  log "deploying $short: $(git log -1 --format=%s "$target")"
  git checkout --quiet -B "$BRANCH" "$target"
  # continue with the deploy.sh of the new commit
  exec "$OT_REPO/deploy/deploy.sh" --apply "$target"
}

apply() {
  local target="$1" prev short="${1:0:12}"
  prev="$(state_get deployed)"

  LAST_BACKUP=""
  if systemctl --user is-active --quiet openthreat-postgres.service; then
    backup_db openthreat-postgres "$short" || die "no verified backup - not deploying $short"
  fi

  if activate "$target"; then
    state_set deployed "$target"
    [ -n "$prev" ] && [ "$prev" != "$target" ] && state_set previous "$prev"
    rm -f "$OT_STATE/failed"
    prune_images
    log "deployed $short"
    notify "OpenThreat deployed" "$short: $(git log -1 --format=%s "$target")"
    return 0
  fi

  state_set failed "$target"
  if [ -z "$prev" ]; then
    notify "OpenThreat deploy FAILED" "$short failed and there is no previous deploy to roll back to"
    die "deploy of $short failed; no previous deploy to roll back to"
  fi
  log "deploy of $short FAILED - rolling back to ${prev:0:12}"
  git checkout --quiet -B "$BRANCH" "$prev"
  render_env_files
  local svc
  for svc in backend frontend; do
    podman tag "$LOCAL_IMG-$svc:previous" "$LOCAL_IMG-$svc:current"
  done
  render_units >/dev/null
  restart_units "${APP_UNITS[@]}"
  if health_check "$HEALTH_TIMEOUT"; then
    log "rolled back to ${prev:0:12}"
  else
    log "rollback is unhealthy too - manual intervention needed"
  fi
  log "NOTE: migrations are not reverted. Backup from before the deploy: ${LAST_BACKUP:-none}"
  notify "OpenThreat deploy FAILED" "$short rolled back to ${prev:0:12}. Backup: ${LAST_BACKUP:-none}"
  return 1
}

rollback() {
  local prev cur
  prev="$(state_get previous)"; cur="$(state_get deployed)"
  [ -n "$prev" ] || die "no previous deploy recorded"
  podman image exists "$LOCAL_IMG-backend:previous" || die "no :previous images to roll back to"
  log "manual rollback ${cur:0:12} -> ${prev:0:12}"
  backup_db openthreat-postgres "rollback-${cur:0:12}" || die "no verified backup - not rolling back"
  state_set failed "$cur"     # don't redeploy it automatically
  git checkout --quiet -B "$BRANCH" "$prev"
  local svc
  for svc in backend frontend; do
    podman tag "$LOCAL_IMG-$svc:current" "$LOCAL_IMG-$svc:rolledback"
    podman tag "$LOCAL_IMG-$svc:previous" "$LOCAL_IMG-$svc:current"
  done
  render_env_files
  render_units >/dev/null
  restart_units "${APP_UNITS[@]}"
  state_set deployed "$prev"
  rm -f "$OT_STATE/previous"
  health_check "$HEALTH_TIMEOUT"
}

status() {
  local u state health
  log "deployed: $(state_get deployed | cut -c1-12)  $(git log -1 --format=%s "$(state_get deployed)" 2>/dev/null || true)"
  log "origin:   $(git rev-parse --short=12 "origin/$BRANCH" 2>/dev/null || echo ?)  (git fetch to refresh)"
  log "previous: $(state_get previous | cut -c1-12)"
  [ -n "$(state_get failed)" ] && log "failed:   $(state_get failed | cut -c1-12) (skipped until a newer commit)"
  for u in "${ALL_UNITS[@]}"; do
    state="$(systemctl --user is-active "$u.service" 2>/dev/null || true)"
    health="$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$u" 2>/dev/null || echo -)"
    printf '  %-22s %-10s %s\n' "$u" "$state" "$health"
  done
  printf '  timer: %s\n' "$(systemctl --user list-timers openthreat-deploy.timer --no-legend 2>/dev/null | awk '{print "next " $1" "$2" "$3}')"
}

case "${1:-}" in
  "")          deploy ;;
  --force)     FORCE=1; deploy ;;
  --apply)     apply "${2:?commit}" ;;
  --rollback)  rollback ;;
  --status)    status ;;
  *)           sed -n '2,8p' "$0"; exit 2 ;;
esac
