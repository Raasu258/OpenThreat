#!/usr/bin/env bash
# Integration smoke test against a real Postgres + Redis.
#
# Runs Alembic + SQL migrations on a fresh schema, starts the API and
# exercises health, listing/search, auth (register/login/JWT), admin
# RBAC, the multipart upload path, the endpoint lock-downs and the
# Celery broker connection. Exits non-zero if any check fails.
#
# Env:
#   PG_URL     postgres URL with rights to drop/create the public schema
#              (default postgresql://postgres:postgres@localhost:5432/openthreat)
#   REDIS_URL  default redis://localhost:6379
#   PORT       API port for the test server (default 18001)
set -u

PG_URL="${PG_URL:-postgresql://postgres:postgres@localhost:5432/openthreat}"
export REDIS_URL="${REDIS_URL:-redis://localhost:6379}"
PORT="${PORT:-18001}"
LOG_DIR="${LOG_DIR:-$(mktemp -d)}"

export DATABASE_URL="$PG_URL"
export SECRET_KEY="ci-smoke-secret-0123456789abcdef0123456789abcdef"
export CSRF_SECRET_KEY="ci-smoke-csrf-0123456789abcdef0123456789"
export ENVIRONMENT=production
export ALLOWED_ORIGINS=https://example.test

psql -q "$PG_URL" -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;" 2>/dev/null
psql -q "$PG_URL" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS btree_gin;"

pass=0; fail=0
check() { # name, expected-status-regex, actual
  if [[ "$3" =~ ^($2)$ ]]; then echo "PASS  $1 ($3)"; pass=$((pass+1));
  else echo "FAIL  $1 (got '$3', want $2)"; fail=$((fail+1)); fi
}

alembic upgrade head >"$LOG_DIR/alembic.log" 2>&1
check "alembic upgrade head" 0 $?
python -m backend.migrations.run_migrations >"$LOG_DIR/sqlmig.log" 2>&1
check "sql migrations" 0 $?
python -m backend.migrations.run_migrations >"$LOG_DIR/sqlmig2.log" 2>&1
check "sql migrations idempotent" 0 $?

uvicorn backend.main:app --port "$PORT" >"$LOG_DIR/uvicorn.log" 2>&1 &
UV=$!
trap 'kill $UV 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "localhost:$PORT/health" && break; sleep 1; done

B="http://localhost:$PORT"
BODY="$LOG_DIR/body"
c() { curl -s -o "$BODY" -w '%{http_code}' "$@"; }

check "GET /health"                   200 "$(c "$B/health")"
check "GET /api/v1/vulnerabilities"    200 "$(c "$B/api/v1/vulnerabilities?page_size=5")"
check "GET /api/v1/stats"              200 "$(c "$B/api/v1/stats")"
check "GET /api/v1/search"             200 "$(c "$B/api/v1/search?q=openssl")"
check "GET /api/v1/csrf-token"         200 "$(c "$B/api/v1/csrf-token")"
check "POST /api/v1/analytics/track"   "200|201|204" "$(c -X POST -H 'Content-Type: application/json' -d '{"path":"/","referrer":""}' "$B/api/v1/analytics/track")"
check "GET analytics/stats"            200 "$(c "$B/api/v1/analytics/stats?days=30")"
check "GET analytics/stats days>365"   422 "$(c "$B/api/v1/analytics/stats?days=100000")"
check "GET tasks/workers/status anon"  "401|403" "$(c "$B/api/v1/tasks/workers/status")"
check "GET tasks/{id} anon"            "401|403" "$(c "$B/api/v1/tasks/abc")"

code=$(c -X POST -H 'Content-Type: application/json' \
  -d '{"email":"smoke.test@mailbox.org","username":"smoke","password":"Sm0keTest!pw"}' "$B/api/v1/auth/register")
check "POST register" 201 "$code"; [ "$code" = 201 ] || echo "      body: $(head -c 300 "$BODY")"
check "POST login" 200 "$(c -X POST -H 'Content-Type: application/json' -d '{"username":"smoke","password":"Sm0keTest!pw"}' "$B/api/v1/auth/login")"
TOKEN=$(python -c "import json,sys;print(json.load(open(sys.argv[1])).get('access_token',''))" "$BODY" 2>/dev/null)
check "GET /auth/me"                   200 "$(c -H "Authorization: Bearer $TOKEN" "$B/api/v1/auth/me")"
check "GET /auth/me tampered token"    401 "$(c -H "Authorization: Bearer ${TOKEN%?}x" "$B/api/v1/auth/me")"
check "GET admin/stats as viewer"      403 "$(c -H "Authorization: Bearer $TOKEN" "$B/api/v1/admin/stats")"

psql -q "$PG_URL" -c "UPDATE users SET role='ADMIN' WHERE username='smoke';" >/dev/null 2>&1 || \
psql -q "$PG_URL" -c "UPDATE users SET role='admin' WHERE username='smoke';" >/dev/null 2>&1
check "GET admin/stats as admin"       200 "$(c -H "Authorization: Bearer $TOKEN" "$B/api/v1/admin/stats")"

printf 'requests==2.0.0\nflask==0.12\n' > "$LOG_DIR/requirements.txt"
check "POST techstack/scan (multipart)" 200 "$(c -X POST -F "file=@$LOG_DIR/requirements.txt;filename=requirements.txt" -F name=smoke "$B/api/v1/techstack/scan")"

kill $UV 2>/dev/null; wait $UV 2>/dev/null; trap - EXIT

timeout 25 celery -A backend.celery_app worker --loglevel=info --concurrency=1 -n smoke@%h >"$LOG_DIR/celery.log" 2>&1
check "celery worker connects" 1 "$(grep -c ' ready\.' "$LOG_DIR/celery.log")"

echo "== $pass passed, $fail failed (logs: $LOG_DIR)"
if [ "$fail" -gt 0 ]; then
  echo "--- uvicorn errors"; grep -iE "error|traceback" "$LOG_DIR/uvicorn.log" | head -20
  echo "--- sql migrations"; grep -E "✗" "$LOG_DIR/sqlmig.log" | head -10
  exit 1
fi
