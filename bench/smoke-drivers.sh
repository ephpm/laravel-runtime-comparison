#!/usr/bin/env bash
# Pre-flight for the session sweep: start each driver's image, prove the
# compiled config is what the profile claims, prove the session store actually
# advances one entry per request, and record the SQLite pragmas that decide
# whether a writer blocks readers. Not a measurement.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ENGINE:-podman}"
ARM="${ARM:-ephpm-worker}"
PORT="${PORT:-8087}"
OUT="${OUT:-$ROOT_DIR/results/preflight-$(date -u +%Y%m%dT%H%M%SZ)}"
REDIS_IMAGE="redis:7-alpine@sha256:1db42ccef14898aa29bae778452d567534b59c107129cbc1163fb552de184d3c"
APP=bench-smoke-app
RED=bench-smoke-redis
POD=bench-smoke-pod

mkdir -p "$OUT"
cleanup() {
  "$ENGINE" pod rm -f "$POD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

php_cmd() { case "$ARM" in ephpm|ephpm-worker) printf 'ephpm php' ;; *) printf 'php' ;; esac; }

for spec in "array:runtime" "file:file-sessions" "database:upstream" "redis:redis-sessions"; do
  driver="${spec%%:*}"
  profile="${spec##*:}"
  printf '\n===== %s (profile %s)\n' "$driver" "$profile"

  cleanup
  "$ENGINE" pod create --name "$POD" --add-host redis:127.0.0.1 -p "$PORT:8000" >/dev/null
  if [[ "$driver" == redis ]]; then
    "$ENGINE" run -d --pod "$POD" --name "$RED" "$REDIS_IMAGE" >/dev/null
  fi
  "$ENGINE" run -d --pod "$POD" --name "$APP" \
    -e APP_ENV=production -e APP_DEBUG=false -e LOG_CHANNEL=stderr \
    -e EPHPM_APP_BASE=/var/www/html "bench-$ARM:$profile" >/dev/null

  for _ in $(seq 1 90); do
    curl -sf "http://127.0.0.1:$PORT/api/static" >/dev/null 2>&1 && break
    sleep 1
  done

  probe='$c = require "/var/www/html/bootstrap/cache/config.php"; printf("session.driver=%s cache.default=%s db.default=%s\n", $c["session"]["driver"], $c["cache"]["default"], $c["database"]["default"]);'
  "$ENGINE" exec "$APP" sh -c "$(php_cmd) -r '$probe'" | tee "$OUT/$driver-config.txt"

  "$ENGINE" exec "$APP" sh -c \
    "$(php_cmd) -r '\$p=new PDO(\"sqlite:/var/www/html/database/database.sqlite\"); foreach([\"journal_mode\",\"busy_timeout\",\"synchronous\"] as \$g){printf(\"%s=%s\n\",\$g,\$p->query(\"PRAGMA \$g\")->fetchColumn());} \$t=\$p->query(\"select name from sqlite_master where type=(char(116)||char(97)||char(98)||char(108)||char(101))\")->fetchAll(PDO::FETCH_COLUMN); echo \"tables=\".implode(\",\",\$t).\"\n\";'" \
    | tee "$OUT/$driver-sqlite.txt"

  count_store() {
    case "$driver" in
      database) "$ENGINE" exec "$APP" sh -c "$(php_cmd) -r 'echo (new PDO(\"sqlite:/var/www/html/database/database.sqlite\"))->query(\"select count(*) from sessions\")->fetchColumn();'" ;;
      file) "$ENGINE" exec "$APP" sh -c 'find /var/www/html/storage/framework/sessions -type f ! -name ".gitignore" | wc -l' ;;
      redis) "$ENGINE" exec "$RED" redis-cli dbsize | tr -d "\r" ;;
      *) printf '0' ;;
    esac
  }

  before="$(count_store)"
  for _ in $(seq 1 100); do curl -sf "http://127.0.0.1:$PORT/api/static" >/dev/null; done
  after="$(count_store)"
  printf 'session store: before=%s after=%s delta=%s over 100 requests\n' \
    "$before" "$after" "$((after - before))" | tee "$OUT/$driver-mechanism.txt"

  if [[ "$driver" == redis ]]; then
    "$ENGINE" exec "$RED" sh -c 'redis-server --version; redis-cli config get save; redis-cli config get appendonly' \
      | tee "$OUT/redis-config.txt"
    "$ENGINE" exec "$RED" redis-cli --scan --count 3 2>/dev/null | head -3 | tee "$OUT/redis-sample-keys.txt" || true
  fi
done

printf '\nPreflight written to %s\n' "$OUT"
