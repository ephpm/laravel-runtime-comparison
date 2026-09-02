# ePHPm in the Laravel runtime benchmark

This fork adds two [ePHPm](https://github.com/ephpm/ephpm) entries to the
benchmark and records a run of all seven setups. The app, the endpoints, the
`wrk` parameters, and the harness are upstream's; the additions are
`runtimes/ephpm/`, `runtimes/ephpm-worker/`, and the plumbing to list two more
runtimes and to run the suite under a non-Docker engine.

## Verdict

**Worker class.** ePHPm worker mode was the fastest runtime measured, about
19% ahead of FrankenPHP and 27% ahead of Swoole on throughput. It also had the
*worst* tail latency of the fast group: its P99 was roughly 2.5-3x FrankenPHP's.
It wins on throughput and loses on P99, and both halves of that belong in any
honest summary.

**Per-request class.** ePHPm per-request and Nginx + PHP FPM are effectively
tied. ePHPm was ~10% ahead on the database endpoint and ~2-3% behind on the
other three, which is inside the run-to-run noise of a single round.

**The headline caveat.** The benchmark as configured upstream is dominated by a
bottleneck that is not the runtime, and the default numbers therefore separate
the runtimes very poorly. See "Two measurements, and why" below. The verdict
above comes from the supplementary measurement, which is a single round and
carries correspondingly lower confidence.

## Read the two classes separately

| Class | Runtimes | Model |
| --- | --- | --- |
| **Worker** | FrankenPHP, Swoole, OpenSwoole, RoadRunner, **ePHPm worker** | Laravel is booted once per worker and stays resident. All five run Laravel Octane. |
| **Per-request** | Nginx + PHP FPM, **ePHPm per-request** | Every request pays a full PHP request startup, framework bootstrap, and shutdown. |

`ephpm` is a per-request runtime; read it against Nginx with PHP FPM, not
against the Octane runtimes. `ephpm-worker` is the entry that belongs beside the
Octane runtimes, and it gets there through Laravel Octane's own worker loop, so
the framework-side lifecycle is the same code in both cases.

## Two measurements, and why

### Primary run: the harness exactly as upstream ships it

Three rounds, 30s per endpoint, 10 threads, 100 connections, 100 warm-up
requests. This is the run to quote if you want "the upstream harness, unmodified."

It has a problem. Every runtime lands in a narrow 95-165 req/s band, average
latency sits at 650-1000ms, and worker-mode runtimes beat per-request FPM by
only ~1.4x where 3-10x is normal for Octane. Three checks established why:

1. **Throughput does not scale with concurrency.** ePHPm worker served 169
   req/s at one connection and 147 req/s at sixteen. Latency grew linearly while
   throughput stayed flat — the signature of a serialized resource, effective
   parallelism of about 1.
2. **The transport is not the limit.** Plain nginx serving a static file through
   the identical rootless-Podman published-port path did **16,350 req/s**, and
   still did 5,407 req/s when forced to `Connection: close`.
3. **The app writes to SQLite on every request.** `app/.env.example` sets
   `SESSION_DRIVER=database` and `CACHE_STORE=database` on top of
   `DB_CONNECTION=sqlite`, and all four `/api/*` routes are declared in
   `routes/web.php`, so they carry the `web` middleware group and its
   `StartSession`. Every response carries a fresh `laravel-session` cookie.
   SQLite serializes writers with a global write lock, so all seven runtimes
   queue behind the same lock.

That bottleneck is identical for every runtime, so the primary run is *fair*.
It is just mostly a measurement of SQLite session-write contention rather than
of request handling, and the runtime differences in it are small relative to
the shared ceiling.

### Supplementary run: the same harness with the shared lock removed

`SESSION_DRIVER=array` and `CACHE_STORE=array` in `app/.env.example`, all seven
images rebuilt, everything else identical. `DB_CONNECTION` stays `sqlite`, so
`/api/db` still does its four real queries. One round, 20s per endpoint.

This is a deviation from upstream and is **not** committed to the repo —
`app/.env.example` is restored to upstream's values. It is included because it
is the only one of the two runs that actually separates the runtimes.

## Results

### Supplementary run (sessions/cache = array, 1 round x 20s)

#### Worker class — throughput, requests/sec

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| **ePHPm worker (Octane)** | **2,250** | **2,227** | **2,205** | **1,482** |
| FrankenPHP (Octane) | 1,897 | 1,874 | 1,848 | 1,294 |
| OpenSwoole (Octane) | 1,756 | 1,752 | 1,724 | 1,262 |
| Swoole (Octane) | 1,743 | 1,713 | 1,699 | 1,246 |
| RoadRunner (Octane) | 1,274 | 1,230 | 1,221 | 967 |

#### Worker class — P99 latency, ms (lower is better)

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| FrankenPHP (Octane) | **57.8** | **57.2** | **57.6** | **80.3** |
| OpenSwoole (Octane) | 131.7 | 131.2 | 137.7 | 158.6 |
| Swoole (Octane) | 145.2 | 145.0 | 144.1 | 162.5 |
| **ePHPm worker (Octane)** | 156.0 | 157.4 | 160.7 | 201.7 |
| RoadRunner (Octane) | 271.5 | 278.1 | 224.5 | 312.4 |

#### Per-request class — throughput, requests/sec

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| Nginx + PHP FPM | 936 | 929 | 910 | 610 |
| **ePHPm per-request** | 910 | 909 | 901 | **669** |

#### Per-request class — P99 latency, ms (lower is better)

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| Nginx + PHP FPM | **110.2** | **111.5** | **114.1** | **173.0** |
| **ePHPm per-request** | 125.4 | 114.8 | 115.5 | 157.4 |

### Primary run (upstream defaults, 3 rounds x 30s)

Throughput, requests/sec, mean of three rounds with standard deviation. Every
runtime here is queued behind the shared SQLite write lock described above, so
these numbers compress the real differences; the standard deviations are large
enough that most pairs overlap.

| Runtime | Class | health | static | cpu | db |
| --- | --- | ---: | ---: | ---: | ---: |
| RoadRunner | worker | 165 <sub>+/-6</sub> | 155 <sub>+/-8</sub> | 123 <sub>+/-33</sub> | 136 <sub>+/-4</sub> |
| Swoole | worker | 157 <sub>+/-30</sub> | 152 <sub>+/-29</sub> | 150 <sub>+/-14</sub> | 151 <sub>+/-20</sub> |
| OpenSwoole | worker | 154 <sub>+/-18</sub> | 159 <sub>+/-17</sub> | 152 <sub>+/-22</sub> | 141 <sub>+/-13</sub> |
| **ePHPm worker** | worker | 111 <sub>+/-19</sub> | 123 <sub>+/-21</sub> | 127 <sub>+/-12</sub> | 111 <sub>+/-14</sub> |
| FrankenPHP | worker | 119 <sub>+/-9</sub> | 121 <sub>+/-32</sub> | 121 <sub>+/-18</sub> | 111 <sub>+/-13</sub> |
| **ePHPm per-request** | per-request | 125 <sub>+/-4</sub> | 117 <sub>+/-12</sub> | 113 <sub>+/-19</sub> | 111 <sub>+/-25</sub> |
| Nginx + PHP FPM | per-request | 108 <sub>+/-6</sub> | 113 <sub>+/-9</sub> | 112 <sub>+/-18</sub> | 95 <sub>+/-7</sub> |

P99 latency, ms, mean of three rounds:

| Runtime | health | static | cpu | db | timeouts |
| --- | ---: | ---: | ---: | ---: | ---: |
| RoadRunner | 1,230 | 1,437 | 3,597 | 1,303 | 65 |
| **ePHPm per-request** | 1,387 | 1,430 | 2,377 | 2,470 | 8 |
| Nginx + PHP FPM | 1,667 | 1,630 | 1,597 | 1,740 | 0 |
| FrankenPHP | 1,633 | 1,813 | 1,797 | 2,587 | 30 |
| **ePHPm worker** | 2,190 | 2,983 | 2,070 | 2,747 | 12 |
| Swoole | 2,773 | 3,733 | 2,873 | 3,133 | 39 |
| OpenSwoole | 3,113 | 3,143 | 3,017 | 3,070 | 270 |

Note that under this configuration the two ePHPm entries are close to each
other: worker mode's advantage is invisible when every request is waiting on the
same database write lock.

## What was added

Both entries use `ephpm/ephpm:v0.8.7-php8.4`, the newest tag on Docker Hub at
the time of the run, matching the PHP 8.4 minor every other runtime pins.

**`runtimes/ephpm`** — ePHPm's default `fpm` mode with `[php] workers = 2`,
which caps concurrent PHP execution at two and is ePHPm's equivalent of the
`pm.max_children = 2` the Nginx + PHP FPM image uses.

**`runtimes/ephpm-worker`** — ePHPm's `worker` mode with `worker_count = 2`,
matching `--workers=2` on the Octane runtimes. The entrypoint is
`ephpm/octane-driver`, which implements Laravel Octane's `Client` contract and
drives Octane's own `Worker` loop.

## Normalisation

**PHP version.** Every image, including both ePHPm images, runs PHP 8.4.

**Database.** The upstream harness already used SQLite, so nothing had to change
to make storage uniform: all seven runtimes use stock `pdo_sqlite` against a
`database/database.sqlite` seeded at image build with 100 users and 1,000
products.

ePHPm's own embedded database engine (Turso, via litewire's wire-protocol
translation) is deliberately **not** used, and neither is `ephpm/db-laravel`.
This benchmark varies the HTTP request path and holds storage constant.
Measuring ePHPm's embedded database against `pdo_sqlite` is a separate question
needing its own harness, and is not part of these numbers.

**OPcache.** The other six images share `runtimes/php.ini`. ePHPm embeds PHP and
generates its own `php.ini` at startup, so the same directives are set through
ePHPm's typed knobs in `runtimes/ephpm*/ephpm.toml`:
`opcache.memory_consumption=128`, `interned_strings_buffer=16`,
`max_accelerated_files=20000`, `validate_timestamps=0`, JIT disabled with a
zero-byte buffer, `realpath_cache_size=4096K`, `realpath_cache_ttl=600`.
Startup logs confirm each value was applied.

**Memory limit.** `php_memory_limit = "128M"` is pinned explicitly. Left unset,
ePHPm's serve-mode autotuner derives a per-request limit from host RAM and had
selected **1990M** here. That would have handed ePHPm a budget the other
runtimes do not get.

**Vendor tree.** ePHPm ships as a single binary with PHP linked in and carries no
standalone `php` or `composer`, so both ePHPm images build the Laravel vendor
tree and seed the database in a build stage using the same pinned
`php:8.4-cli-alpine` and Composer digests as the Swoole, OpenSwoole, and
RoadRunner images, then copy the result into the ePHPm image.

## Caveats

### The Octane driver needed its framework constraints relaxed

`ephpm/octane-driver` v0.1.1 declares:

```json
"laravel/framework": "^10 || ^11 || ^12",
"symfony/http-foundation": "^6 || ^7"
```

This app resolves `laravel/framework v13.25.0` and
`symfony/http-foundation v8.1.4`, so Composer refuses a plain
`require ephpm/octane-driver`. The `ephpm-worker` image declares both ePHPm
packages as inline Composer `package` repositories that omit those two
constraints (`runtimes/ephpm-worker/composer-ephpm.json`). The driver's code is
used **unmodified from the v0.1.1 tag** — only the declared range is bypassed.

It boots and serves all four endpoints correctly, so the constraint looks stale
rather than describing a real incompatibility. But this is a harness decision,
not an upstream compatibility claim: **as shipped, no Laravel 13 application can
install this driver.** Anyone reproducing the worker numbers is bypassing a
constraint the package author has not yet cleared.

### Host and engine

A developer workstation, not an isolated benchmark rig: AMD Ryzen 9 5950X
(16C/32T), 62 GB RAM, Windows 11 running Podman 5.8.5 with crun inside a WSL2
VM (kernel 6.18.33.2), Compose v5.5.0, `wrk` 4.2.0. `wrk` runs inside the same
WSL2 VM as the containers, over published localhost ports. No CPU pinning — the
upstream harness does not pin and none was added.

Rootless Podman cannot start Compose v5's privileged buildkit container, so
images were built with `DOCKER_BUILDKIT=0`. That affects image construction
only, not the measured request path.

### Deviations from the documented defaults

- **Cooldown.** The runner defaults to `COOLDOWN=900`, which with seven runtimes
  and three rounds is over five hours of waiting. The primary run used
  `COOLDOWN=60`, uniform across all runtimes, with the harness's runtime-order
  and endpoint-order rotation intact.
- **Interrupted and resumed.** The primary run was interrupted after 74 of 84
  measurements. It was resumed with the same `RUN_ID`, which the harness
  supports: `frankenphp` round 3, `swoole` round 3, and `ephpm-worker` round 3
  were re-measured, the first two never having started. Those three sessions ran
  with a longer gap before them than the 60s the others got — more cooling, not
  less.
- **Supplementary run** is one round of 20s, not three rounds of 30s, so it has
  no standard deviation and correspondingly lower confidence. Treat its
  differences under ~10% as unresolved.

### What this does not measure

- Anything about ePHPm's embedded Turso database, litewire, its KV store, its
  clustering, or its native session handler. None are enabled.
- Memory footprint, cold-start, or sustained-load behaviour.
- Production capacity for any runtime. Worker counts are pinned at two to make
  the comparison fair, not because two is a sensible production value.

## Reproducing

```bash
# Primary run, upstream harness
COMPOSE_CMD="podman compose" \
ROUNDS=3 COOLDOWN=60 ENDPOINT_COOLDOWN=0 INITIAL_COOLDOWN=60 \
bash bench/run.sh all

# Supplementary run: first set SESSION_DRIVER=array and CACHE_STORE=array
# in app/.env.example and rebuild all images, then
COMPOSE_CMD="podman compose" ROUNDS=1 DURATION=20s bash bench/run.sh all
```

The parsed metrics, summary, schedule, and settings for the primary run are
committed under `results/20260902T001036Z/`; the raw `wrk` output stays
gitignored as upstream intends.
