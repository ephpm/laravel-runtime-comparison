#!/usr/bin/env bash
# Build one image per (arm, BENCH_PROFILE) with an explicit, distinct tag.
#
# The suite's Compose files all build to the same implicit tag per arm, so
# building a second profile overwrites the first. The session-driver sweep
# needs four profiles of the same arm to exist at once, so each is tagged
# bench-<arm>:<profile> here and driven with `podman run` by
# bench/session-sweep.sh rather than through Compose.
#
# Usage: bash bench/build-profiles.sh <arm> [profile ...]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ENGINE:-podman}"

arm="${1:?Usage: $0 <arm> [profile ...]}"
shift
profiles=("$@")
if [[ "${#profiles[@]}" -eq 0 ]]; then
  profiles=(upstream runtime file-sessions redis-sessions)
fi

for profile in "${profiles[@]}"; do
  printf '===== build %s / %s\n' "$arm" "$profile"
  "$ENGINE" build \
    -f "$ROOT_DIR/runtimes/$arm/Dockerfile" \
    --build-arg "BENCH_PROFILE=$profile" \
    -t "bench-$arm:$profile" \
    "$ROOT_DIR" 2>&1 | tail -3
done

printf '\n===== images\n'
"$ENGINE" images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | grep "^localhost/bench-$arm:" || true
