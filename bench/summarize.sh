#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${1:?Usage: $0 <run-id>}"
RESULT_ROOT="${RESULT_ROOT:-$ROOT_DIR/results}"
RESULT_DIR="$RESULT_ROOT/$RUN_ID"
RAW="$RESULT_DIR/metrics.csv"
SUMMARY="$RESULT_DIR/summary.csv"

[[ -d "$RESULT_DIR" ]] || { printf 'Result directory not found: %s\n' "$RESULT_DIR" >&2; exit 1; }

printf 'runtime,endpoint,run,requests_per_sec,avg_latency_ms,p99_latency_ms,timeout_errors\n' > "$RAW"
for runtime in frankenphp swoole openswoole roadrunner nginx-fpm; do
  for run_path in "$RESULT_DIR/$runtime"/run-*; do
    [[ -d "$run_path" ]] || continue
    run="${run_path##*-}"
    for endpoint in db health static cpu; do
      raw_file="$run_path/$endpoint.txt"
      [[ -s "$raw_file" ]] || { printf 'Missing result: %s\n' "$raw_file" >&2; exit 1; }
      metrics="$(awk '
        function to_ms(value) {
          if (value ~ /ms$/) { sub(/ms$/, "", value); return value }
          if (value ~ /us$/) { sub(/us$/, "", value); return value / 1000 }
          if (value ~ /s$/) { sub(/s$/, "", value); return value * 1000 }
          return value
        }
        $1 == "Latency" && $2 ~ /(ms|us|s)$/ { average = to_ms($2) }
        $1 == "99%" { p99 = to_ms($2) }
        $1 == "Requests/sec:" { requests = $2 }
        $1 == "Socket" && $2 == "errors:" { timeouts = $10 }
        END {
          if (requests == "" || average == "" || p99 == "") exit 1
          print requests "," average "," p99 "," (timeouts + 0)
        }
      ' "$raw_file")" || { printf 'Could not parse result: %s\n' "$raw_file" >&2; exit 1; }
      printf '%s,%s,%s,%s\n' "$runtime" "$endpoint" "$run" "$metrics" >> "$RAW"
    done
  done
done

printf 'runtime,endpoint,runs,avg_requests_per_sec,stddev_requests_per_sec,min_requests_per_sec,max_requests_per_sec,avg_latency_ms,avg_p99_latency_ms,max_p99_latency_ms,total_timeout_errors\n' > "$SUMMARY"
awk -F, '
  function max(a, b) { return a > b ? a : b }
  NR > 1 {
    key = $1 "," $2
    runs[key] += 1
    requests[key] += $4
    requests_squared[key] += $4 * $4
    latency[key] += $5
    p99[key] += $6
    max_p99[key] = max(max_p99[key], $6)
    timeouts[key] += $7
    runtime[key] = $1
    endpoint[key] = $2
    if (runs[key] == 1 || $4 < min_requests[key]) min_requests[key] = $4
    if (runs[key] == 1 || $4 > max_requests[key]) max_requests[key] = $4
  }
  END {
    for (key in runs) {
      average = requests[key] / runs[key]
      variance = 0
      if (runs[key] > 1) {
        variance = (requests_squared[key] - (requests[key] * requests[key] / runs[key])) / (runs[key] - 1)
        if (variance < 0) variance = 0
      }
      printf "%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n", \
        runtime[key], endpoint[key], runs[key], average, sqrt(variance), \
        min_requests[key], max_requests[key], latency[key] / runs[key], \
        p99[key] / runs[key], max_p99[key], timeouts[key]
    }
  }
' "$RAW" | sort >> "$SUMMARY"

printf 'Summary written to %s\n' "$SUMMARY"
