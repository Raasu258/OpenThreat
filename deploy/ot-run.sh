#!/usr/bin/env bash
# Run a one-off command with the deployed backend image on the stack network.
#
#   deploy/ot-run.sh [podman run args] -- command...
#
# Examples:
#   deploy/ot-run.sh -it -- python                  # Python shell with app settings
#   deploy/ot-run.sh -- alembic current
#   # full NVD import, resumable (checkpoint in a volume), as a background unit:
#   systemd-run --user --unit=nvd-full-import --collect \
#     "$PWD/deploy/ot-run.sh" -v openthreat_nvd_state:/state -- \
#     python scripts/fetch_nvd_complete.py --checkpoint-file /state/nvd_checkpoint.txt
#   journalctl --user -u nvd-full-import -f
#
# Database shell:  podman exec -it openthreat-postgres sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"'
set -Eeuo pipefail
# shellcheck source=deploy/lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -f "$OT_STATE/app.env" ] || die "not installed yet - run deploy/install.sh"
case " $* " in *" -- "*) ;; *) set -- -- "$@" ;; esac
run_app "$@"
