FROM php:8.4-cli-alpine@sha256:26e3f1de7f6aa3e8ea15584d803c5e088c57df89ff02a3ecf2dc855a4282d8d7

WORKDIR /var/www/html

COPY --from=mlocati/php-extension-installer:2@sha256:b6d3fa381b9ba5cf051117c1c601d6a523b590e534bf3d56eb4fbe352949c138 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pdo_sqlite opcache pcntl sockets swoole

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

EXPOSE 8000
CMD ["php", "artisan", "octane:start", "--server=swoole", "--host=0.0.0.0", "--port=8000", "--workers=2", "--task-workers=0"]
