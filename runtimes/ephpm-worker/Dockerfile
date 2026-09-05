# ePHPm in persistent worker mode, driven by Laravel Octane through
# ephpm/octane-driver.
#
# ePHPm ships as a single binary with PHP linked in, so its published image has
# no PHP CLI and no Composer. The vendor tree and the seeded SQLite database are
# therefore produced in a build stage on the same pinned php:8.4-cli-alpine and
# composer digests the Swoole, OpenSwoole, and RoadRunner images use, and copied
# into the ePHPm image. The build steps below are the same ones the other
# runtimes run, in the same order.
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

# The Octane driver for ePHPm. This is the only place where this image's
# dependency set differs from the shared app/composer.lock.
#
# ePHPm's PHP packages are published through their GitHub repositories rather
# than Packagist, so they are added as Composer `vcs` repositories. Two entries
# are required because Composer does not resolve VCS repositories transitively:
# ephpm/octane-driver depends on ephpm/worker, which is also GitHub hosted.
# Both are MIT licensed and version pinned here.
RUN composer config repositories.ephpm-octane-driver vcs https://github.com/ephpm/octane-driver \
    && composer config repositories.ephpm-worker vcs https://github.com/ephpm/php-worker \
    && composer require ephpm/octane-driver:0.1.2 \
        --no-interaction --prefer-dist --optimize-autoloader --no-scripts --update-no-dev \
    && cp vendor/ephpm/octane-driver/bin/ephpm-octane-worker public/ephpm-octane-worker.php

FROM ephpm/ephpm:v0.9.1-php8.4@sha256:b7c2b70a7e73b1962e8e6a0d7266793ea1967e06fb8dca19ea75bd1637b8289b

WORKDIR /var/www/html

COPY --from=build /var/www/html /var/www/html
COPY runtimes/ephpm-worker/ephpm.toml /etc/ephpm/ephpm.toml

# The Octane entrypoint locates bootstrap/app.php by searching upward from the
# working directory; pinning the base directory removes the search.
ENV EPHPM_APP_BASE=/var/www/html

# PHP is linked into the ephpm binary and reached as `ephpm php`, so the image
# has no separate `php` executable. This shim lets bench/run.sh collect the same
# `php -v` / `php -m` / `php --ri` metadata here as it does for every other
# runtime, without a special case in the runner. The captured OPcache block is
# the CLI's view; the server's effective settings come from ephpm.toml and are
# logged at startup.
RUN printf '#!/bin/sh\nexec ephpm php "$@"\n' > /usr/local/bin/php \
    && chmod +x /usr/local/bin/php

EXPOSE 8000
CMD ["ephpm", "serve", "--config", "/etc/ephpm/ephpm.toml"]
