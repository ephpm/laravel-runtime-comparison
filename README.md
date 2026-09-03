<img width="1024" height="572" alt="image" src="https://github.com/user-attachments/assets/4a891a09-b66a-4d33-b27a-b8071bff6474" />

# Laravel Runtime Benchmark

This repository provides a repeatable benchmark for one Laravel application running on eight PHP server setups:

1. FrankenPHP (Laravel Octane, worker mode)

2. Swoole

3. OpenSwoole

4. RoadRunner

5. Nginx with PHP FPM

6. ePHPm in per-request mode

7. ePHPm in persistent worker mode

8. FrankenPHP in classic mode (its default, non-worker mode)

The two ePHPm entries and `frankenphp-classic` are additions in this fork. See
`RESULTS-EPHPM.md` for how they are configured, what had to be relaxed to
install the Octane driver, and the recorded runs.

Every setup uses the same Laravel source, Composer lock file, database schema, seed data, endpoints, worker count, and OPcache configuration. Docker base images are pinned with digest values so that a later build does not silently pull a different image.

## Requirements

For Docker based benchmark runs:

1. Docker Engine with Docker Compose v2

2. `curl`

3. `wrk`

For local Laravel tests and chart generation:

1. PHP 8.4 or a compatible PHP version

2. Composer 2

3. Python 3

Docker Desktop must be running before starting a benchmark.

## Local setup

Install the Laravel dependencies before running the local test suite:

```bash
cd app
composer install
cd ..
```

The Docker build installs the same locked dependencies inside each runtime image, so local setup is not required for Docker image creation.

## Repository layout

```text
app/                  Laravel application and Composer files
bench/run.sh          Benchmark runner
bench/smoke.sh        Docker Compose configuration checks
bench/summarize.sh    Raw output parser and summary generator
bench/select-ephpm-binary.sh
                      Chooses which ephpm binary the two ePHPm images run
bench/generate-charts.py
                      SVG chart generator
runtimes/             Dockerfiles and Compose files for each setup
docs/                 Written documentation and generated charts
results/              Benchmark output grouped by run ID
```

## Runtime setup

The FrankenPHP, Swoole, OpenSwoole, and RoadRunner setups use Laravel Octane with two application workers.

The Nginx setup uses Nginx in front of PHP FPM with two static PHP FPM children.

The `frankenphp-classic` setup runs the **same** pinned FrankenPHP image in its
default, non-worker mode: a Caddyfile with `php_server` and no worker script, so
every request pays a full PHP request startup, Laravel bootstrap, and shutdown.
It belongs in the same class as Nginx with PHP FPM, not next to `frankenphp`.
Its two concurrent PHP executions come from `num_threads 2` — in classic mode a
FrankenPHP thread runs one request at a time, so the thread count is the
concurrency cap. See `runtimes/frankenphp-classic/Caddyfile`.

The `ephpm` setup runs ePHPm in its per-request mode with two concurrent PHP
execution slots, which is ePHPm's equivalent of `pm.max_children = 2`. It runs a
full PHP request startup and shutdown per request, so it belongs in the same
class as the Nginx with PHP FPM setup.

The `ephpm-worker` setup runs ePHPm in persistent worker mode with two workers,
driven by Laravel Octane through the `ephpm/octane-driver` package. It boots the
framework once per worker, so it belongs in the same class as the four Octane
setups.

Both ePHPm setups build `FROM` the published `ephpm/ephpm:v0.9.0-php8.4` image,
use stock `pdo_sqlite` against the same seeded database file as every other
runtime, and pin the same OPcache directives as `runtimes/php.ini`. ePHPm's
embedded Turso database engine is deliberately not used, so the storage path
stays identical across all eight setups.

Which ePHPm binary those two images actually run is chosen by
`bench/select-ephpm-binary.sh`, whose output both Dockerfiles copy over
`/usr/local/bin/ephpm` as their last layer:

```bash
bash bench/select-ephpm-binary.sh published            # the base image's own binary
bash bench/select-ephpm-binary.sh /path/to/built/ephpm # a locally built binary
```

`published` copies the base image's binary back over itself, so the image is
byte-equivalent to using the published image unmodified. Everything else about
the image is identical either way, which makes "which ephpm build" a
single-variable comparison. See `RESULTS-EPHPM.md`.

Because ePHPm links PHP into its own binary and ships no separate `php` or
`composer` executable, both ePHPm images build the Laravel vendor tree and the
seeded database in a build stage that uses the same pinned `php:8.4-cli-alpine`
and Composer digests as the Swoole, OpenSwoole, and RoadRunner images.

All setups enable OPcache. JIT is disabled in the shared PHP configuration. The application is seeded with 100 users and 1,000 products in a SQLite database during the Docker image build.

The runtime Dockerfiles copy the same `app/composer.json` and `app/composer.lock` files. This keeps the Laravel dependency set identical across all images.

## Benchmark profiles

All four `/api/*` routes are declared in `routes/web.php`, so they carry the
`web` middleware group and its `StartSession`. With the session and cache stores
that `app/.env.example` ships — `SESSION_DRIVER=database` and
`CACHE_STORE=database` on top of `DB_CONNECTION=sqlite` — every request performs
a SQLite write. SQLite serializes writers behind one global write lock, so all
seven runtimes queue behind the same lock and the suite mostly measures that
lock rather than the runtimes.

`BENCH_PROFILE` selects which configuration the images are built with. All four
are committed; none requires editing a file.

| `BENCH_PROFILE` | Session driver | Cache store | What the suite then measures |
| --- | --- | --- | --- |
| `upstream` (default) | `database` | `database` | The SQLite session-write lock, shared by every runtime |
| `runtime` | `array` | `array` | The runtimes. `/api/db` still runs its four real SQLite queries |
| `file-sessions` | `file` | `array` | Session persistence *without* a global lock |
| `redis-sessions` | `redis` | `array` | What production Laravel actually runs |

`DB_CONNECTION` stays `sqlite` in all four.

`array` alone cannot tell "SQLite serializes every writer" apart from "persisting
a session costs something", because `array` persists nothing at all. That is what
`file-sessions` is for: the session is still written to disk on every request,
but the file driver locks per session id, so there is no single lock every
request queues behind. It is the control that makes the lock claim falsifiable —
if `file` were as slow as `database`, the cost would be persistence rather than
locking.

`redis-sessions` answers a different question and is **not** a clean isolation of
the lock: it adds a network round trip per request and a second container
competing for the same cores. It is here because it is the realistic production
choice, not because it is the controlled one. Cache is `array` in both new
profiles so the session driver is the only thing that varies between them and
`runtime`.

Two things about `redis-sessions` are deliberate and worth knowing before
comparing its numbers to anything:

- It uses **predis** (a pure-PHP client) rather than the `phpredis` extension.
  ePHPm links its own ZTS PHP and cannot load an extension built against another
  PHP build, so `phpredis` cannot be installed on every arm. One client on every
  arm keeps the arms comparable; the cost is that these are a lower bound on what
  Redis sessions can do, since `phpredis` is faster than `predis`.
- The vendor tree for this profile therefore contains one package the other three
  do not. No other profile's image changes.

Laravel's `redis` session driver routes through the Redis **cache** store, so its
keys carry the cache prefix (`laravel-database-laravel-cache-…`) and land in the
default connection's database, not `REDIS_CACHE_DB`. That is Laravel's behaviour,
not a misconfiguration, and it is why the sidecar's `DBSIZE` is a valid count of
sessions written.

The measured difference is large. On the host described in `RESULTS-EPHPM.md`,
moving from `runtime` to `upstream` took FrankenPHP from 1,863 to 116 req/s and
ePHPm worker mode from 2,147 to 30-70 req/s, and under `upstream` throughput
stops scaling with concurrency at all (130 req/s at one connection, 197 req/s at
one hundred) — the signature of a serialized resource rather than slow request
handling. Under `upstream` every runtime lands in the same narrow 95-165 req/s
band, so that profile cannot separate them. It is still a *fair* comparison,
because the bottleneck is identical for every runtime; it is just a measurement
of the session store.

```bash
BENCH_PROFILE=upstream       bash bench/run.sh all   # the harness as it ships
BENCH_PROFILE=runtime        bash bench/run.sh all   # the runtimes
BENCH_PROFILE=file-sessions  bash bench/run.sh all   # persistence, no global lock
BENCH_PROFILE=redis-sessions bash bench/run.sh all   # the production choice
```

`redis-sessions` needs the Redis sidecar, which the Compose files declare behind
a Compose profile so it never starts for the other three. `bench/run.sh` enables
it automatically by setting `COMPOSE_PROFILES=redis` when that profile is
selected. The sidecar is pinned by digest like every other image in the suite and
runs stock — no tuning, and no persistence changes in either direction.

To measure the *shape* of throughput against concurrency rather than a single
100-connection point, use `bench/session-sweep.sh`, which walks a connection
ladder across session drivers on one arm and one endpoint:

```bash
RUN_ID=tier1 DURATION=25s REPEATS=3 bash bench/session-sweep.sh array file database redis
python3 bench/sweep-table.py results/tier1
```

That script gives every cell a **fresh container** on purpose. `wrk` never sends
a cookie back, so every request mints a new session id and the store grows by one
entry per request; reusing a container would start the 100-connection cell
against a store holding a million rows the 1-connection cell never saw, and any
flattening could then be blamed on store growth rather than on locking.

`BENCH_PROFILE` is a **build-time** selection, not a run-time one. Laravel bakes
`session.driver` and `cache.default` into `bootstrap/cache/config.php` when
`php artisan config:cache` runs during the image build, so an image serves
whatever profile it was built with regardless of its environment. Switching
profiles therefore rebuilds the images; the Compose files pass `BENCH_PROFILE`
through as a Docker build argument and the Dockerfiles map it onto
`SESSION_DRIVER` and `CACHE_STORE` before `config:cache` runs.

Because an image's profile is invisible at run time, `bench/run.sh` reads the
compiled config cache out of each running container into
`results/<run-id>/<runtime>/run-N/app-config.txt`:

```text
session.driver=array cache.default=array db.default=sqlite
```

If that does not match the requested `BENCH_PROFILE`, the run **aborts** instead
of recording numbers. This matters because a profile mismatch does not look like
a configuration bug: every runtime collapses together, so the comparison still
looks internally fair, and a control runtime rebuilt in the same pass collapses
with the subject, which reads as a dead host. Always read `app-config.txt`, not
the source tree, when deciding what a recorded number measured.

## Endpoints

The benchmark tests four HTTP endpoints:

1. `GET /api/health` returns an empty 204 response.

2. `GET /api/static` returns a small JSON response.

3. `GET /api/db` runs four SQLite queries. It counts users and active products, calculates inventory value, and loads 20 products.

4. `GET /api/cpu` performs 1,000 deterministic calculations and returns a fixed checksum.

Each endpoint is warmed up before the measured requests begin.

## Checks and tests

Validate every Docker Compose file:

```bash
make smoke
```

Run the Laravel test suite from the `app` directory:

```bash
make test
```

The Docker benchmark also performs a readiness check and a small endpoint check before every runtime session.

## Running a benchmark

Run all runtimes with the default settings, which is `BENCH_PROFILE=upstream`:

```bash
make bench
```

The runner accepts one runtime, `all`, or a class name:

```bash
bash bench/run.sh frankenphp
bash bench/run.sh swoole
bash bench/run.sh openswoole
bash bench/run.sh roadrunner
bash bench/run.sh nginx-fpm
bash bench/run.sh ephpm
bash bench/run.sh ephpm-worker
bash bench/run.sh frankenphp-classic
bash bench/run.sh all
```

The two class names measure one class, rotated and interleaved among its members
exactly as `all` is. Worker and per-request results are not comparable to each
other, so re-recording one class alone is a normal thing to want, and doing it
through the runner keeps the rotation, the cooldowns, and the profile check that
a hand-written loop loses:

```bash
bash bench/run.sh per-request   # nginx-fpm, ephpm, frankenphp-classic
bash bench/run.sh worker        # frankenphp, swoole, openswoole, roadrunner, ephpm-worker
```

The runner and the smoke check use Docker Compose v2 by default. To run the
suite under another OCI engine, set `COMPOSE_CMD`:

```bash
COMPOSE_CMD="podman compose" bash bench/run.sh all
```

The runner supports these environment variables:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `ROUNDS` | `3` | Number of complete rounds |
| `DURATION` | `30s` | Duration of each `wrk` measurement |
| `THREADS` | `10` | Number of `wrk` threads |
| `CONNECTIONS` | `100` | Number of open connections |
| `TIMEOUT` | `5s` | `wrk` request timeout |
| `WARMUP_REQUESTS` | `100` | Warm up requests per endpoint |
| `ENDPOINT_COOLDOWN` | `0` | Seconds between endpoint measurements in one runtime session |
| `COOLDOWN` | `900` | Seconds between runtime sessions |
| `INITIAL_COOLDOWN` | Value of `COOLDOWN` | Seconds to wait after image preparation |
| `RUN_ID` | Current UTC timestamp | Directory name under `results/` |
| `BENCH_PROFILE` | `upstream` | Session/cache stores the images are built with: `upstream` (`database`/`database`), `runtime` (`array`/`array`), `file-sessions` (`file`/`array`) or `redis-sessions` (`redis`/`array`). See "Benchmark profiles" |
| `SKIP_BUILD` | `0` | `1` measures whatever image is already tagged instead of rebuilding. The `BENCH_PROFILE` check still runs |

For a schedule with a 10 minute initial wait, 4 minute endpoint breaks, and 5 minute runtime breaks:

```bash
ROUNDS=3 \
ENDPOINT_COOLDOWN=240 \
COOLDOWN=300 \
INITIAL_COOLDOWN=600 \
bash bench/run.sh all
```

Only one runtime is active at a time. The runner stops its containers after each session. With `all`, the runtime order rotates between rounds. The endpoint order rotates as well, so the same endpoint does not always run in the same position.

The runner waits between endpoint measurements only when `ENDPOINT_COOLDOWN` is greater than zero. It waits between runtime sessions when `COOLDOWN` is greater than zero. There is no extra wait after the last scheduled session because no later measurement needs to use that cooldown.

## Benchmark output

Each run is saved under `results/<run-id>`.

The main files are:

```text
settings.txt       Benchmark parameters, the benchmark profile, and timestamps
schedule.csv       Runtime order and endpoint order
metrics.csv        One parsed row per runtime, endpoint, and round
summary.csv        Averages, standard deviation, ranges, P99, and timeouts
```

Each `run-N` folder also holds `app-config.txt`, the session, cache, and
database drivers read out of that container's compiled config cache. It is the
only run-time evidence of which benchmark profile produced a number.

Each runtime also gets a directory with one `run-N` folder per round. These folders contain the raw `wrk` output for every endpoint, runtime metadata, image information, readiness output, and timestamps.

The runner creates `metrics.csv` and `summary.csv` automatically when the scheduled sessions finish. To rebuild summaries from an existing run:

```bash
bash bench/summarize.sh <run-id>
```

Do not summarize an incomplete run. Aborted runs should remain separate from complete runs.

## Generating charts

Charts are generated from a run's `summary.csv` file:

```bash
make charts RUN_ID=<run-id>
```

The SVG files are written to `docs/charts`:

```text
db-throughput.svg
health-throughput.svg
static-throughput.svg
cpu-throughput.svg
tail-latency.svg
```

The throughput charts show the three run average and the lowest and highest run. The latency chart shows the average P99 latency for each endpoint. Chart generation requires at least three completed runs for every runtime and endpoint.

## Reproducibility notes

The benchmark is designed to compare runtime configurations, not to predict production capacity for every server. Results can change with the host processor, operating system, Docker version, background tasks, database engine, worker count, and traffic pattern.

For a thermal controlled comparison, keep the room conditions stable and use the cooldown variables consistently for every runtime. A schedule with endpoint breaks measures separate traffic bursts. A sustained load test without breaks answers a different question and should be treated as a separate benchmark.

Results from the two benchmark profiles are not comparable with each other and
should never be mixed in one table. `BENCH_PROFILE=upstream` and
`BENCH_PROFILE=runtime` measure different bottlenecks, which is the point of
having both. Every recorded run states its profile in `settings.txt`, and each
round proves it in `app-config.txt`.
