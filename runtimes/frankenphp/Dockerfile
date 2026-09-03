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

COPY runtimes/php.ini /usr/local/etc/php/conf.d/benchmark.ini

EXPOSE 8000
CMD ["php", "artisan", "octane:start", "--server=frankenphp", "--host=0.0.0.0", "--port=8000", "--workers=2"]
