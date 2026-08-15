FROM dunglas/frankenphp:php8.4-alpine@sha256:3354314945be903be25ae88aa1d7de7eaebc7f244c9017d4005f60746bd35084

WORKDIR /var/www/html

RUN install-php-extensions pdo_sqlite opcache pcntl sockets \
    && docker-php-source delete

COPY app/composer.json app/composer.lock ./
COPY --from=composer:2@sha256:4d71c3c2109c61d5415544264b59ad4087e4c5b7244481723664138fd36d5040 /usr/bin/composer /usr/bin/composer
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts

COPY app/ ./
RUN rm -f bootstrap/cache/*.php \
    && cp .env.example .env \
    && php artisan key:generate --force \
    && touch database/database.sqlite \
    && php artisan migrate --force --seed \
    && php artisan config:cache \
    && chmod -R ug+rwx storage bootstrap/cache

COPY runtimes/php.ini /usr/local/etc/php/conf.d/benchmark.ini

EXPOSE 8000
CMD ["php", "artisan", "octane:start", "--server=frankenphp", "--host=0.0.0.0", "--port=8000", "--workers=2"]
