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

COPY app/ ./
RUN rm -f bootstrap/cache/*.php \
    && cp .env.example .env \
    && php artisan key:generate --force \
    && touch database/database.sqlite \
    && php artisan migrate --force --seed \
    && php artisan config:cache \
    && chmod -R ug+rwx storage bootstrap/cache

# Add the ePHPm worker packages on top of the shared dependency set, then put
# the driver's Octane worker entrypoint inside the document root, which is
# where ePHPm's config validation requires worker_script to resolve.
COPY runtimes/ephpm-worker/composer-ephpm.json runtimes/ephpm-worker/merge-composer.php /tmp/
RUN php /tmp/merge-composer.php composer.json /tmp/composer-ephpm.json \
    && composer update ephpm/octane-driver ephpm/worker \
        --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts \
    && cp vendor/ephpm/octane-driver/bin/ephpm-octane-worker public/ephpm-octane-worker.php

FROM ephpm/ephpm:v0.8.7-php8.4

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
