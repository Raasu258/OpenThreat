#!/usr/bin/env bash
# One-time setup of OpenThreat on the VPS with rootless Podman + Quadlet.
# Also migrates an existing podman-compose installation, keeping its data.
#
# As the stack user, in the repo checkout on main:
#   git fetch origin && git checkout -B main origin/main
#   deploy/install.sh
#
# What it does:
#   1. preflight: tools, Podman version, linger, .env, TLS files, subnet
#   2. existing compose stack: verified pg_dump (kept as *-pre-quadlet.dump),
#      CVE count, then compose containers + old units are removed.
#      Volumes are NOT touched - the Quadlet units reuse them by name.
#   3. images for the checked-out commit -> units -> migrations -> start
#   4. health check, CVE count compared, deploy timer + podman auto-update on
set -Eeuo pipefail
# shellcheck source=deploy/lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$OT_REPO"

COMPOSE_LABEL=io.podman.compose.project=openthreat
REMOVED_COMPOSE=0
on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  log "install FAILED (exit $rc)."
  if [ "$REMOVED_COMPOSE" = 1 ]; then
    cat >&2 <<EOF

Your data is untouched (volumes are never removed). To get the old stack back:
  systemctl --user stop openthreat.target
  podman-compose up -d
Backup from before the migration: ${LAST_BACKUP:-none}
EOF
  fi
}
trap on_exit EXIT

# ------------------------------------------------------------- preflight
log "preflight"
[ "$(id -u)" -ne 0 ] || die "run as the stack user, not root"
for bin in podman git curl flock systemctl python3; do
  command -v "$bin" >/dev/null || die "missing: $bin"
done

pv="$(podman version --format '{{.Client.Version}}')"
case "$pv" in
  [5-9].*|[1-9][0-9].*) ;;
  4.[4-9]*) warn "Podman $pv: Notify=healthy needs Podman 5 - start order then relies on restarts (works, slower)" ;;
  *) die "Podman $pv is too old for Quadlet (need >= 4.4, recommended >= 5)" ;;
esac
[ -x /usr/libexec/podman/quadlet ] || [ -x /usr/lib/podman/quadlet ] || die "Quadlet generator not found (package podman too old?)"

if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
  log "enabling linger (services run without a login session)"
  loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"
fi
systemctl --user show-environment >/dev/null 2>&1 || die "systemd --user not reachable (log in directly as $USER, or: machinectl shell $USER@)"

load_settings
render_env_files          # validates POSTGRES_PASSWORD / SECRET_KEY
chmod 600 .env
[ -n "$(ls -A nginx/ssl 2>/dev/null)" ] || die "nginx/ssl is empty - put the TLS certificate and key there"

nets="$(podman network ls --format '{{.Name}} {{range .Subnets}}{{.Subnet}} {{end}}')"
if awk -v s="$SUBNET.0/24" '$1 != "openthreat" { for (i = 2; i <= NF; i++) if ($i == s) found = 1 } END { exit !found }' <<<"$nets"; then
  die "subnet $SUBNET.0/24 is used by another Podman network - set OT_SUBNET=<a.b.c> in .env"
fi
[ -d /var/log/journal ] || warn "journald is not persistent: 'journalctl --user' shows nothing. Fix: sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal && sudo systemctl restart systemd-journald"

target="$(git rev-parse HEAD)"
git fetch --quiet origin main || true
[ "$target" = "$(git rev-parse origin/main 2>/dev/null)" ] || warn "checkout ${target:0:12} is not origin/main"
images_exist "sha-$target" || die "no images for ${target:0:12} on $REGISTRY yet - wait for the Images workflow, then rerun"

# ------------------------------------------------- existing compose stack
count_before=""
if [ -n "$(podman ps -a -q --filter "label=$COMPOSE_LABEL")" ]; then
  log "found podman-compose stack - migrating"
  pg="$(podman ps -q --filter "label=$COMPOSE_LABEL" --filter label=com.docker.compose.service=postgres | awk 'NR==1')"
  [ -n "$pg" ] || die "compose postgres is not running - start it (podman-compose up -d postgres) so it can be backed up"
  pg="$(podman inspect --format '{{.Name}}' "$pg")"

  vols="$(podman inspect --format '{{range .Mounts}}{{.Name}} {{end}}' "$pg")"
  case " $vols " in
    *" openthreat_postgres_data "*) ;;
    *) die "compose postgres uses volume(s) '$vols', expected openthreat_postgres_data - not migrating (tell Claude)" ;;
  esac

  backup_db "$pg" pre-quadlet || die "backup failed - nothing was changed"
  count_before="$(db_count "$pg")"
  log "CVEs in database before: $count_before"

  for u in $(systemctl --user list-units --all --plain --no-legend 'nvd-*' 2>/dev/null | awk '{print $1}'); do
    log "stopping $u (resumable via deploy/ot-run.sh, see README)"
    systemctl --user stop "$u" || true
  done
  systemctl --user disable --now openthreat-deploy.timer openthreat.service 2>/dev/null || true
  rm -f "$UNIT_DIR/openthreat.service"

  log "removing compose containers (volumes stay)"
  REMOVED_COMPOSE=1
  podman stop -t 90 $(podman ps -q --filter "label=$COMPOSE_LABEL") >/dev/null 2>&1 || true
  # --depend: podman-compose links containers (depends_on) - order matters
  podman rm -f --depend $(podman ps -a -q --filter "label=$COMPOSE_LABEL") >/dev/null
  podman volume exists openthreat_postgres_data || die "volume openthreat_postgres_data vanished?!"
elif podman volume exists openthreat_postgres_data; then
  log "reusing existing volume openthreat_postgres_data"
fi

# ------------------------------------------------------------- install
log "images sha-${target:0:12}"
tag_current "sha-$target"
log "units -> $QUADLET_DIR, $UNIT_DIR"
render_units >/dev/null
systemctl --user enable openthreat.target >/dev/null
ensure_socket restart

log "starting postgres + redis"
systemctl --user start openthreat-postgres.service openthreat-redis.service
migrate_db
log "starting the stack"
systemctl --user start --no-block openthreat.target
health_check 600

count_after="$(db_count openthreat-postgres)"
log "CVEs in database now: $count_after${count_before:+ (before: $count_before)}"
if [ -n "$count_before" ] && [ "$count_after" != "$count_before" ]; then
  warn "CVE count changed during migration - check before deleting the backup ($LAST_BACKUP)"
fi

state_set deployed "$target"
systemctl --user enable --now openthreat-deploy.timer
systemctl --user enable --now podman-auto-update.timer 2>/dev/null \
  || warn "podman-auto-update.timer not available - base images (postgres/redis/nginx) won't auto-update"

cat <<EOF

OpenThreat runs as systemd units now (deployed ${target:0:12}).
  status        deploy/deploy.sh --status
  deploy log    journalctl --user -u openthreat-deploy.service -f
  stack         systemctl --user status 'openthreat-*'
  backups       $BACKUP_DIR${LAST_BACKUP:+  (pre-migration: $(basename "$LAST_BACKUP"))}

podman-compose is no longer used on this host.
EOF
