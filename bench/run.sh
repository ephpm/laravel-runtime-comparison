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

# Which session/cache store every image is built with. See README.md,
# "Benchmark profiles". Exported because the Compose files read it as a build
# argument; the Dockerfiles map it onto SESSION_DRIVER and CACHE_STORE before
# `php artisan config:cache` bakes them in.
#
#   upstream -- database, exactly what app/.env.example ships
#   runtime  -- array
BENCH_PROFILE="${BENCH_PROFILE:-upstream}"
export BENCH_PROFILE

case "$BENCH_PROFILE" in
  upstream) EXPECTED_STORE="database" ;;
  runtime) EXPECTED_STORE="array" ;;
  *)
    printf 'BENCH_PROFILE must be "upstream" or "runtime", got: %s\n' "$BENCH_PROFILE" >&2
    exit 1
    ;;
esac

# Container engine. Defaults to Docker Compose v2. Set COMPOSE_CMD to run the
# suite under a different engine, for example COMPOSE_CMD="podman compose".
read -r -a COMPOSE <<< "${COMPOSE_CMD:-docker compose}"

runtime_port() {
  case "$1" in
    frankenphp) printf '8081' ;;
    swoole) printf '8082' ;;
    openswoole) printf '8083' ;;
    roadrunner) printf '8084' ;;
    nginx-fpm) printf '8085' ;;
    ephpm) printf '8086' ;;
    ephpm-worker) printf '8087' ;;
    *) return 1 ;;
  esac
}

# Command that runs the embedded PHP CLI inside a runtime's container. ePHPm
# links PHP into its own binary and ships no standalone php executable, so its
# runtime metadata is captured through the `ephpm php` subcommand instead.
runtime_php_command() {
  case "$1" in
    ephpm | ephpm-worker) printf 'ephpm php' ;;
    *) printf 'php' ;;
  esac
}

runtime_order_for_round() {
  local round="$1"
  local runtimes=(frankenphp swoole openswoole roadrunner nginx-fpm ephpm ephpm-worker)
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
  printf 'Runtime values: frankenphp swoole openswoole roadrunner nginx-fpm ephpm ephpm-worker\n'
  printf 'Defaults: ROUNDS=3 DURATION=30s THREADS=10 CONNECTIONS=100 TIMEOUT=5s WARMUP_REQUESTS=100 COOLDOWN=900.\n'
  printf 'BENCH_PROFILE=upstream|runtime selects the session/cache store the images are built with\n'
  printf '(upstream=database, the harness default; runtime=array). Default: upstream.\n'
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

  # SKIP_BUILD=1 measures against whatever image is already tagged. Needed for
  # config-only sweeps: podman does not cache a cross-stage `COPY --from=build`
  # reliably, so re-running `compose build` between arms mints a new image ID
  # from unchanged inputs. That is a variable the sweep is not trying to
  # measure, so the image is built once up front and pinned for every arm.
  #
  # It does not skip the BENCH_PROFILE check: an image built with the other
  # profile is caught after start-up and aborts the run rather than being
  # measured.
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    printf '  build: %s (skipped, SKIP_BUILD=1)\n' "$runtime"
    return 0
  fi

  printf '  build: %s\n' "$runtime"
  "${COMPOSE[@]}" -f "$compose" build
  if [[ "$runtime" == "nginx-fpm" ]]; then
    "${COMPOSE[@]}" -f "$compose" pull nginx
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
  local php_command

  port="$(runtime_port "$runtime")"
  endpoint_order="$(endpoint_order_for_round "$round")"
  if is_complete "$run_dir"; then
    printf '\n==> round %s: %s already complete, skipping\n' "$round" "$runtime"
    return 2
  fi

  mkdir -p "$run_dir"
  printf '\n==> round %s/%s: %s (port %s)\n' "$round" "$ROUNDS" "$runtime" "$port"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$run_dir/started-at.txt"
  "${COMPOSE[@]}" -f "$compose" up -d --no-build
  trap '"${COMPOSE[@]}" -f "$compose" down --remove-orphans' RETURN

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

  "${COMPOSE[@]}" -f "$compose" images > "$run_dir/images.txt"
  php_command="$(runtime_php_command "$runtime")"
  # Metadata capture is best effort: a runtime that reports its build
  # differently must not abort a measurement that is otherwise valid.
  "${COMPOSE[@]}" -f "$compose" exec -T "$service" sh -c \
    "$php_command -v; printf '\nExtensions:\n'; $php_command -m; printf '\nOPcache:\n'; $php_command --ri 'Zend OPcache'" \
    > "$run_dir/php-runtime.txt" 2>&1 || printf 'metadata capture failed for %s\n' "$runtime" >> "$run_dir/php-runtime.txt"

  # Which session/cache driver this image ACTUALLY runs, read out of the
  # compiled config cache inside the container, and checked against the profile
  # this run asked for.
  #
  # `php artisan config:cache` bakes the drivers into the image at build time,
  # so an image runs whatever BENCH_PROFILE it was built with -- which need not
  # be what this shell asked for, and is not visible in any config file at run
  # time. Running the wrong one does not present as a config problem: every
  # runtime collapses by 10-60x, together, so the comparison still looks
  # internally fair, and a control runtime that was rebuilt in the same pass
  # collapses with the subject, which reads as a dead host rather than a
  # changed config. Mismatch is fatal on purpose; an unverifiable run is worse
  # than no run.
  # Single-quoted for the inner shell; the snippet itself contains no single
  # quotes, so it survives the nesting intact.
  config_probe='$c = require "/var/www/html/bootstrap/cache/config.php"; printf("session.driver=%s cache.default=%s db.default=%s\n", $c["session"]["driver"], $c["cache"]["default"], $c["database"]["default"]);'
  if ! "${COMPOSE[@]}" -f "$compose" exec -T "$service" \
      sh -c "$php_command -r '$config_probe'" > "$run_dir/app-config.txt" 2>&1; then
    printf 'Could not read the compiled config cache from %s. Refusing to measure a run whose configuration cannot be verified.\n' "$runtime" >&2
    cat "$run_dir/app-config.txt" >&2
    return 1
  fi
  printf '    app config: %s\n' "$(tr '\n' ' ' < "$run_dir/app-config.txt")"

  if ! grep -q "session.driver=$EXPECTED_STORE cache.default=$EXPECTED_STORE" "$run_dir/app-config.txt"; then
    printf 'BENCH_PROFILE=%s expects session.driver=%s and cache.default=%s, but the %s image is running: %s\n' \
      "$BENCH_PROFILE" "$EXPECTED_STORE" "$EXPECTED_STORE" "$runtime" \
      "$(tr '\n' ' ' < "$run_dir/app-config.txt")" >&2
    printf 'That image was built with a different profile. Rebuild it (do not pass SKIP_BUILD=1) or set BENCH_PROFILE to match it.\n' >&2
    return 1
  fi

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
    printf 'bench_profile=%s\n' "$BENCH_PROFILE"
    printf 'session_and_cache_store=%s\n' "$EXPECTED_STORE"
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

command -v "${COMPOSE[0]}" >/dev/null || { printf '%s is required\n' "${COMPOSE[0]}" >&2; exit 1; }
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

printf 'Benchmark profile: %s (session and cache store: %s)\n' "$BENCH_PROFILE" "$EXPECTED_STORE"
printf 'Preparing runtime images before measurements...\n'
if [[ "$RUNTIME_LIST" == "all" ]]; then
  for runtime in frankenphp swoole openswoole roadrunner nginx-fpm ephpm ephpm-worker; do
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
