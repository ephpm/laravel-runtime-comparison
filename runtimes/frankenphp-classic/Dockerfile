# FrankenPHP in classic (non-worker) mode: `php_server` with no worker script,
# so every request pays a full PHP request startup, Laravel bootstrap, and
# shutdown. That puts this image in the same class as Nginx + PHP FPM and ePHPm
# per-request, NOT with runtimes/frankenphp, which runs the same binary under
# Laravel Octane and keeps the framework resident.
#
# Classic is FrankenPHP's default mode -- it is what `frankenphp run` does with
# the Caddyfile the image ships. Upstream's suite only ever measured FrankenPHP
# under Octane, so the mode most people actually run it in was never recorded.
#
# Every layer below except the Caddyfile and the CMD is byte-for-byte the same
# as runtimes/frankenphp/Dockerfile: same pinned FrankenPHP digest, same
# extensions, same pinned Composer digest, same composer.lock, same app, same
# BENCH_PROFILE handling, same runtimes/php.ini.
FROM dunglas/frankenphp:php8.4-alpine@sha256:3354314945be903be25ae88aa1d7de7eaebc7f244c9017d4005f60746bd35084

WORKDIR /var/www/html

RUN install-php-extensions pdo_sqlite opcache pcntl sockets \
    && docker-php-source delete

COPY app/composer.json app/composer.lock ./
COPY --from=composer:2@sha256:4d71c3c2109c61d5415544264b59ad4087e4c5b7244481723664138fd36d5040 /usr/bin/composer /usr/bin/composer
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts

# Which session and cache store this image is built with. Laravel bakes both
# into bootstrap/cache/config.php at build time via `php artisan config:cache`,
# so unlike WORKER_BACKLOG this cannot be a run-time environment override -- it
# has to be chosen when the image is built, and an image runs whatever it was
# built with.
#
#   upstream (default) -- database sessions and cache, which is exactly what
#     app/.env.example ships. On top of DB_CONNECTION=sqlite that puts a SQLite
#     write on every request, and SQLite serializes writers, so all runtimes
#     queue behind one lock. The suite then measures the lock.
#   runtime -- array sessions and cache. Removes the shared lock so the suite
#     measures the runtimes. /api/db still runs its four real SQLite queries.
#
# Nothing else differs between the two. See README.md, "Benchmark profiles".
ARG BENCH_PROFILE=upstream

COPY app/ ./
RUN set -eu; \
    case "$BENCH_PROFILE" in \
      upstream) bench_store=database ;; \
      runtime) bench_store=array ;; \
      *) echo "BENCH_PROFILE must be upstream or runtime, got: $BENCH_PROFILE" >&2; exit 1 ;; \
    esac; \
    rm -f bootstrap/cache/*.php; \
    cp .env.example .env; \
    sed -i -e "s/^SESSION_DRIVER=.*/SESSION_DRIVER=$bench_store/" \
           -e "s/^CACHE_STORE=.*/CACHE_STORE=$bench_store/" .env; \
    php artisan key:generate --force; \
    touch database/database.sqlite; \
    php artisan migrate --force --seed; \
    php artisan config:cache; \
    chmod -R ug+rwx storage bootstrap/cache

COPY runtimes/php.ini /usr/local/etc/php/conf.d/benchmark.ini

# Replaces the image's own Caddyfile in place, so the container starts through
# FrankenPHP's stock entrypoint and stock arguments (see CMD below) rather than
# a bespoke command line.
COPY runtimes/frankenphp-classic/Caddyfile /etc/frankenphp/Caddyfile

EXPOSE 8000
# The base image's own default CMD, restated rather than inherited so that this
# file says what it runs. docker-php-entrypoint turns a leading "-" into
# `frankenphp run "$@"`.
CMD ["--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]
