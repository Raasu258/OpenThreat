#!/usr/bin/env bash
# Full-stack test: runs the real docker-compose.yml with freshly built
# images (nginx, frontend, backend, celery worker + beat, postgres, redis)
# and checks the deployed behaviour through nginx, the way users see it.
#
# Env:
#   OT_REGISTRY, OT_IMAGE_TAG   locally available images to test
#   COMPOSE                     default "docker compose"
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")/../.."

: "${OT_REGISTRY:?set OT_REGISTRY}" "${OT_IMAGE_TAG:?set OT_IMAGE_TAG}"
COMPOSE="${COMPOSE:-docker compose}"
HTTP_PORT=8082
HTTPS_PORT=8443
B="https://localhost:$HTTPS_PORT"

mkdir -p nginx/ssl
if [ ! -f nginx/ssl/nginx.crt ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=localhost \
    -keyout nginx/ssl/nginx.key -out nginx/ssl/nginx.crt 2>/dev/null
fi

cat > .env <<EOF
OT_REGISTRY=$OT_REGISTRY
OT_IMAGE_TAG=$OT_IMAGE_TAG
NGINX_HTTP_PORT=$HTTP_PORT
NGINX_HTTPS_PORT=$HTTPS_PORT
POSTGRES_DB=openthreat
POSTGRES_USER=openthreat
POSTGRES_PASSWORD=$(openssl rand -hex 16)
SECRET_KEY=$(openssl rand -hex 32)
CSRF_SECRET_KEY=$(openssl rand -hex 32)
ENVIRONMENT=production
EOF

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--- containers"; $COMPOSE ps -a || true
    echo "--- logs";       $COMPOSE logs --no-color --tail 60 || true
  fi
  $COMPOSE down -v >/dev/null 2>&1 || true
}
trap on_exit EXIT

echo "== starting postgres + redis"
$COMPOSE up -d --wait postgres redis
echo "== migrations"
$COMPOSE run --rm backend alembic upgrade head
$COMPOSE run --rm backend python -m backend.migrations.run_migrations
echo "== starting stack"
$COMPOSE up -d

for _ in $(seq 1 60); do
  [ "$(curl -sk -o /dev/null -w '%{http_code}' "$B/health")" = 200 ] && break
  sleep 2
done

pass=0; fail=0
check() { # name, expected-regex, actual
  if [[ "$3" =~ ^($2)$ ]]; then echo "PASS  $1 ($3)"; pass=$((pass+1));
  else echo "FAIL  $1 (got '$3', want $2)"; fail=$((fail+1)); fi
}
code() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }

check "GET /health"                       200 "$(code "$B/health")"
check "GET / (frontend via nginx)"        200 "$(code "$B/")"
check "GET /news"                         200 "$(code "$B/news")"
check "GET /my-stack"                     200 "$(code "$B/my-stack")"
check "GET /site-stats"                   200 "$(code "$B/site-stats")"
check "GET /vulnerabilities/<missing>"    "200|404" "$(code "$B/vulnerabilities/CVE-0000-00000")"
check "GET /api/v1/vulnerabilities"       200 "$(code "$B/api/v1/vulnerabilities?page_size=1")"
check "GET /api/v1/stats"                 200 "$(code "$B/api/v1/stats")"
check "GET /api/v1/analytics/stats"       200 "$(code "$B/api/v1/analytics/stats?days=7")"
check "GET /metrics blocked"              403 "$(code "$B/metrics")"
check "GET tasks/workers/status anon"     "401|403" "$(code "$B/api/v1/tasks/workers/status")"

asset="$(curl -sk "$B/" | grep -o '/_next/static/[^"]*\.js' | head -n1)"
check "static asset served"               200 "$(code "$B${asset:-/_next/static/missing.js}")"

hdrs="$(curl -sk -D - -o /dev/null "$B/")"
check "CSP header present"                1 "$(grep -ci '^content-security-policy:' <<<"$hdrs")"

loc="$(curl -s -o /dev/null -w '%{redirect_url}' "http://localhost:$HTTP_PORT/news?x=1")"
check "HTTP redirect keeps HTTPS port"    "https://localhost:$HTTPS_PORT/news\?x=1" "$loc"

# client bundles must not carry a hard-coded API host (same-origin /api/...)
hardcoded=0
for page in / /news /my-stack /site-stats; do
  for js in $(curl -sk "$B$page" | grep -o '/_next/static/[^"]*\.js' | sort -u); do
    if curl -sk "$B$js" | grep -qE '127\.0\.0\.1:8001|localhost:8000|open-threats\.'; then
      echo "      hard-coded host in $js"; hardcoded=$((hardcoded+1))
    fi
  done
done
check "no hard-coded API host in bundle"  0 "$hardcoded"

pong=0
for _ in $(seq 1 30); do
  if $COMPOSE exec -T celery-worker celery -A backend.celery_app inspect ping 2>/dev/null | grep -q pong; then
    pong=1; break
  fi
  sleep 3
done
check "celery worker answers ping"        1 "$pong"
check "celery beat running"               1 "$($COMPOSE ps --status running --services | grep -cx celery-beat || true)"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
