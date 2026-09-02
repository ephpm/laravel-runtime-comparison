#!/usr/bin/env bash
# Put an ephpm binary at runtimes/ephpm-bin/ephpm, which both ePHPm images
# COPY over the one their base image ships.
#
# The two ePHPm images are built FROM a published ephpm release image and then
# overwrite /usr/local/bin/ephpm with this file. Selecting "published" copies
# the base image's own binary back over itself, so the resulting image is
# byte-equivalent to using the published image unmodified. That is what makes a
# before/after comparison honest: the Dockerfiles, the layers, the vendor tree,
# the config and the entrypoint are identical in both legs, and the binary is
# the only thing that differs.
#
# Usage:
#   bench/select-ephpm-binary.sh published
#   bench/select-ephpm-binary.sh /path/to/locally/built/ephpm
#
# Set ENGINE to use something other than podman.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ENGINE:-podman}"
BASE_IMAGE="${BASE_IMAGE:-ephpm/ephpm:v0.8.7-php8.4}"
DEST="$ROOT_DIR/runtimes/ephpm-bin/ephpm"

source="${1:?Usage: $0 published|/path/to/ephpm}"

mkdir -p "$(dirname "$DEST")"

if [[ "$source" == "published" ]]; then
  container="$("$ENGINE" create "$BASE_IMAGE" true)"
  trap '"$ENGINE" rm -f "$container" >/dev/null 2>&1 || true' EXIT
  "$ENGINE" cp "$container:/usr/local/bin/ephpm" "$DEST"
  printf 'selected: %s from %s\n' "$DEST" "$BASE_IMAGE"
else
  [[ -r "$source" ]] || { printf 'not readable: %s\n' "$source" >&2; exit 1; }
  cat "$source" > "$DEST"
  printf 'selected: %s from %s\n' "$DEST" "$source"
fi

chmod +x "$DEST"
ls -l "$DEST"
sha256sum "$DEST"
