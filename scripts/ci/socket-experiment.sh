#!/usr/bin/env bash
# Experiment: which part of nginx socket activation hangs?
set -uo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
Q="$HOME/.config/containers/systemd"; U="$HOME/.config/systemd/user"; C="$HOME/exp"
mkdir -p "$Q" "$U" "$C"
podman pull -q docker.io/library/nginx:alpine >/dev/null
podman network create --subnet 10.91.99.0/24 expnet >/dev/null

conf() { # name, listen-http, [listen-https]
  cat > "$C/$1.conf" <<EOF
events {}
error_log stderr info;
http {
  access_log /dev/stdout;
  server { listen $2; return 200 "ok $1 from \$remote_addr\n"; }
EOF
  if [ -n "${3:-}" ]; then cat >> "$C/$1.conf" <<EOF
  server { listen $3 ssl; ssl_certificate /c/t.crt; ssl_certificate_key /c/t.key; return 200 "ok-tls $1 from \$remote_addr\n"; }
EOF
  fi
  echo "}" >> "$C/$1.conf"
}
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=x -keyout "$C/t.key" -out "$C/t.crt" 2>/dev/null

variant() { # name port1 [port2] -- extra [Container] lines...
  local n="$1" p1="$2" p2="$3"; shift 3
  printf '[Socket]\nListenStream=0.0.0.0:%s\n' "$p1" > "$U/exp-$n.socket"
  [ -n "$p2" ] && printf 'ListenStream=0.0.0.0:%s\n' "$p2" >> "$U/exp-$n.socket"
  { printf '[Unit]\nRequires=exp-%s.socket\nAfter=exp-%s.socket\n[Container]\nImage=docker.io/library/nginx:alpine\nContainerName=exp-%s\n' "$n" "$n" "$n"
    printf 'Volume=%s/%s.conf:/etc/nginx/nginx.conf:ro\nVolume=%s:/c:ro\n' "$C" "$n" "$C"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$Q/exp-$n.container"
}

conf none   0.0.0.0:18101
conf bridge 0.0.0.0:18102
conf both   0.0.0.0:18103 0.0.0.0:18104
conf tpl    0.0.0.0:18105
variant none   18101 "" 'Network=none' 'Environment=NGINX=3;'
variant bridge 18102 "" 'Network=expnet' 'Environment=NGINX=3;'
variant both   18103 18104 'Network=expnet' 'IP=10.91.99.30' 'Environment=NGINX=3;4;'
# exactly like ours: entrypoint renders a template, env from Environment=
variant tpl    18105 "" 'Network=expnet' 'Environment=NGINX=3;' 'Environment=NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx NGINX_ENVSUBST_FILTER=^NGINX_PUBLIC_'
sed -i "s#Volume=$C/tpl.conf:/etc/nginx/nginx.conf:ro#Volume=$C/tpl.conf:/etc/nginx/templates/nginx.conf.template:ro#" "$Q/exp-tpl.container"

systemctl --user daemon-reload
for n in none bridge both tpl; do systemctl --user start "exp-$n.socket"; done
sleep 2
try() { echo "--- $1: $(curl -sk -m 5 "$2" 2>&1 || echo "FAILED rc=$?")"; }
try none   http://127.0.0.1:18101/
try bridge http://127.0.0.1:18102/
try both-http  http://127.0.0.1:18103/
try both-https https://127.0.0.1:18104/
try tpl    http://127.0.0.1:18105/
sleep 2
for n in none bridge both tpl; do
  echo "===== $n: unit + log"
  systemctl --user status "exp-$n.service" --no-pager -n 0 | head -4
  journalctl --user -u "exp-$n.service" --no-pager -n 25 | cut -c1-220
done
echo "===== generated ExecStart (both)"
/usr/libexec/podman/quadlet -dryrun -user 2>/dev/null | sed -n '/---exp-both.service---/,/^---/p' | grep ExecStart
