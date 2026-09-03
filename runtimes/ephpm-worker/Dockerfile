# ePHPm in persistent worker mode, driven by Laravel Octane through
# ephpm/octane-driver. This is the worker-class ePHPm entry and is the one
# comparable to the FrankenPHP, Swoole, OpenSwoole, and RoadRunner images.
#
# As with runtimes/ephpm, the vendor tree and the seeded SQLite database are
# produced in a build stage on the same pinned php:8.4-cli-alpine and composer
# digests the other runtimes use, because the ePHPm image ships only a single
# static binary with PHP 8.4 embedded.
#
# This image is the one place where the dependency set intentionally differs
# from the shared composer.lock: it additionally installs ephpm/octane-driver
# and ephpm/worker. See runtimes/ephpm-worker/composer-ephpm.json for the exact
# overlay and why the packages are declared inline.
FROM php:8.4-cli-alpine@sha256:26e3f1de7f6aa3e8ea15584d803c5e088c57df89ff02a3ecf2dc855a4282d8d7 AS build

WORKDIR /var/www/html

COPY --from=mlocati/php-extension-installer:2@sha256:b6d3fa381b9ba5cf051117c1c601d6a523b590e534bf3d56eb4fbe352949c138 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pdo_sqlite opcache pcntl sockets zip
COPY --from=composer:2@sha256:4d71c3c2109c61d5415544264b59ad4087e4c5b7244481723664138fd36d5040 /usr/bin/composer /usr/bin/composer
COPY app/composer.json app/composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts

# Which session and cache store this image is built with. Laravel bakes both
# into bootstrap/cache/config.php at build time via `php artisan config:cache`,
# so unlike WORKER_BACKLOG this cannot be a run-time environment override -- it
# has to be chosen when the image is built, and an image runs whatever it was
# built with.
#
#   upstream (default) -- database sessions and cache, which is exactly what
#     app/.env.example ships. On top of DB_CONNECTION=sqlite that puts a SQLite
#     write on every request, and SQLite serializes writers, so all seven
#     runtimes queue behind one lock. The suite then measures the lock.
#   runtime -- array sessions and cache. Removes the shared lock so the suite
#     measures the runtimes. /api/db still runs its four real SQLite queries.
#   file-sessions -- file sessions, array cache. The control that separates
#     "SQLite's global writer lock" from "persisting a session costs
#     something at all": the session is still written to disk on every
#     request, but the file driver locks per session id, so there is no one
#     lock every request has to queue behind.
#   file-sessions-nogc -- file sessions with Laravel's session GC lottery
#     turned off (`session.lottery` [2,100] -> [0,100]). A DIAGNOSTIC, not a
#     configuration anyone should run: it exists only to attribute the file
#     driver's cost. Laravel's file GC scans the whole session directory, and
#     because `wrk` sends no cookie every request creates a new session file,
#     so that directory grows by tens of thousands of files inside a single
#     measurement window and the scan gets steadily more expensive. Without
#     this leg there is no way to tell that cost apart from the per-request
#     write, and `file` is the control the whole lock argument leans on.
#   redis-sessions -- redis sessions, array cache. What production Laravel
#     actually runs. Deliberately NOT a clean isolation of the lock: it adds a
#     network round trip per request and a second container competing for the
#     same cores, so it answers "what should this app use" rather than "what
#     is the lock costing". Uses predis (pure PHP) rather than the phpredis
#     extension, because ePHPm links its own ZTS PHP and cannot load an
#     extension built against another PHP; one client on every arm keeps the
#     arms comparable, at the cost of some absolute Redis throughput.
#
# Cache is array in both new profiles, so the session driver is the only thing
# that differs between them and `runtime`. See README.md, "Benchmark profiles".
ARG BENCH_PROFILE=upstream

COPY app/ ./
RUN set -eu; \
    case "$BENCH_PROFILE" in \
      upstream) bench_session=database; bench_cache=database ;; \
      runtime) bench_session=array; bench_cache=array ;; \
      file-sessions) bench_session=file; bench_cache=array ;; \
      file-sessions-nogc) bench_session=file; bench_cache=array; disable_gc=1 ;; \
      redis-sessions) bench_session=redis; bench_cache=array ;; \
      *) echo "BENCH_PROFILE must be upstream, runtime, file-sessions, file-sessions-nogc or redis-sessions, got: $BENCH_PROFILE" >&2; exit 1 ;; \
    esac; \
    if [ "${disable_gc:-0}" = 1 ]; then \
      sed -i "s/'lottery' => \[2, 100\]/'lottery' => [0, 100]/" config/session.php; \
      grep -q "'lottery' => \[0, 100\]" config/session.php; \
    fi; \
    if [ "$bench_session" = redis ]; then \
      composer require predis/predis --no-interaction --no-scripts --update-no-dev --optimize-autoloader; \
    fi; \
    rm -f bootstrap/cache/*.php; \
    cp .env.example .env; \
    sed -i -e "s/^SESSION_DRIVER=.*/SESSION_DRIVER=$bench_session/" \
           -e "s/^CACHE_STORE=.*/CACHE_STORE=$bench_cache/" .env; \
    printf 'REDIS_CLIENT=predis\nREDIS_HOST=redis\nREDIS_PORT=6379\n' >> .env; \
    php artisan key:generate --force; \
    touch database/database.sqlite; \
    php artisan migrate --force --seed; \
    php artisan config:cache; \
    chmod -R ug+rwx storage bootstrap/cache

# Add the ePHPm worker packages on top of the shared dependency set, then put
# the driver's Octane worker entrypoint inside the document root, which is
# where ePHPm's config validation requires worker_script to resolve.
COPY runtimes/ephpm-worker/composer-ephpm.json runtimes/ephpm-worker/merge-composer.php /tmp/
RUN php /tmp/merge-composer.php composer.json /tmp/composer-ephpm.json \
    && composer update ephpm/octane-driver ephpm/worker \
        --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts \
    && cp vendor/ephpm/octane-driver/bin/ephpm-octane-worker public/ephpm-octane-worker.php

FROM ephpm/ephpm:v0.9.0-php8.4

WORKDIR /var/www/html

COPY --from=build /var/www/html /var/www/html
COPY runtimes/ephpm-worker/ephpm.toml /etc/ephpm/ephpm.toml
RUN chmod -R a+rwX storage bootstrap/cache database

# The ephpm binary under test, overwriting the one the base image ships.
# Nothing else about the image changes -- same debian:12-slim base, same
# layers, same entrypoint -- so the binary is the only variable between the
# "before" and "after" legs of the second recording. Last layer on purpose:
# swapping it rebuilds one small layer, not the vendor tree above it.
# Populate runtimes/ephpm-bin/ephpm with bench/select-ephpm-binary.sh.
COPY runtimes/ephpm-bin/ephpm /usr/local/bin/ephpm

EXPOSE 8000
CMD ["ephpm", "serve", "--config", "/etc/ephpm/ephpm.toml"]
