#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Container engine. Defaults to Docker Compose v2. Set COMPOSE_CMD to run the
# suite under a different engine, for example COMPOSE_CMD="podman compose".
read -r -a COMPOSE <<< "${COMPOSE_CMD:-docker compose}"

for runtime in frankenphp swoole openswoole roadrunner nginx-fpm ephpm ephpm-worker frankenphp-classic; do
  "${COMPOSE[@]}" -f "$ROOT_DIR/runtimes/$runtime/docker-compose.yml" config --quiet
  printf 'valid: %s\n' "$runtime"
done
