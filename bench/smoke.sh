#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for runtime in frankenphp swoole openswoole roadrunner nginx-fpm; do
  docker compose -f "$ROOT_DIR/runtimes/$runtime/docker-compose.yml" config --quiet
  printf 'valid: %s\n' "$runtime"
done
