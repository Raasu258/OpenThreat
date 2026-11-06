#!/usr/bin/env bash
# One-time setup of the pull-based deploy on the VPS.
# Run as the (unprivileged) user that owns the Podman stack, from the repo:
#   deploy/install.sh
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
cd "$REPO_DIR"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

[ "$(id -u)" -ne 0 ] || { echo "Run as the stack user, not root." >&2; exit 1; }
for bin in podman podman-compose git curl flock; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done

# .env sanity
[ -f .env ] || { echo ".env missing - start from .env.vps.example" >&2; exit 1; }
chmod 600 .env
for key in POSTGRES_PASSWORD SECRET_KEY CSRF_SECRET_KEY; do
  val="$(sed -n "s/^$key=//p" .env | tail -n1)"
  [ -n "$val" ] || warn "$key is empty in .env"
done
secret="$(sed -n 's/^SECRET_KEY=//p' .env | tail -n1)"
[ "${#secret}" -ge 32 ] || warn "SECRET_KEY is shorter than 32 chars - the backend will refuse to start"
grep -q '^OT_REGISTRY=' .env || warn "OT_REGISTRY not set in .env (default ghcr.io/raasu258)"

# Containers keep running without an active login session
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
  say "enabling linger for $USER"
  loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"
fi

say "installing systemd user units to $UNIT_DIR"
mkdir -p "$UNIT_DIR"
for unit in openthreat.service openthreat-deploy.service openthreat-deploy.timer; do
  sed "s|@REPO_DIR@|$REPO_DIR|g" "deploy/systemd/$unit" > "$UNIT_DIR/$unit"
done
systemctl --user daemon-reload
systemctl --user enable openthreat.service
systemctl --user enable --now openthreat-deploy.timer

if systemctl --user is-enabled podman-restart.service >/dev/null 2>&1; then
  warn "podman-restart.service is enabled too; openthreat.service now owns the stack."
  warn "Disable it to avoid double starts:  systemctl --user disable podman-restart.service"
fi

# Can we pull from GHCR?
registry="$(sed -n 's/^OT_REGISTRY=//p' .env | tail -n1)"; registry="${registry:-ghcr.io/raasu258}"
if podman pull -q "$registry/openthreat-backend:main" >/dev/null 2>&1; then
  say "GHCR pull works ($registry)"
else
  warn "could not pull $registry/openthreat-backend:main."
  warn "Either CI hasn't published yet, or the package is private:"
  warn "  make the packages public on GitHub, or: podman login ghcr.io  (PAT with read:packages only)"
fi

cat <<EOF

Done. The timer checks origin/main every 10 minutes.

  First deploy now:   $REPO_DIR/deploy/deploy.sh --force
  Status:             $REPO_DIR/deploy/deploy.sh --status
  Logs:               journalctl --user -u openthreat-deploy.service -f
  Timer:              systemctl --user list-timers openthreat-deploy.timer
EOF
