#!/usr/bin/env bash
# End-to-end test of the VPS deployment (deploy/*) on a CI runner with
# rootless Podman and a real systemd --user manager.
#
#   1. a podman-compose-style stack with data  -> deploy/install.sh migrates it;
#      the data must survive
#   2. new commit                               -> deploy.sh deploys it
#   3. new commit with a broken backend image   -> deploy fails, rolls back, data intact
#   4. backend container killed                 -> systemd restarts it, nginx still proxies
#   5. whole stack restarted (reboot)           -> comes back
#
# Env: SRC_BACKEND_IMAGE, SRC_FRONTEND_IMAGE  images (in Docker) built by CI
set -Eeuo pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
: "${SRC_BACKEND_IMAGE:?}" "${SRC_FRONTEND_IMAGE:?}"
REG=localhost:5000/ot
HTTPS_PORT=18443
B="https://127.0.0.1:$HTTPS_PORT"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
STATE="$HOME/.local/state/openthreat"

pass=0
ok()   { pass=$((pass + 1)); echo "PASS  $*"; }
fail() { echo "FAIL  $*"; exit 1; }
expect() { # name, want, got
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$3', want '$2')"; fi
}
code() { curl -sk -m 10 -o /dev/null -w '%{http_code}' "$@" || true; }
cves() { curl -sk -m 10 "$B/api/v1/vulnerabilities?page_size=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])' 2>/dev/null || echo "?"; }
db_cves() { podman exec openthreat-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from vulnerabilities"'; }
wait_for() { # seconds, command...
  local end=$(( $(date +%s) + $1 )); shift
  until "$@"; do [ "$(date +%s)" -lt "$end" ] || return 1; sleep 3; done
}
api_up() { [ "$(code "$B/health")" = 200 ] && [ "$(code "$B/")" = 200 ]; }

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--- units";  systemctl --user list-units 'openthreat*' --all --no-pager || true
    echo "--- containers"; podman ps -a || true
    for u in postgres redis backend frontend worker beat nginx; do
      echo "--- journal openthreat-$u"
      journalctl --user -u "openthreat-$u.service" -n 40 --no-pager 2>/dev/null || true
    done
    echo "--- deploy state"; tail -n +1 "$STATE"/deployed "$STATE"/previous "$STATE"/failed 2>/dev/null || true
  fi
  echo "== $pass checks passed"
}
trap on_exit EXIT

# Re-published as OCI images, like GHCR gets them from CI (provenance/SBOM):
# Podman ignores a Dockerfile HEALTHCHECK in OCI images, so the units must
# define their own - a Docker-format image here would hide that.
push_images() { # tag backend-src frontend-src
  local svc src
  for svc in backend frontend; do
    if [ "$svc" = backend ]; then src="$2"; else src="$3"; fi
    docker tag "$src" "$REG/openthreat-$svc:$1-docker"
    docker push -q "$REG/openthreat-$svc:$1-docker" >/dev/null
    podman pull -q "$REG/openthreat-$svc:$1-docker" >/dev/null
    podman push -q --format oci "$REG/openthreat-$svc:$1-docker" "$REG/openthreat-$svc:$1"
    podman rmi -f "$REG/openthreat-$svc:$1-docker" >/dev/null
  done
}

echo "== environment"
podman --version
systemctl --user is-system-running || true
docker run -d --rm --name registry -p 5000:5000 docker.io/library/registry:2 >/dev/null
mkdir -p "$HOME/.config/containers"
cat > "$HOME/.config/containers/registries.conf" <<'EOF'
[[registry]]
location = "localhost:5000"
insecure = true
EOF

echo "== app checkout with a local origin"
W="$(mktemp -d)"
git init -q --bare "$W/origin.git"
mkdir "$W/app"; git -C "$SRC" archive HEAD | tar -x -C "$W/app"
cd "$W/app"
# Commit A = the layout before socket activation (nginx publishes the ports
# itself), like the first Quadlet installs. Commit B switches to the socket.
rm deploy/systemd/openthreat-nginx.socket
sed -i -e '/openthreat-nginx.socket/d' -e '/^Environment=NGINX=3;4;$/d' \
  -e 's#^Environment=NGINX_PUBLIC_HTTP_LISTEN=.*#Environment=NGINX_PUBLIC_HTTP_LISTEN=80 NGINX_PUBLIC_HTTPS_LISTEN=443\nPublishPort=@HTTP_PORT@:80\nPublishPort=@HTTPS_PORT@:443#' \
  deploy/quadlet/openthreat-nginx.container
grep -q '^PublishPort=@HTTPS_PORT@:443' deploy/quadlet/openthreat-nginx.container || { echo "legacy rewrite failed"; exit 1; }
git init -q -b main; git add -A
git -c user.name=ci -c user.email=ci@localhost commit -qm A
git remote add origin "$W/origin.git"; git push -q origin main
A="$(git rev-parse HEAD)"
push_images "sha-$A" "$SRC_BACKEND_IMAGE" "$SRC_FRONTEND_IMAGE"

mkdir -p nginx/ssl
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=localhost \
  -keyout nginx/ssl/nginx.key -out nginx/ssl/nginx.crt 2>/dev/null
PGPW="$(openssl rand -hex 16)"
cat > .env <<EOF
OT_REGISTRY=$REG
NGINX_HTTP_PORT=18082
NGINX_HTTPS_PORT=$HTTPS_PORT
POSTGRES_DB=openthreat
POSTGRES_USER=openthreat
POSTGRES_PASSWORD=$PGPW
SECRET_KEY=$(openssl rand -hex 32)
CSRF_SECRET_KEY=$(openssl rand -hex 32)
ENVIRONMENT=production
DEPLOY_BACKUP_DIR=$W/backups
DEPLOY_HEALTH_TIMEOUT=150
EOF

echo "== 1. podman-compose style stack with data"
podman network create ot_compose >/dev/null
L=(--label io.podman.compose.project=openthreat)
podman run -d --name openthreat_postgres_1 "${L[@]}" --label com.docker.compose.service=postgres \
  --network ot_compose --network-alias postgres \
  -e POSTGRES_DB=openthreat -e POSTGRES_USER=openthreat -e POSTGRES_PASSWORD="$PGPW" \
  -v openthreat_postgres_data:/var/lib/postgresql/data docker.io/library/postgres:16-alpine >/dev/null
podman run -d --name openthreat_redis_1 "${L[@]}" --label com.docker.compose.service=redis \
  --network ot_compose docker.io/library/redis:7-alpine >/dev/null
# podman-compose turns depends_on into --requires: removal order matters
podman run -d --name openthreat_backend_1 "${L[@]}" --label com.docker.compose.service=backend \
  --requires openthreat_postgres_1,openthreat_redis_1 --network ot_compose \
  docker.io/library/redis:7-alpine >/dev/null
wait_for 60 podman exec openthreat_postgres_1 pg_isready -U openthreat -h 127.0.0.1 >/dev/null
podman pull -q "$REG/openthreat-backend:sha-$A" >/dev/null
APPENV=(-e "DATABASE_URL=postgresql://openthreat:$PGPW@postgres:5432/openthreat" -e REDIS_URL=redis://x:6379 -e "SECRET_KEY=$(openssl rand -hex 32)")
podman run --rm --network ot_compose "${APPENV[@]}" "$REG/openthreat-backend:sha-$A" alembic upgrade head >/dev/null
podman run --rm --network ot_compose "${APPENV[@]}" "$REG/openthreat-backend:sha-$A" python -m backend.migrations.run_migrations >/dev/null
podman exec -i openthreat_postgres_1 psql -q -U openthreat openthreat -v ON_ERROR_STOP=1 < "$SRC/scripts/ci/seed_filter_data.sql"
before="$(podman exec openthreat_postgres_1 psql -U openthreat -d openthreat -tAc 'select count(*) from vulnerabilities')"
expect "seeded data present" 8 "$before"

echo "== deploy.sh refuses to run next to the compose stack"
if deploy/deploy.sh >/dev/null 2>&1; then fail "deploy.sh ran with compose containers present"; else ok "deploy.sh refuses before install"; fi

echo "== install.sh (migration)"
deploy/install.sh
expect "compose containers removed" "" "$(podman ps -a -q --filter label=io.podman.compose.project=openthreat)"
expect "data survived migration (db)" "$before" "$(db_cves)"
expect "data survived migration (API)" "$before" "$(cves)"
expect "deployed = A" "$A" "$(cat "$STATE/deployed")"
expect "pre-migration backup kept" 1 "$(find "$W/backups" -name '*pre-quadlet.dump' | wc -l)"
expect "deploy timer enabled" enabled "$(systemctl --user is-enabled openthreat-deploy.timer)"
expect "stack target enabled" enabled "$(systemctl --user is-enabled openthreat.target)"
expect "postgres not published" "" "$(podman port openthreat-postgres)"
health() { podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo missing; }
for c in openthreat-postgres openthreat-redis openthreat-backend openthreat-frontend; do
  wait_for 120 sh -c "[ \"\$(podman inspect --format '{{.State.Health.Status}}' $c 2>/dev/null)\" = healthy ]" || true
  expect "$c reports healthy" healthy "$(health "$c")"
done
expect "all units active (not stuck activating)" "" \
  "$(for u in postgres redis backend frontend worker beat nginx; do systemctl --user is-active --quiet "openthreat-$u.service" || echo "$u"; done)"

echo "== nothing new -> no-op"
deploy/deploy.sh
expect "still A" "$A" "$(cat "$STATE/deployed")"

curl -sk -o /dev/null "$B/health?from-test-A"
echo "client address nginx logs with published ports: $(podman logs --tail 50 openthreat-nginx 2>&1 | awk '/from-test-A/ {print $1}' | tail -n1)"

echo "== 2. new commit B (socket activation), CI not done yet -> waits"
git -C "$SRC" archive HEAD | tar -x -C .        # restore the real files
git add -A
git -c user.name=ci -c user.email=ci@localhost commit -q -m B; git push -q origin main
Bc="$(git rev-parse HEAD)"; git reset -q --hard "$A"     # VPS checkout is still at A
deploy/deploy.sh
expect "waits for images" "$A" "$(cat "$STATE/deployed")"
push_images "sha-$Bc" "$SRC_BACKEND_IMAGE" "$SRC_FRONTEND_IMAGE"
# a unit that is no longer in the repo still holds a port (happened on the VPS)
printf '[Socket]\nListenStream=0.0.0.0:18099\n' > "$HOME/.config/systemd/user/openthreat-stale.socket"
printf '[Service]\nExecStart=/bin/sleep infinity\n' > "$HOME/.config/systemd/user/openthreat-stale.service"
systemctl --user daemon-reload; systemctl --user start openthreat-stale.socket
expect "stale socket holds its port" 1 "$(ss -Hltn 'sport = :18099' | wc -l)"
deploy/deploy.sh
expect "deployed = B" "$Bc" "$(cat "$STATE/deployed")"
expect "previous = A" "$A" "$(cat "$STATE/previous")"
expect "checkout = B" "$Bc" "$(git rev-parse HEAD)"
expect "data after deploy" "$before" "$(cves)"
expect "stale units removed" 0 "$(ls "$HOME"/.config/systemd/user/openthreat-stale.* 2>/dev/null | wc -l)"
expect "its port released" 0 "$(ss -Hltn 'sport = :18099' | wc -l)"
expect "backup before deploy" 1 "$(find "$W/backups" -name "*-${Bc:0:12}.dump" | wc -l)"
expect "public ports held by systemd socket" active "$(systemctl --user is-active openthreat-nginx.socket)"
curl -sk -o /dev/null "$B/health?from-test-B"
sleep 1
expect "nginx logs the real client address" 127.0.0.1 \
  "$(podman logs --tail 50 openthreat-nginx 2>&1 | awk '/from-test-B/ {print $1}' | tail -n1)"
expect "backend sees the client address (X-Real-IP)" 1 \
  "$(podman logs --tail 50 openthreat-backend 2>&1 | grep -c '127.0.0.1:[0-9]* - "GET /health?from-test-B' || true)"
expect "HTTP redirect keeps the public port" "https://127.0.0.1:$HTTPS_PORT/news" \
  "$(curl -s -o /dev/null -w '%{redirect_url}' "http://127.0.0.1:18082/news")"

echo "== 3. commit C with a broken backend -> rollback"
git -c user.name=ci -c user.email=ci@localhost commit -q --allow-empty -m C; git push -q origin main
C="$(git rev-parse HEAD)"; git reset -q --hard "$Bc"
printf 'FROM %s\nCMD ["sh", "-c", "echo broken on purpose; exit 1"]\n' "$SRC_BACKEND_IMAGE" \
  | docker build -q -t broken-backend - >/dev/null
push_images "sha-$C" broken-backend "$SRC_FRONTEND_IMAGE"
if deploy/deploy.sh; then fail "broken deploy reported success"; else ok "broken deploy fails"; fi
expect "rolled back to B" "$Bc" "$(cat "$STATE/deployed")"
expect "C marked failed" "$C" "$(cat "$STATE/failed")"
expect "checkout back at B" "$Bc" "$(git rev-parse HEAD)"
wait_for 60 api_up && ok "site up after rollback" || fail "site down after rollback"
expect "data after rollback" "$before" "$(cves)"
deploy/deploy.sh
expect "failed commit skipped" "$Bc" "$(cat "$STATE/deployed")"

echo "== 4. backend killed -> restarted, nginx still proxies"
old_id="$(podman inspect --format '{{.Id}}' openthreat-backend)"
podman kill openthreat-backend >/dev/null
sleep 3
wait_for 150 api_up && ok "API back after kill" || fail "API not back after kill"
expect "backend recreated" 1 "$([ "$(podman inspect --format '{{.Id}}' openthreat-backend)" != "$old_id" ] && echo 1)"
expect "API data via nginx" "$before" "$(cves)"

echo "== nginx restart: the port stays open (socket held by systemd)"
systemctl --user restart --no-block openthreat-nginx.service
expect "request during nginx restart" 200 "$(curl -sk -m 60 -o /dev/null -w '%{http_code}' "$B/health")"

echo "== 5. whole stack restarted (like a reboot)"
systemctl --user stop openthreat.target     # waits: units are ordered after the target
expect "everything stopped when stop returns" "" "$(podman ps -q --filter name=openthreat-)"
systemctl --user start openthreat.target
wait_for 240 api_up && ok "stack back after restart" || fail "stack not back after restart"
expect "data after restart" "$before" "$(cves)"
deploy/deploy.sh --status
