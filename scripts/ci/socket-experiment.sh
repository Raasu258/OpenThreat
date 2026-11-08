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
# Experiment 3: which top-level directive breaks it?
mk() { # name port-base sed-expr
  local n="$1" b="$2"; shift 2
  sed "$@" "$C/nginx.conf" > "$C/nginx-$n.conf"
  run_variant "$n" "$b"1 "$b"2 socket
  sed -i "s#$C/nginx.conf:#$C/nginx-$n.conf:#" "$Q/exp-$n.container"
}
mk asis     1830 -e 's#^error_log .*#error_log stderr info;#'
mk w1       1831 -e 's#^worker_processes auto;#worker_processes 1;#'
mk nomulti  1832 -e '/multi_accept on;/d'
mk noepoll  1833 -e '/use epoll;/d'
mk mutex    1834 -e 's#multi_accept on;#multi_accept on; accept_mutex on;#'
mk nouser   1835 -e '/^user nginx;/d'
mk w1mutex  1836 -e 's#^worker_processes auto;#worker_processes 2;#' -e 's#multi_accept on;#multi_accept on; accept_mutex on;#'
# hypothesis: systemd sockets are blocking; nginx + multi_accept blocks in accept()
mk nonblock 1837 -e 's#^error_log .*#error_log stderr info;#'
sed -i 's#^\[Socket\]#[Socket]\nNonBlocking=yes#' "$U/exp-nonblock.socket"
cat "$U/exp-nonblock.socket"
systemctl --user daemon-reload
for n in asis w1 nomulti noepoll mutex nouser w1mutex nonblock; do systemctl --user start "exp-$n.socket"; done
sleep 3
for v in "asis 1830" "w1 1831" "nomulti 1832" "noepoll 1833" "mutex 1834" "nouser 1835" "w1mutex 1836" "nonblock 1837"; do
  set -- $v
  for _ in 1 2 3; do curl -sk -m 3 -o /dev/null "https://127.0.0.1:${2}2/" || true; done
  echo "--- $1: http=$(curl -s -m 6 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${2}1/x") https=$(curl -sk -m 6 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${2}2/health")"
done
echo "===== asis log"
journalctl --user -u exp-asis.service --no-pager -n 30 | grep -v "docker-entrypoint\|podman\[" | cut -c40-260
echo "===== inside asis"
podman exec exp-asis sh -c 'ls -l /proc/1/fd; cat /etc/nginx/nginx.conf | grep -n listen; ps' 2>&1 | head -30
