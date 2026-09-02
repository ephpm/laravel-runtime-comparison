# ePHPm in classic per-request mode (its "fpm" engine): every request runs a
# full PHP request startup/shutdown cycle, so this image belongs in the same
# class as the Nginx + PHP FPM setup, not with the Octane runtimes.
#
# ePHPm ships as a single static binary with PHP 8.4 embedded and carries no
# composer or standalone php CLI, so the Laravel vendor tree and the seeded
# SQLite database are produced in a build stage that uses the exact same pinned
# php:8.4-cli-alpine and composer digests as the Swoole, OpenSwoole, and
# RoadRunner images. The dependency set and seed data are therefore identical.
FROM php:8.4-cli-alpine@sha256:26e3f1de7f6aa3e8ea15584d803c5e088c57df89ff02a3ecf2dc855a4282d8d7 AS build

WORKDIR /var/www/html

COPY --from=mlocati/php-extension-installer:2@sha256:b6d3fa381b9ba5cf051117c1c601d6a523b590e534bf3d56eb4fbe352949c138 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pdo_sqlite opcache pcntl sockets
COPY --from=composer:2@sha256:4d71c3c2109c61d5415544264b59ad4087e4c5b7244481723664138fd36d5040 /usr/bin/composer /usr/bin/composer
COPY app/composer.json app/composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts

COPY app/ ./
RUN rm -f bootstrap/cache/*.php \
    && cp .env.example .env \
    && php artisan key:generate --force \
    && touch database/database.sqlite \
    && php artisan migrate --force --seed \
    && php artisan config:cache \
    && chmod -R ug+rwx storage bootstrap/cache

FROM ephpm/ephpm:v0.8.7-php8.4

WORKDIR /var/www/html

COPY --from=build /var/www/html /var/www/html
COPY runtimes/ephpm/ephpm.toml /etc/ephpm/ephpm.toml
RUN chmod -R a+rwX storage bootstrap/cache database

# The ephpm binary under test, overwriting the one the base image ships. See
# the same block in runtimes/ephpm-worker/Dockerfile. PR #443 touches
# fpm_pool.rs as well as worker_pool.rs, so this per-request entry is on the
# same dispatch-admission path as the worker entry.
# Populate runtimes/ephpm-bin/ephpm with bench/select-ephpm-binary.sh.
COPY runtimes/ephpm-bin/ephpm /usr/local/bin/ephpm

EXPOSE 8000
CMD ["ephpm", "serve", "--config", "/etc/ephpm/ephpm.toml"]
