#!/usr/bin/env bash
# Concurrency sweep across session drivers, one arm, one endpoint.
#
# The question this answers is not "are database sessions slower" -- that is
# already known -- but "is the cost a *global* lock". The two have different
# signatures against rising concurrency:
#
#   global writer lock -> throughput is flat as connections rise; every
#     request serialises behind the same resource, so adding load adds queueing
#     and nothing else.
#   worker-count limit -> throughput scales until the workers are busy and then
#     plateaus. With `concurrency = 2` on every arm here, that plateau is at
#     roughly twice the single-connection number.
#
# Distinguishing them needs the ladder, not a single 100-connection point,
# which is why this exists alongside bench/run.sh rather than inside it.
#
# Each cell gets a FRESH container. That is deliberate and it matters: wrk
# sends no cookies, so every request mints a new session id and the store grows
# by one row (or one file, or one key) per request. Reusing a container would
# start the 100-connection cell against a store holding a million rows the
# 1-connection cell never saw, and any flattening could then be blamed on table
# growth instead of on locking. Restarting also makes the mechanism counters
# below exact: the store starts empty, so its size afterwards *is* the number
# of session writes that cell performed.
#
# Usage: bash bench/session-sweep.sh [driver ...]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ENGINE:-podman}"

ARM="${ARM:-ephpm-worker}"
PORT="${PORT:-8087}"
ENDPOINT="${ENDPOINT:-static}"
DURATION="${DURATION:-25s}"
TIMEOUT="${TIMEOUT:-5s}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-200}"
REPEATS="${REPEATS:-3}"
# Which repeats this invocation should record. Split out so a long sweep can be
# driven one repeat at a time and resumed; cells that already have wrk output
# are skipped, so re-invoking is safe and never silently re-measures.
REPEAT_LIST="${REPEAT_LIST:-$(seq 1 "$REPEATS")}"
CELL_COOLDOWN="${CELL_COOLDOWN:-10}"
DRIVER_COOLDOWN="${DRIVER_COOLDOWN:-30}"
CONNECTION_LADDER="${CONNECTION_LADDER:-1 2 4 8 16 32 64 100}"
RUN_ID="${RUN_ID:-sweep-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/results/$RUN_ID}"

APP_CONTAINER="bench-sweep-app"
REDIS_CONTAINER="bench-sweep-redis"
POD="bench-sweep-pod"
REDIS_IMAGE="redis:7-alpine@sha256:1db42ccef14898aa29bae778452d567534b59c107129cbc1163fb552de184d3c"

DRIVERS=("$@")
if [[ "${#DRIVERS[@]}" -eq 0 ]]; then
  DRIVERS=(array file database redis)
fi

# BENCH_PROFILE that provides each session driver, and the cache store that
# profile pairs it with. Cache is `array` everywhere except `upstream`, so
# across file/redis/array the session driver is the only variable; `database`
# (upstream) moves cache too, which is what the Tier 3 cell exists to separate.
profile_for() {
  case "$1" in
    array) printf 'runtime' ;;
    file) printf 'file-sessions' ;;
    file-nogc) printf 'file-sessions-nogc' ;;
    database) printf 'upstream' ;;
    redis) printf 'redis-sessions' ;;
    *) return 1 ;;
  esac
}

# The compiled config reports session.driver=file for both file legs, so the
# per-cell check below is asked about the driver, not the profile.
config_driver_for() {
  case "$1" in
    file-nogc) printf 'file' ;;
    *) printf '%s' "$1" ;;
  esac
}

expected_cache_for() {
  case "$1" in
    database) printf 'database' ;;
    *) printf 'array' ;;
  esac
}

php_cmd() {
  case "$ARM" in
    ephpm | ephpm-worker) printf 'ephpm php' ;;
    *) printf 'php' ;;
  esac
}

cleanup() {
  "$ENGINE" pod rm -f "$POD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Every driver runs in a pod, including the three that need no sidecar, so the
# network path is identical across drivers and only the presence of the Redis
# container varies. A pod shares one network namespace, so Redis is reached
# over loopback rather than a bridge; rootless aardvark-dns cannot start in
# this VM (no session bus for its transient scope), which rules out a DNS
# bridge network. Loopback is the same shape as a Kubernetes sidecar and, if
# anything, slightly flatters Redis by removing bridge NAT -- so it does not
# weaken the "Redis is not the clean control" caveat, it strengthens it.
start_stack() {
  local driver="$1"
  local profile
  profile="$(profile_for "$driver")"

  cleanup
  "$ENGINE" pod create --name "$POD" --add-host "redis:127.0.0.1" -p "$PORT:8000" >/dev/null

  if [[ "$driver" == "redis" ]]; then
    "$ENGINE" run -d --pod "$POD" --name "$REDIS_CONTAINER" "$REDIS_IMAGE" >/dev/null
  fi

  "$ENGINE" run -d --pod "$POD" --name "$APP_CONTAINER" \
    -e APP_ENV=production -e APP_DEBUG=false -e LOG_CHANNEL=stderr \
    -e EPHPM_APP_BASE=/var/www/html \
    "bench-$ARM:$profile" >/dev/null

  local attempt
  for attempt in $(seq 1 90); do
    if curl --silent --fail "http://127.0.0.1:$PORT/api/$ENDPOINT" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'stack for driver %s did not become ready\n' "$driver" >&2
  "$ENGINE" logs "$APP_CONTAINER" >&2 || true
  return 1
}

# Reads the drivers out of the COMPILED config cache inside the running
# container. An image serves whatever profile it was built with; the source
# tree being right proves nothing, so this is checked per cell, not per build.
verify_config() {
  local driver="$1"
  local out="$2"
  local expect_cache expect_driver
  expect_cache="$(expected_cache_for "$driver")"
  expect_driver="$(config_driver_for "$driver")"
  # session.lottery is included because it is the only thing separating the two
  # file legs, and it is not visible anywhere else at run time.
  local probe='$c = require "/var/www/html/bootstrap/cache/config.php"; printf("session.driver=%s cache.default=%s db.default=%s session.lottery=%s\n", $c["session"]["driver"], $c["cache"]["default"], $c["database"]["default"], implode(",", $c["session"]["lottery"]));'

  "$ENGINE" exec "$APP_CONTAINER" sh -c "$(php_cmd) -r '$probe'" > "$out" 2>&1

  if ! grep -q "session.driver=$expect_driver cache.default=$expect_cache" "$out"; then
    printf 'driver %s expects session.driver=%s cache.default=%s, image reports: %s\n' \
      "$driver" "$expect_driver" "$expect_cache" "$(tr '\n' ' ' < "$out")" >&2
    return 1
  fi

  local expect_lottery="2,100"
  [[ "$driver" == "file-nogc" ]] && expect_lottery="0,100"
  if ! grep -q "session.lottery=$expect_lottery" "$out"; then
    printf 'driver %s expects session.lottery=%s, image reports: %s\n' \
      "$driver" "$expect_lottery" "$(tr '\n' ' ' < "$out")" >&2
    return 1
  fi
}

# Size of the session store. With a fresh container this is exactly the number
# of sessions written since start-up, because wrk never sends a cookie back.
session_store_count() {
  local driver="$1"
  case "$driver" in
    database)
      "$ENGINE" exec "$APP_CONTAINER" sh -c \
        "$(php_cmd) -r 'echo (new PDO(\"sqlite:/var/www/html/database/database.sqlite\"))->query(\"select count(*) from sessions\")->fetchColumn();'" 2>/dev/null || printf 'NA'
      ;;
    file | file-nogc)
      "$ENGINE" exec "$APP_CONTAINER" sh -c \
        'find /var/www/html/storage/framework/sessions -type f ! -name ".gitignore" | wc -l' 2>/dev/null || printf 'NA'
      ;;
    redis)
      "$ENGINE" exec "$REDIS_CONTAINER" redis-cli dbsize 2>/dev/null | tr -d '\r' || printf 'NA'
      ;;
    *) printf '0' ;;
  esac
}

mkdir -p "$RESULT_DIR"

{
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'arm=%s\n' "$ARM"
  printf 'endpoint=/api/%s\n' "$ENDPOINT"
  printf 'drivers=%s\n' "${DRIVERS[*]}"
  printf 'connection_ladder=%s\n' "$CONNECTION_LADDER"
  printf 'duration=%s\n' "$DURATION"
  printf 'timeout=%s\n' "$TIMEOUT"
  printf 'warmup_requests=%s\n' "$WARMUP_REQUESTS"
  printf 'repeats=%s\n' "$REPEATS"
  printf 'cell_cooldown_seconds=%s\n' "$CELL_COOLDOWN"
  printf 'driver_cooldown_seconds=%s\n' "$DRIVER_COOLDOWN"
  printf 'fresh_container_per_cell=yes\n'
  printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RESULT_DIR/settings.txt"

if [[ ! -s "$RESULT_DIR/mechanism.csv" ]]; then
  printf 'driver,connections,repeat,sessions_written,started_at,finished_at\n' > "$RESULT_DIR/mechanism.csv"
fi

for repeat in $REPEAT_LIST; do
  # Rotate which driver measures first, so no driver always runs on the
  # freshest host.
  count="${#DRIVERS[@]}"
  offset=$(( (repeat - 1) % count ))
  order=()
  for i in $(seq 0 $((count - 1))); do
    order+=("${DRIVERS[$(( (offset + i) % count ))]}")
  done

  for driver in "${order[@]}"; do
    printf '\n########## repeat %s/%s driver %s (profile %s)\n' \
      "$repeat" "$REPEATS" "$driver" "$(profile_for "$driver")"

    for connections in $CONNECTION_LADDER; do
      cell="$RESULT_DIR/$driver/c$connections/repeat-$repeat"
      if [[ -s "$cell/wrk.txt" ]]; then
        printf '  c=%s repeat=%s already recorded, skipping\n' "$connections" "$repeat"
        continue
      fi
      mkdir -p "$cell"

      start_stack "$driver"
      verify_config "$driver" "$cell/app-config.txt"

      # SQLite's locking mode is the whole mechanism, so it is recorded per
      # driver rather than assumed. `podman logs` comes back empty for a
      # detached container in this VM, so the ePHPm settings line is captured
      # separately by bench/capture-ephpm-settings.sh instead of from here.
      if [[ "$connections" == "1" ]]; then
        "$ENGINE" exec "$APP_CONTAINER" sh -c \
          "$(php_cmd) -r '\$p=new PDO(\"sqlite:/var/www/html/database/database.sqlite\"); foreach([\"journal_mode\",\"busy_timeout\",\"synchronous\"] as \$g){printf(\"%s=%s\n\",\$g,\$p->query(\"PRAGMA \$g\")->fetchColumn());}'" \
          > "$RESULT_DIR/$driver/sqlite-pragmas.txt" 2>&1 || true
        if [[ "$driver" == "redis" ]]; then
          "$ENGINE" exec "$REDIS_CONTAINER" sh -c \
            'redis-server --version; redis-cli config get save; redis-cli config get appendonly; redis-cli config get maxmemory-policy' \
            > "$RESULT_DIR/$driver/redis-config.txt" 2>&1 || true
        fi
      fi

      threads=10
      [[ "$connections" -lt 10 ]] && threads="$connections"

      url="http://127.0.0.1:$PORT/api/$ENDPOINT"
      for _ in $(seq 1 "$WARMUP_REQUESTS"); do
        curl --silent --fail --max-time 10 "$url" >/dev/null || true
      done

      before="$(session_store_count "$driver")"
      started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '  wrk -t%s -c%s -d%s %s\n' "$threads" "$connections" "$DURATION" "$url"

      # Redis CPU during the window, so the "second container competing for the
      # same cores" caveat is a number rather than an assertion. Backgrounded
      # for the length of this cell only and reaped before the next one.
      if [[ "$driver" == "redis" ]]; then
        ( "$ENGINE" stats --no-stream --format '{{.Name}} cpu={{.CPU}} mem={{.MemUsage}}' \
            "$REDIS_CONTAINER" "$APP_CONTAINER" > "$cell/container-stats.txt" 2>&1 ) &
        stats_pid=$!
      fi

      wrk -t"$threads" -c"$connections" -d"$DURATION" --timeout "$TIMEOUT" --latency "$url" \
        > "$cell/wrk.txt" 2>&1
      finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      if [[ "$driver" == "redis" ]]; then
        wait "${stats_pid:-}" 2>/dev/null || true
      fi

      after="$(session_store_count "$driver")"
      printf '%s,%s,%s,%s,%s,%s\n' \
        "$driver" "$connections" "$repeat" "$after" "$started_at" "$finished_at" \
        >> "$RESULT_DIR/mechanism.csv"

      grep -E 'Requests/sec|Non-2xx|Socket errors' "$cell/wrk.txt" || true
      printf '  sessions in store after cell: %s (was %s at window start)\n' "$after" "$before"

      cleanup
      sleep "$CELL_COOLDOWN"
    done

    sleep "$DRIVER_COOLDOWN"
  done
done

printf 'finished_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RESULT_DIR/settings.txt"
printf '\nSweep written to %s\n' "$RESULT_DIR"
