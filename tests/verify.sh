#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
RUNTIME="$ROOT/.runtime/nginx"

if [ -x "$ROOT/.venv/bin/ansible-playbook" ]; then
  AP="$ROOT/.venv/bin/ansible-playbook"
else
  AP=$(command -v ansible-playbook)
fi

export ANSIBLE_CONFIG="$ROOT/ansible.cfg"
export ANSIBLE_NOCOLOR=1

fail() {
  echo "FAIL  $1" >&2
  if [ "${2:-}" != "" ]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

pass() {
  echo "PASS  $1"
}

curl_code() {
  curl -sS --max-time 10 -o /tmp/nginx-playbook-body -w '%{http_code}' "$@"
}

if [ ! -f "$RUNTIME/docker-compose.yml" ]; then
  fail "stack is not deployed" "run make deploy first"
fi

python3 -m http.server 18080 --directory "$ROOT/tests/fixtures/backend" --bind 0.0.0.0 >/tmp/nginx-playbook-backend.log 2>&1 &
backend_pid=$!
cleanup() {
  kill "$backend_pid" 2>/dev/null || true
}
trap cleanup EXIT

i=0
while [ "$i" -lt 20 ]; do
  if curl -sf --max-time 2 http://127.0.0.1:18080/ping.txt >/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done
curl -sf --max-time 2 http://127.0.0.1:18080/ping.txt >/dev/null || fail "backend on :18080 did not start" "$(cat /tmp/nginx-playbook-backend.log)"

services=$(docker compose --project-directory "$RUNTIME" config --services | sort)
printf '%s\n' "$services" | grep -qx nginx || fail "compose has no nginx" "$services"
printf '%s\n' "$services" | grep -qx certbot || fail "compose has no certbot" "$services"
printf '%s\n' "$services" | grep -qx pebble || fail "local compose has no pebble" "$services"
pass "compose services"

running=$(docker compose --project-directory "$RUNTIME" ps --status running --format '{{.Service}}' | sort)
printf '%s\n' "$running" | grep -qx nginx || fail "nginx is not running" "$running"
printf '%s\n' "$running" | grep -qx certbot || fail "certbot is not running" "$running"
printf '%s\n' "$running" | grep -qx pebble || fail "pebble is not running" "$running"
pass "containers are up"

cmp -s "$ROOT/config/nginx.conf" "$RUNTIME/nginx/nginx.conf" || fail "deployed nginx.conf differs from config/nginx.conf"
pass "host nginx.conf"

grep -q 'include /etc/nginx/conf.d/\*\.conf;' "$RUNTIME/nginx/nginx.conf" || fail "nginx.conf does not include conf.d"
pass "conf.d include"

for domain in demo.test secure.test; do
  http_hist="$RUNTIME/nginx/history/$domain/01-http.conf"
  https_hist="$RUNTIME/nginx/history/$domain/02-https.conf"
  live="$RUNTIME/nginx/conf.d/$domain.conf"
  grep -q 'listen 80;' "$http_hist" || fail "$domain: missing saved HTTP vhost"
  grep -q 'acme-challenge' "$http_hist" || fail "$domain: HTTP vhost has no ACME location"
  if grep -q 'ssl_certificate' "$http_hist"; then
    fail "$domain: saved HTTP vhost already has TLS"
  fi
  if grep -q 'return 301' "$http_hist"; then
    fail "$domain: redirect was written before the certificate"
  fi
  grep -q 'ssl_certificate' "$https_hist" || fail "$domain: missing saved TLS vhost"
  grep -q 'ssl_certificate' "$live" || fail "$domain: live vhost has no certificate"
  grep -q 'return 301' "$live" || fail "$domain: no HTTP to HTTPS redirect"
  grep -q 'robots.txt' "$live" || fail "$domain: no robots.txt location"
  [ -f "$RUNTIME/certbot/conf/live/$domain/fullchain.pem" ] || fail "$domain: missing fullchain.pem"
  [ -f "$RUNTIME/certbot/conf/live/$domain/privkey.pem" ] || fail "$domain: missing privkey.pem"
  [ -L "$RUNTIME/certbot/conf/live/$domain/fullchain.pem" ] || fail "$domain: fullchain.pem is not a certbot symlink"
  grep -q 'server = https://pebble:14000/dir' "$RUNTIME/certbot/conf/renewal/$domain.conf" || fail "$domain: renewal server is not pebble"
  grep -q 'authenticator = webroot' "$RUNTIME/certbot/conf/renewal/$domain.conf" || fail "$domain: authenticator is not webroot"
  sh -n "$RUNTIME/bin/issue-$domain.sh"
  grep -q 'certonly' "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: issue script has no certonly"
  grep -q -- '--webroot' "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: issue script is not webroot"
  grep -q -- '--agree-tos' "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: missing --agree-tos"
  grep -q -- '--non-interactive' "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: missing --non-interactive"
  grep -q -- '--keep-until-expiring' "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: missing --keep-until-expiring"
  grep -q -- '--server' "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: missing --server"
  grep -q 'https://pebble:14000/dir' "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: missing ACME URL"
  if grep -q -- '--staging' "$RUNTIME/bin/issue-$domain.sh"; then
    fail "$domain: local issue script must not use Let's Encrypt staging"
  fi
  grep -q -- "-d \"$domain\"" "$RUNTIME/bin/issue-$domain.sh" || fail "$domain: certbot -d is missing"
  issuer=$(openssl x509 -in "$RUNTIME/certbot/conf/live/$domain/fullchain.pem" -noout -issuer)
  printf '%s\n' "$issuer" | grep -q 'Pebble' || fail "$domain: issuer is not Pebble" "$issuer"
  pass "$domain certificate"
done

san=$(openssl x509 -in "$RUNTIME/certbot/conf/live/demo.test/fullchain.pem" -noout -ext subjectAltName)
printf '%s\n' "$san" | grep -q 'DNS:demo.test' || fail "SAN missing DNS:demo.test" "$san"
printf '%s\n' "$san" | grep -q 'DNS:www.demo.test' || fail "SAN missing DNS:www.demo.test" "$san"
pass "SAN demo.test www.demo.test"

grep -q '^demo:' "$RUNTIME/nginx/htpasswd/secure.test" || fail "htpasswd has no demo"
grep -q '^auditor:' "$RUNTIME/nginx/htpasswd/secure.test" || fail "htpasswd has no auditor"
pass "htpasswd users"

mkdir -p "$RUNTIME/certbot/www/.well-known/acme-challenge"
printf 'ping' > "$RUNTIME/certbot/www/.well-known/acme-challenge/ping"

code=$(curl_code --resolve demo.test:80:127.0.0.1 "http://demo.test/.well-known/acme-challenge/ping")
[ "$code" = "200" ] || fail "ACME over HTTP should stay 200" "$code $(cat /tmp/nginx-playbook-body)"
[ "$(cat /tmp/nginx-playbook-body)" = "ping" ] || fail "ACME body mismatch" "$(cat /tmp/nginx-playbook-body)"
pass "HTTP-01 is not redirected"

code=$(curl_code -I --resolve demo.test:80:127.0.0.1 http://demo.test/)
[ "$code" = "301" ] || fail "HTTP / on demo.test should be 301" "$code"
headers=$(curl -sSI --max-time 10 --resolve demo.test:80:127.0.0.1 http://demo.test/)
printf '%s\n' "$headers" | grep -qi '^location: https://demo.test/' || fail "Location demo.test" "$headers"
pass "demo.test redirects to https"

headers=$(curl -sSI --max-time 10 --resolve www.demo.test:80:127.0.0.1 http://www.demo.test/health)
printf '%s\n' "$headers" | grep -qi '^location: https://www.demo.test/health' || fail "Location www.demo.test" "$headers"
pass "www.demo.test keeps its own host"

code=$(curl_code -k --resolve demo.test:443:127.0.0.1 https://demo.test/)
[ "$code" = "200" ] || fail "HTTPS / demo.test" "$code $(cat /tmp/nginx-playbook-body)"
grep -q 'hello from demo.test' /tmp/nginx-playbook-body || fail "root content missing" "$(cat /tmp/nginx-playbook-body)"
pass "static /"

code=$(curl_code -k --resolve demo.test:443:127.0.0.1 https://demo.test/assets/app.txt)
[ "$code" = "200" ] || fail "HTTPS /assets/app.txt" "$code $(cat /tmp/nginx-playbook-body)"
[ "$(cat /tmp/nginx-playbook-body)" = "asset-ok" ] || fail "alias /assets/ returned the wrong file" "$(cat /tmp/nginx-playbook-body)"
pass "location alias /assets/"

code=$(curl_code -k --resolve demo.test:443:127.0.0.1 https://demo.test/health)
[ "$code" = "200" ] || fail "HTTPS /health" "$code"
[ "$(cat /tmp/nginx-playbook-body)" = "ok" ] || fail "return /health" "$(cat /tmp/nginx-playbook-body)"
pass "location return /health"

code=$(curl_code -k --resolve demo.test:443:127.0.0.1 https://demo.test/api/ping.txt)
[ "$code" = "200" ] || fail "proxy /api/" "$code $(cat /tmp/nginx-playbook-body)"
[ "$(cat /tmp/nginx-playbook-body)" = "backend-ok" ] || fail "proxy did not return the backend" "$(cat /tmp/nginx-playbook-body)"
pass "location proxy /api/"

code=$(curl_code -k --resolve demo.test:443:127.0.0.1 https://demo.test/robots.txt)
[ "$code" = "200" ] || fail "robots demo.test" "$code"
grep -q 'Disallow: /admin' /tmp/nginx-playbook-body || fail "robots.txt for demo.test" "$(cat /tmp/nginx-playbook-body)"
pass "robots.txt demo.test"

code=$(curl_code -k --resolve secure.test:443:127.0.0.1 https://secure.test/)
[ "$code" = "401" ] || fail "secure.test without a password should be 401" "$code"
headers=$(curl -sSI -k --max-time 10 --resolve secure.test:443:127.0.0.1 https://secure.test/)
printf '%s\n' "$headers" | grep -qi 'www-authenticate: basic' || fail "missing WWW-Authenticate" "$headers"
pass "basic auth on the server"

code=$(curl_code -k -u demo:wrong --resolve secure.test:443:127.0.0.1 https://secure.test/)
[ "$code" = "401" ] || fail "wrong password should be 401" "$code"
pass "wrong password"

code=$(curl_code -k -u demo:demo-password --resolve secure.test:443:127.0.0.1 https://secure.test/)
[ "$code" = "200" ] || fail "demo:demo-password" "$code $(cat /tmp/nginx-playbook-body)"
[ "$(cat /tmp/nginx-playbook-body)" = "secret" ] || fail "body for demo" "$(cat /tmp/nginx-playbook-body)"
pass "user demo"

code=$(curl_code -k -u auditor:auditor-password --resolve secure.test:443:127.0.0.1 https://secure.test/)
[ "$code" = "200" ] || fail "auditor" "$code $(cat /tmp/nginx-playbook-body)"
[ "$(cat /tmp/nginx-playbook-body)" = "secret" ] || fail "body for auditor" "$(cat /tmp/nginx-playbook-body)"
pass "user auditor"

code=$(curl_code -k --resolve secure.test:443:127.0.0.1 https://secure.test/public/index.txt)
[ "$code" = "200" ] || fail "/public/ should be open" "$code $(cat /tmp/nginx-playbook-body)"
[ "$(cat /tmp/nginx-playbook-body)" = "open" ] || fail "body of /public/" "$(cat /tmp/nginx-playbook-body)"
pass "location with basic_auth off"

code=$(curl_code -k --resolve secure.test:443:127.0.0.1 https://secure.test/robots.txt)
[ "$code" = "200" ] || fail "robots.txt behind basic auth should be open" "$code $(cat /tmp/nginx-playbook-body)"
grep -q 'Disallow: /private' /tmp/nginx-playbook-body || fail "robots.txt for secure.test" "$(cat /tmp/nginx-playbook-body)"
pass "robots.txt stays open"

echo "Second playbook run..."
recap=$("$AP" playbooks/site.yml)
printf '%s\n' "$recap" | tail -n 20
printf '%s\n' "$recap" | grep -q 'failed=0' || fail "second run failed" "$recap"
printf '%s\n' "$recap" | grep -q 'unreachable=0' || fail "second run unreachable" "$recap"
printf '%s\n' "$recap" | grep -q 'changed=0' || fail "second run was not idempotent" "$recap"
pass "second run changed=0"

code=$(curl_code -k --resolve demo.test:443:127.0.0.1 https://demo.test/health)
[ "$code" = "200" ] || fail "/health broke after the second run" "$code"
pass "nginx still answers"

rm -f "$RUNTIME/certbot/www/.well-known/acme-challenge/ping"
echo "ok"
