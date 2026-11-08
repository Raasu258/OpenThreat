#!/usr/bin/env bash
# Experiment 2: our real nginx.conf (as in #35) with socket activation.
set -uo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
Q="$HOME/.config/containers/systemd"; U="$HOME/.config/systemd/user"; C="$HOME/exp"
mkdir -p "$Q" "$U" "$C/ssl"
podman pull -q docker.io/library/nginx:alpine >/dev/null
podman network create --subnet 10.91.99.0/24 expnet >/dev/null
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=x -keyout "$C/ssl/nginx.key" -out "$C/ssl/nginx.crt" 2>/dev/null
cp "$SRC/scripts/ci/exp-nginx.conf.template" "$C/nginx.conf"

# dummy backend + frontend (answer 200 on 8001 and 3000)
cat > "$C/dummy.conf" <<'EOF'
events {}
http { server { listen 8001; listen 3000; location / { return 200 "dummy $remote_addr xff=$http_x_forwarded_for xri=$http_x_real_ip\n"; } } }
EOF
podman run -d --name dummy --network expnet --ip 10.91.99.20 --network-alias backend --network-alias frontend \
  -v "$C/dummy.conf:/etc/nginx/nginx.conf:ro" docker.io/library/nginx:alpine >/dev/null

run_variant() { # name http-port https-port mode(socket|publish) extra-lines...
  local n="$1" hp="$2" sp="$3" mode="$4"; shift 4
  { printf '[Unit]\n'
    [ "$mode" = socket ] && printf 'Requires=exp-%s.socket\nAfter=exp-%s.socket\n' "$n" "$n"
    printf '[Container]\nImage=docker.io/library/nginx:alpine\nContainerName=exp-%s\nNetwork=expnet\n' "$n"
    printf 'Volume=%s/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro\nVolume=%s/ssl:/etc/nginx/ssl:ro\n' "$C" "$C"
    printf 'Environment=NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx NGINX_ENVSUBST_FILTER=^NGINX_PUBLIC_ NGINX_PUBLIC_HTTPS_PORT=%s\n' "$sp"
    if [ "$mode" = socket ]; then
      printf 'Environment=NGINX=3;4;\nEnvironment=NGINX_PUBLIC_HTTP_LISTEN=0.0.0.0:%s NGINX_PUBLIC_HTTPS_LISTEN=0.0.0.0:%s\n' "$hp" "$sp"
    else
      printf 'Environment=NGINX_PUBLIC_HTTP_LISTEN=80 NGINX_PUBLIC_HTTPS_LISTEN=443\nPublishPort=%s:80\nPublishPort=%s:443\n' "$hp" "$sp"
    fi
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$Q/exp-$n.container"
  [ "$mode" = socket ] && printf '[Socket]\nListenStream=0.0.0.0:%s\nListenStream=0.0.0.0:%s\n' "$hp" "$sp" > "$U/exp-$n.socket"
}
run_variant publish 18201 18202 publish
run_variant socket  18211 18212 socket
# same, but error log at info to see where the master stops
run_variant socketdbg 18221 18222 socket
sed 's#^error_log .*#error_log stderr info;#' "$C/nginx.conf" > "$C/nginx-dbg.conf"
sed -i "s#$C/nginx.conf:#$C/nginx-dbg.conf:#" "$Q/exp-socketdbg.container"

systemctl --user daemon-reload
systemctl --user start exp-publish.service exp-socket.socket exp-socketdbg.socket
sleep 3
try() { echo "--- $1: $(curl -sk -m 8 -o /dev/stdout -w ' [%{http_code}]' "$2" 2>&1 | tr '\n' ' ' || echo "FAILED rc=$?")"; }
for v in "publish 18201 18202" "socket 18211 18212" "socketdbg 18221 18222"; do
  set -- $v
  try "$1 http"         "http://127.0.0.1:$2/x"
  try "$1 https /health" "https://127.0.0.1:$3/health"
  try "$1 https /"       "https://127.0.0.1:$3/"
done
sleep 2
for n in socket socketdbg; do
  echo "===== $n"
  systemctl --user status "exp-$n.service" --no-pager -n 0 | sed -n 1,4p
  journalctl --user -u "exp-$n.service" --no-pager -n 40 | grep -v "docker-entrypoint\|podman\[" | cut -c40-260
done
echo "===== inside socketdbg"
podman exec exp-socketdbg sh -c 'ls -l /proc/1/fd; cat /etc/nginx/nginx.conf | grep -n listen; ps' 2>&1 | head -30
