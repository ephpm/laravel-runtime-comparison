# Laravel Runtime Benchmark

This repository provides a repeatable benchmark for one Laravel application running on five PHP server setups:

1. FrankenPHP

2. Swoole

3. OpenSwoole

4. RoadRunner

5. Nginx with PHP FPM

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
bench/generate-charts.py
                      SVG chart generator
runtimes/             Dockerfiles and Compose files for each setup
docs/                 Written documentation and generated charts
results/              Benchmark output grouped by run ID
```

## Runtime setup

The FrankenPHP, Swoole, OpenSwoole, and RoadRunner setups use Laravel Octane with two application workers.

The Nginx setup uses Nginx in front of PHP FPM with two static PHP FPM children.

All setups enable OPcache. JIT is disabled in the shared PHP configuration. The application is seeded with 100 users and 1,000 products in a SQLite database during the Docker image build.

The runtime Dockerfiles copy the same `app/composer.json` and `app/composer.lock` files. This keeps the Laravel dependency set identical across all images.

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

Run the default benchmark profile for all runtimes:

```bash
make bench
```

The runner accepts one runtime or `all`:

```bash
bash bench/run.sh frankenphp
bash bench/run.sh swoole
bash bench/run.sh openswoole
bash bench/run.sh roadrunner
bash bench/run.sh nginx-fpm
bash bench/run.sh all
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

For a profile with a 10 minute initial wait, 4 minute endpoint breaks, and 5 minute runtime breaks:

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
settings.txt       Benchmark parameters and timestamps
schedule.csv       Runtime order and endpoint order
metrics.csv        One parsed row per runtime, endpoint, and round
summary.csv        Averages, standard deviation, ranges, P99, and timeouts
```

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

For a thermal controlled comparison, keep the room conditions stable and use the cooldown variables consistently for every runtime. A profile with endpoint breaks measures separate traffic bursts. A sustained load test without breaks answers a different question and should be treated as a separate benchmark.
