#!/usr/bin/env bash
# Record the ePHPm execution settings the sweep runs under.
#
# `podman logs` returns nothing for a detached container in this VM, so the
# start-up banner is captured by running the server in the foreground for a few
# seconds instead. This is not a measurement -- it starts and stops its own
# container and must not overlap one.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ENGINE:-podman}"
IMAGE="${1:?Usage: $0 <image> [output]}"
OUT="${2:-$ROOT_DIR/results/ephpm-settings.txt}"

mkdir -p "$(dirname "$OUT")"
{
  printf '# image: %s\n' "$IMAGE"
  printf '# captured: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  timeout 12 "$ENGINE" run --rm -e RUST_LOG=info "$IMAGE" \
    ephpm serve --config /etc/ephpm/ephpm.toml 2>&1 || true
} | sed 's/\x1b\[[0-9;]*m//g' > "$OUT"

printf 'wrote %s\n' "$OUT"
grep -E 'php execution configured|concurrency from|worker pool started' "$OUT" || true
