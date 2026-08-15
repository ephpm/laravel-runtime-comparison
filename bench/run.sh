#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DURATION="${DURATION:-30s}"
THREADS="${THREADS:-10}"
CONNECTIONS="${CONNECTIONS:-100}"
ROUNDS="${ROUNDS:-${RUNS:-3}}"
TIMEOUT="${TIMEOUT:-5s}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-100}"
COOLDOWN="${COOLDOWN:-900}"
ENDPOINT_COOLDOWN="${ENDPOINT_COOLDOWN:-0}"
INITIAL_COOLDOWN="${INITIAL_COOLDOWN:-$COOLDOWN}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_ROOT="${RESULT_ROOT:-$ROOT_DIR/results}"
RESULT_DIR="$RESULT_ROOT/$RUN_ID"
RUNTIME_LIST=""

runtime_port() {
  case "$1" in
    frankenphp) printf '8081' ;;
    swoole) printf '8082' ;;
    openswoole) printf '8083' ;;
    roadrunner) printf '8084' ;;
    nginx-fpm) printf '8085' ;;
    *) return 1 ;;
  esac
}

runtime_order_for_round() {
  local round="$1"
  local runtimes=(frankenphp swoole openswoole roadrunner nginx-fpm)
  local count="${#runtimes[@]}"
  local offset=$(( (round - 1) % count ))
  local index=0

  while [[ "$index" -lt "$count" ]]; do
    printf '%s ' "${runtimes[$(( (offset + index) % count ))]}"
    index=$((index + 1))
  done
}

endpoint_order_for_round() {
  local round="$1"
  local endpoints=(db health static cpu)
  local count="${#endpoints[@]}"
  local offset=$(( (round - 1) % count ))
  local index=0

  while [[ "$index" -lt "$count" ]]; do
    printf '%s ' "${endpoints[$(( (offset + index) % count ))]}"
    index=$((index + 1))
  done
}

usage() {
  printf 'Usage: %s [runtime|all]\n' "$0"
  printf 'Runtime values: frankenphp swoole openswoole roadrunner nginx-fpm\n'
  printf 'Defaults: ROUNDS=3 DURATION=30s THREADS=10 CONNECTIONS=100 TIMEOUT=5s WARMUP_REQUESTS=100 COOLDOWN=900.\n'
}

is_complete() {
  local run_dir="$1"
  local endpoint
  local endpoint_index
  local endpoints
  local endpoint_order

  for endpoint in db health static cpu; do
    [[ -s "$run_dir/$endpoint.txt" ]] || return 1
  done
}

prepare_runtime() {
  local runtime="$1"
  local compose="$ROOT_DIR/runtimes/$runtime/docker-compose.yml"

  printf '  build: %s\n' "$runtime"
  docker compose -f "$compose" build
  if [[ "$runtime" == "nginx-fpm" ]]; then
    docker compose -f "$compose" pull nginx
  fi
}

run_one() {
  local runtime="$1"
  local round="$2"
  local port
  local compose="$ROOT_DIR/runtimes/$runtime/docker-compose.yml"
  local output="$RESULT_DIR/$runtime"
  local run_dir="$output/run-$round"
  local service="app"
  local endpoint
  local url
  local warmup
  local ready=0
  local attempt

  port="$(runtime_port "$runtime")"
  endpoint_order="$(endpoint_order_for_round "$round")"
  if is_complete "$run_dir"; then
    printf '\n==> round %s: %s already complete, skipping\n' "$round" "$runtime"
    return 2
  fi

  mkdir -p "$run_dir"
  printf '\n==> round %s/%s: %s (port %s)\n' "$round" "$ROUNDS" "$runtime" "$port"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$run_dir/started-at.txt"
  docker compose -f "$compose" up -d --no-build
  trap 'docker compose -f "$compose" down --remove-orphans' RETURN

  for attempt in $(seq 1 60); do
    if curl --silent --fail "http://127.0.0.1:$port/api/static" >/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" -ne 1 ]]; then
    printf 'Runtime %s did not become ready within 60 seconds.\n' "$runtime" >&2
    return 1
  fi

  curl --silent --show-error --fail "http://127.0.0.1:$port/api/static" > "$run_dir/smoke.json"
  if [[ "$runtime" == "nginx-fpm" ]]; then
    service="php"
  fi

  docker compose -f "$compose" images > "$run_dir/images.txt"
  docker compose -f "$compose" exec -T "$service" sh -c \
    'php -v; printf "\nExtensions:\n"; php -m; printf "\nOPcache:\n"; php --ri "Zend OPcache"' \
    > "$run_dir/php-runtime.txt"

  for endpoint in $endpoint_order; do
    url="http://127.0.0.1:$port/api/$endpoint"
    printf '    warm-up %s (%s requests)\n' "$endpoint" "$WARMUP_REQUESTS"
    for warmup in $(seq 1 "$WARMUP_REQUESTS"); do
      curl --silent --show-error --fail --max-time 10 "$url" >/dev/null
    done
  done

  endpoints=($endpoint_order)
  for endpoint_index in "${!endpoints[@]}"; do
    endpoint="${endpoints[$endpoint_index]}"
    url="http://127.0.0.1:$port/api/$endpoint"
    printf '    wrk %s\n' "$url"
    wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --timeout "$TIMEOUT" --latency "$url" \
      | tee "$run_dir/$endpoint.txt"
    if [[ "$endpoint_index" -lt "$((${#endpoints[@]} - 1))" ]] && [[ "$ENDPOINT_COOLDOWN" -gt 0 ]]; then
      printf '    endpoint cooldown: %s seconds\n' "$ENDPOINT_COOLDOWN"
      sleep "$ENDPOINT_COOLDOWN"
    fi
  done

  date -u +%Y-%m-%dT%H:%M:%SZ > "$run_dir/finished-at.txt"
}

write_settings() {
  {
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'rounds=%s\n' "$ROUNDS"
    printf 'duration=%s\n' "$DURATION"
    printf 'threads=%s\n' "$THREADS"
    printf 'connections=%s\n' "$CONNECTIONS"
    printf 'timeout=%s\n' "$TIMEOUT"
    printf 'warmup_requests=%s\n' "$WARMUP_REQUESTS"
    printf 'cooldown_seconds=%s\n' "$COOLDOWN"
    printf 'endpoint_cooldown_seconds=%s\n' "$ENDPOINT_COOLDOWN"
    printf 'initial_cooldown_seconds=%s\n' "$INITIAL_COOLDOWN"
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RESULT_DIR/settings.txt"
}

write_schedule() {
  local sequence=0
  local round
  local runtime
  local order
  local endpoint_order
  local endpoint_order_csv

  printf 'sequence,round,runtime,endpoint_order\n' > "$RESULT_DIR/schedule.csv"
  for round in $(seq 1 "$ROUNDS"); do
    if [[ "$RUNTIME_LIST" == "all" ]]; then
      order="$(runtime_order_for_round "$round")"
    else
      order="$RUNTIME_LIST"
    fi
    endpoint_order="$(endpoint_order_for_round "$round")"
    endpoint_order_csv="${endpoint_order% }"
    endpoint_order_csv="${endpoint_order_csv// /|}"
    for runtime in $order; do
      sequence=$((sequence + 1))
      printf '%s,%s,%s,%s\n' "$sequence" "$round" "$runtime" "$endpoint_order_csv" >> "$RESULT_DIR/schedule.csv"
    done
  done
}

has_incomplete_tests() {
  local sequence
  local round
  local runtime
  local endpoint_order

  while IFS=, read -r sequence round runtime endpoint_order; do
    [[ "$sequence" == "sequence" ]] && continue
    if ! is_complete "$RESULT_DIR/$runtime/run-$round"; then
      return 0
    fi
  done < "$RESULT_DIR/schedule.csv"

  return 1
}

command -v docker >/dev/null || { printf 'docker is required\n' >&2; exit 1; }
command -v curl >/dev/null || { printf 'curl is required\n' >&2; exit 1; }
command -v wrk >/dev/null || { printf 'wrk is required\n' >&2; exit 1; }

target="${1:-}"
if [[ "$target" == "all" ]]; then
  RUNTIME_LIST="all"
elif runtime_port "$target" >/dev/null; then
  RUNTIME_LIST="$target"
else
  usage
  exit 1
fi

mkdir -p "$RESULT_DIR"
write_settings
write_schedule

printf 'Preparing runtime images before measurements...\n'
if [[ "$RUNTIME_LIST" == "all" ]]; then
  for runtime in frankenphp swoole openswoole roadrunner nginx-fpm; do
    prepare_runtime "$runtime"
  done
else
  prepare_runtime "$RUNTIME_LIST"
fi

if has_incomplete_tests && [[ "$INITIAL_COOLDOWN" -gt 0 ]]; then
  printf 'Initial cooldown after image preparation: %s seconds\n' "$INITIAL_COOLDOWN"
  sleep "$INITIAL_COOLDOWN"
fi

for round in $(seq 1 "$ROUNDS"); do
  if [[ "$RUNTIME_LIST" == "all" ]]; then
    order="$(runtime_order_for_round "$round")"
  else
    order="$RUNTIME_LIST"
  fi

  for runtime in $order; do
    status=0
    run_one "$runtime" "$round" || status=$?
    if [[ "$status" -eq 0 ]]; then
      if has_incomplete_tests; then
        printf '    cooldown: %s seconds before the next runtime\n' "$COOLDOWN"
        sleep "$COOLDOWN"
      fi
    elif [[ "$status" -ne 2 ]]; then
      exit "$status"
    fi
  done
done

bash "$ROOT_DIR/bench/summarize.sh" "$RUN_ID"
printf 'finished_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RESULT_DIR/settings.txt"
printf '\nResults written to %s\n' "$RESULT_DIR"
