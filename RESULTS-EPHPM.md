# ePHPm in the Laravel runtime benchmark

This fork adds two [ePHPm](https://github.com/ephpm/ephpm) entries to the
benchmark and records runs of all seven setups. The app, the endpoints, the
`wrk` parameters, and the harness are upstream's; the additions are
`runtimes/ephpm/`, `runtimes/ephpm-worker/`, `bench/select-ephpm-binary.sh`,
and the plumbing to list two more runtimes and to run the suite under a
non-Docker engine.

There are **two recordings**. Both are kept, because they measure different
ePHPm builds and the difference between them is the point:

| Recording | Date | ePHPm build | Shape |
| --- | --- | --- | --- |
| **First** | 2026-09-02 (UTC) | `ephpm/ephpm:v0.8.7-php8.4`, unmodified | primary 3 x 30s + supplementary 1 x 20s |
| **Second** | 2026-09-02 (UTC), later | ePHPm `main` @ `6557152` | 3 x 30s, plus a v0.8.7 "before" leg |

Everything not ePHPm is identical between them.

## Verdict

### Worker class — second recording

**ePHPm worker mode was the fastest runtime measured *and* had the best or
joint-best tail latency of the group.** It is 15-19% ahead of FrankenPHP on
throughput and ahead of it at every percentile except P99 on one endpoint:

| | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| Throughput vs FrankenPHP | +18.7% | +15.2% | +16.7% | +16.3% |
| P50 vs FrankenPHP | -15.5% | -14.3% | -14.6% | -13.4% |
| P90 vs FrankenPHP | -17.9% | -11.2% | -14.0% | -15.2% |
| P99 vs FrankenPHP | -5.7% | **+8.2%** | -3.8% | -17.6% |

(Negative = ePHPm lower = better, for latency.)

In the first recording ePHPm worker won throughput and lost the tail badly: its
P99 was 156-202 ms against FrankenPHP's 57-80 ms, roughly 2.5-3x. That gap is
gone. The single remaining loss is P99 on `/api/static`, where ePHPm is 66.0 ms
against FrankenPHP's 61.0 ms — 5 ms, and inside FrankenPHP's own run-to-run
range on the other endpoints.

The change responsible is ePHPm PR
[#443](https://github.com/ephpm/ephpm/pull/443), which replaces the dispatch
queue's `send().await` with a FIFO-fair admission semaphore. Measured
before/after on this harness, on the same host in the same session, it moves
**only the tail**: P50 unchanged, P90 halved, P99 down about two thirds,
throughput flat. That is the signature of a fairness fix rather than a speedup,
and it is what the numbers show.

### Per-request class — second recording

ePHPm per-request and Nginx + PHP FPM remain effectively tied, as in the first
recording, but ePHPm's advantage on the **database** endpoint is gone and its
database tail widened. Against Nginx + PHP FPM: +2.8% on `health`, -5.5% on
`static`, -2.1% on `cpu`, -2.7% on `db`. In the first recording the same
comparison was -2.8% / -2.2% / -1.0% / **+9.7%**.

The database endpoint is the one that moved outside noise. Measured against
v0.8.7 on the same host, ePHPm per-request `/api/db` went from 662 req/s and a
177 ms P99 to 531 req/s and a 288 ms P99. #443 touches `fpm_pool.rs` as well as
`worker_pool.rs`, so the per-request path is on the same changed admission
code. This is worth a follow-up in ePHPm; it is not established here, and the
caveats below say why.

### The headline caveat, unchanged

The benchmark as configured upstream is dominated by a bottleneck that is not
the runtime, and the default numbers separate the runtimes very poorly. See
"Two measurements, and why". Both recordings' verdicts come from the
supplementary (array sessions/cache) configuration.

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

`SESSION_DRIVER=array` and `CACHE_STORE=array` in `app/.env.example`, all
images rebuilt, everything else identical. `DB_CONNECTION` stays `sqlite`, so
`/api/db` still does its four real queries.

This is a deviation from upstream and is **not** committed to the repo —
`app/.env.example` is restored to upstream's values after each run. It is
included because it is the only configuration that actually separates the
runtimes. The **second recording is supplementary-only**: the first recording
already established what the primary configuration measures, and re-recording
the SQLite write lock would not say anything about a dispatch-queue change.

## Second recording — ePHPm `main` @ 6557152

ePHPm commit
[`6557152`](https://github.com/ephpm/ephpm/commit/6557152b93ee8b5e24b0f9cf265e940d721b0e9e)
("fix(worker): FIFO-fair dispatch admission", PR #443), five commits after the
`v0.8.7` tag. Of those five, only #443 touches the request path; the others are
cluster write-forwarding (inactive here — no clustering), config-key
validation, a CI change, and a docs change.

Three rounds, 30s per endpoint, 10 threads, 100 connections, 100 warm-up
requests, 60s cooldown between runtime sessions, harness runtime/endpoint
rotation intact. Array sessions and cache. Cells are `mean [min-max]` across
the three rounds. Zero `wrk` timeouts anywhere in this recording.

### Worker class — throughput, requests/sec

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| **ePHPm worker (Octane)** | **2,220** <sub>[2179-2261]</sub> | **2,147** <sub>[2073-2201]</sub> | **2,149** <sub>[2050-2208]</sub> | **1,485** <sub>[1451-1515]</sub> |
| FrankenPHP (Octane) | 1,871 <sub>[1801-1915]</sub> | 1,863 <sub>[1816-1890]</sub> | 1,841 <sub>[1806-1864]</sub> | 1,277 <sub>[1262-1290]</sub> |
| Swoole (Octane) | 1,421 <sub>[1002-1726]</sub> | 1,666 <sub>[1621-1699]</sub> | 1,665 <sub>[1620-1692]</sub> | 1,053 <sub>[924-1221]</sub> |
| OpenSwoole (Octane) | 1,522 <sub>[1193-1692]</sub> | 1,540 <sub>[1233-1741]</sub> | 1,550 <sub>[1367-1651]</sub> | 1,134 <sub>[984-1248]</sub> |
| RoadRunner (Octane) | 1,233 <sub>[1222-1251]</sub> | 1,177 <sub>[1137-1213]</sub> | 1,120 <sub>[984-1193]</sub> | 899 <sub>[836-946]</sub> |

### Worker class — latency, ms (lower is better)

| Runtime | | health | static | cpu | db |
| --- | --- | ---: | ---: | ---: | ---: |
| **ePHPm worker** | P50 | **44.6** | **45.5** | **45.8** | **67.0** |
| | P90 | **46.4** | **49.3** | **48.6** | **69.2** |
| | P99 | **59.5** <sub>[56.0-65.3]</sub> | 66.0 <sub>[65.5-66.6]</sub> | **61.3** <sub>[54.0-69.9]</sub> | **74.1** <sub>[70.2-79.6]</sub> |
| FrankenPHP | P50 | 52.8 | 53.1 | 53.6 | 77.4 |
| | P90 | 56.5 | 55.5 | 56.5 | 81.6 |
| | P99 | 63.1 <sub>[56.0-73.5]</sub> | **61.0** <sub>[58.1-63.9]</sub> | 63.7 <sub>[61.9-66.1]</sub> | 89.9 <sub>[89.2-90.4]</sub> |
| Swoole | P50 | 56.7 | 52.8 | 57.4 | 86.0 |
| | P90 | 160.4 | 77.9 | 80.6 | 158.4 |
| | P99 | 282.9 <sub>[145.6-514.0]</sub> | 142.6 <sub>[137.7-147.8]</sub> | 143.0 <sub>[136.3-150.9]</sub> | 359.4 <sub>[185.7-630.4]</sub> |
| OpenSwoole | P50 | 54.8 | 56.3 | 57.8 | 76.3 |
| | P90 | 107.0 | 117.8 | 94.0 | 120.1 |
| | P99 | 208.2 <sub>[138.5-345.1]</sub> | 238.9 <sub>[134.8-440.3]</sub> | 172.7 <sub>[142.3-233.1]</sub> | 209.7 <sub>[163.8-284.8]</sub> |
| RoadRunner | P50 | 60.3 | 66.6 | 68.9 | 89.0 |
| | P90 | 192.5 | 151.2 | 173.7 | 201.2 |
| | P99 | 284.2 <sub>[277.9-290.6]</sub> | 241.0 <sub>[147.2-291.1]</sub> | 246.6 <sub>[132.7-320.5]</sub> | 326.3 <sub>[280.0-379.0]</sub> |

Note how far the Swoole and OpenSwoole *ranges* span: their P99 varies by 2-4x
between rounds. Three rounds is enough to see that ePHPm worker and FrankenPHP
are the two stable runtimes here and that everything else has a tail that moves
round to round.

### Per-request class — throughput, requests/sec

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| Nginx + PHP FPM | 821 <sub>[747-860]</sub> | **852** <sub>[836-870]</sub> | **826** <sub>[792-848]</sub> | **546** <sub>[521-564]</sub> |
| **ePHPm per-request** | **844** <sub>[815-899]</sub> | 805 <sub>[778-833]</sub> | 809 <sub>[793-838]</sub> | 531 <sub>[466-574]</sub> |

### Per-request class — latency, ms (lower is better)

| Runtime | | health | static | cpu | db |
| --- | --- | ---: | ---: | ---: | ---: |
| Nginx + PHP FPM | P50 | **116.8** | **115.7** | **118.1** | 179.9 |
| | P90 | 130.7 | **123.2** | **131.4** | **197.4** |
| | P99 | 377.9 <sub>[131.7-850.8]</sub> | **142.8** | **148.5** | **224.8** |
| **ePHPm per-request** | P50 | 117.6 | 122.5 | 121.8 | **176.7** |
| | P90 | **126.2** | 134.7 | 132.0 | 245.4 |
| | P99 | **139.2** <sub>[125.3-160.2]</sub> | 151.0 | 155.1 | 287.7 |

The Nginx + PHP FPM `health` P99 of 377.9 ms is one round of 850.8 ms averaged
with two rounds of 131.7 and 151.1 ms — a single-round outlier, not a
characteristic. It is left in rather than dropped.

## Before and after: what PR #443 changed

Same host, same session, same images, same `wrk` shape. The only difference is
the file at `/usr/local/bin/ephpm`: `bench/select-ephpm-binary.sh` copies either
the locally built `main` binary or the base image's own v0.8.7 binary over it,
as the last layer of an otherwise byte-identical image. Three rounds each.

### ePHPm worker mode

| | | health | static | cpu | db |
| --- | --- | ---: | ---: | ---: | ---: |
| **req/s** | v0.8.7 | 2,211 | 2,226 | 2,132 | 1,453 |
| | main @ 6557152 | 2,220 | 2,147 | 2,149 | 1,485 |
| | change | +0.4% | -3.5% | +0.8% | +2.2% |
| **P50 ms** | v0.8.7 | 45.2 | 45.4 | 46.7 | 67.4 |
| | main @ 6557152 | 44.6 | 45.5 | 45.8 | 67.0 |
| | change | -1.3% | +0.2% | -1.9% | -0.6% |
| **P90 ms** | v0.8.7 | 91.2 | 90.4 | 94.9 | 135.5 |
| | main @ 6557152 | 46.4 | 49.3 | 48.6 | 69.2 |
| | change | **-49%** | **-45%** | **-49%** | **-49%** |
| **P99 ms** | v0.8.7 | 164.4 | 159.0 | 172.0 | 242.5 |
| | main @ 6557152 | 59.5 | 66.0 | 61.3 | 74.1 |
| | change | **-64%** | **-58%** | **-64%** | **-69%** |

Throughput is flat: three of four endpoints are inside their own run-to-run
range, and the one that is not (`static`, -3.5%) is a 79 req/s difference
against a 128 req/s spread in the v0.8.7 leg. The median is flat to within 2%.
P90 halves and P99 falls by roughly two thirds on every endpoint.

The v0.8.7 numbers here also reproduce the first recording's supplementary run
(P99 156.0 / 157.4 / 160.7 / 201.7 ms there, 164.4 / 159.0 / 172.0 / 242.5 ms
here), which is the cross-check that the two recordings are measuring the same
machine.

### ePHPm per-request mode

| | | health | static | cpu | db |
| --- | --- | ---: | ---: | ---: | ---: |
| **req/s** | v0.8.7 | 924 | 923 | 911 | 662 |
| | main @ 6557152 | 844 | 805 | 809 | 531 |
| | change | -8.7% | -12.8% | -11.2% | **-19.8%** |
| **P50 ms** | v0.8.7 | 106.8 | 107.1 | 108.8 | 149.0 |
| | main @ 6557152 | 117.6 | 122.5 | 121.8 | 176.7 |
| **P90 ms** | v0.8.7 | 113.8 | 113.3 | 114.4 | 159.5 |
| | main @ 6557152 | 126.2 | 134.7 | 132.0 | 245.4 |
| **P99 ms** | v0.8.7 | 134.9 | 124.6 | 123.6 | 176.7 |
| | main @ 6557152 | 139.2 | 151.0 | 155.1 | 287.7 |

This one needs reading carefully, and it does **not** support a clean "#443 cost
the per-request path 10-20%" claim:

- The v0.8.7 leg here was measured as three consecutive rounds of one runtime,
  not rotated among seven, so it had a different cadence (rounds ~3 minutes
  apart instead of ~19). Cross-runtime numbers from the two legs are not
  directly comparable.
- Nginx + PHP FPM, which did not change at all, is also slower in this
  recording than the first (static 852 vs 929 req/s, db 546 vs 610). Some of
  the drop above is the recording, not the binary. Part of that is the
  supplementary shape: the first recording's supplementary was 20s rounds, this
  one is 30s.

The comparison that survives both objections is ePHPm per-request against
Nginx + PHP FPM **inside one recording**, since they share cadence and session:

| ePHPm per-request as % of Nginx + PHP FPM | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| First recording (v0.8.7) | 97.2% | 97.8% | 99.0% | **109.7%** |
| Second recording (main) | 102.8% | 94.5% | 97.9% | **97.3%** |

health, static and cpu move within a few points in both directions — noise. The
database endpoint moves 12 points in one direction and its P99 goes from beating
Nginx + PHP FPM (157 vs 173 ms in the first recording) to losing to it (288 vs
225 ms here). That is the one per-request result worth chasing upstream.

## `worker_backlog` sweep — harness support, no numbers yet

PR #443 made worker-mode dispatch admission FIFO-fair but left the queue
*depth* at its default: `[php] worker_backlog = 0` means "= `worker_count`", so
with `worker_count = 2` the admission gate holds two permits. Whether a deeper
queue buys anything is an open question — the obvious counter-argument is that
this is a closed-loop test, so at saturation mean latency is pinned to
`connections / throughput` (100 / 2,147 = 46.6 ms, which is exactly the
measured mean) and queue depth can only move where a request waits, not how
long. A sweep was set up but **not recorded**; the harness support is committed
so it is one command away.

To run it:

```bash
# One image, pinned across every arm; depth comes from the environment.
SKIP_BUILD=1 WORKER_BACKLOG=8 RUN_ID=sweep-b8 bash bench/run.sh ephpm-worker
```

`runtimes/ephpm-worker/docker-compose.yml` forwards `WORKER_BACKLOG` as
`EPHPM_PHP__WORKER_BACKLOG`, so depth is a pure environment override and the
image stays byte-identical between arms. Confirm it landed by looking for
`backlog=` in the container's `worker pool started` log line — the value is
echoed there. `SKIP_BUILD=1` exists because podman does not reliably cache a
cross-stage `COPY --from=build`: re-running `compose build` between arms mints
a new image ID from unchanged inputs, which is a variable a config-only sweep
should not have.

Two things to note when reading `ephpm_worker_request_wait_seconds` for this:
it times `WorkerPool::dispatch()`, which is the *admission* wait plus a
non-blocking `try_send` — it does **not** cover the time the job then sits in
the dispatch channel. Raising the backlog hands out permits sooner and moves
wait out of the metered segment into an unmetered one, so a fall in that metric
is not on its own a latency win. And in worker mode `[php] overload_policy =
"shed"` is explicitly ignored (the server warns at startup), so the
"shallow queue sheds sooner" argument for keeping the default low applies to
the experimental `fpm_engine = "pool"` path, not to worker mode.

### Caveat that cost a session: rebuilding re-bakes the session driver

The `array` session/cache setting that the supplementary run depends on is an
**uncommitted** edit to `app/.env.example`, and the Dockerfiles bake it in with
`php artisan config:cache`. An image therefore runs whatever driver the tree
had *when that image was built*, which need not be what the tree says now and
is not visible in any config file at run time.

Rebuilding against a tree that had `SESSION_DRIVER=database` silently
reintroduces the SQLite session-write lock. The failure does not look like a
config problem:

- every runtime collapses together (FrankenPHP 1,863 -> 116 req/s, ePHPm worker
  2,147 -> 30-70 req/s), so the comparison still looks internally fair;
- throughput stops scaling with concurrency (c1 130 req/s, c100 197 req/s) —
  the tell that it is serialization, not slow request handling;
- it survives restarting the container engine, because it is baked into a
  layer;
- **a control runtime that was also rebuilt collapses with the subject**, which
  reads as "the host died" rather than "the config changed". A control only
  controls for what it does not share; a shared rebuild is shared.

`bench/run.sh` now records the effective drivers per run in
`app-config.txt`, read out of the compiled config cache inside the container,
so every result directory says which regime produced it. Check it before
trusting any number:

```
session.driver=array cache.default=array db.default=sqlite
```

## First recording — `ephpm/ephpm:v0.8.7-php8.4`

Kept as recorded. This is what the v0.8.7 release measures.

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

**`runtimes/ephpm`** — ePHPm's default `fpm` mode with `[php] workers = 2`,
which caps concurrent PHP execution at two and is ePHPm's equivalent of the
`pm.max_children = 2` the Nginx + PHP FPM image uses.

**`runtimes/ephpm-worker`** — ePHPm's `worker` mode with `worker_count = 2`,
matching `--workers=2` on the Octane runtimes. The entrypoint is
`ephpm/octane-driver`, which implements Laravel Octane's `Client` contract and
drives Octane's own `Worker` loop.

**`bench/select-ephpm-binary.sh`** — chooses which ePHPm binary the two images
run. Both images are built `FROM ephpm/ephpm:v0.8.7-php8.4` and overwrite
`/usr/local/bin/ephpm` as their **last** layer with
`runtimes/ephpm-bin/ephpm` (gitignored). `select-ephpm-binary.sh published`
copies the base image's own binary back over itself, so the image is
byte-equivalent to using the published image unmodified; passing a path instead
swaps in a locally built binary. Everything else about the image — base,
layers, vendor tree, config, entrypoint — is identical either way, which is
what makes the before/after leg above a single-variable comparison.

For the second recording the `main` binary was built with
`cargo xtask release 8.4` inside `ephpm/ephpm-ci:latest`, the same
almalinux8 / glibc-2.28 container the published release binaries are built in.
`ephpm --version` inside the running container reported
`0.8.8-dev+main.6557152`.

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
VM, Compose v5.5.0, `wrk` 4.2.0. `wrk` runs inside the same WSL2 VM as the
containers, over published localhost ports. No CPU pinning — the upstream
harness does not pin and none was added.

Rootless Podman cannot start Compose v5's privileged buildkit container, so
images were built with `DOCKER_BUILDKIT=0`. That affects image construction
only, not the measured request path.

### The second recording's ePHPm binary is self-built

The five non-ePHPm runtimes and the v0.8.7 "before" leg run published,
digest-pinned artifacts. The `main` binary does not exist as a published
artifact — that is the whole point of the recording — so it was compiled
locally. It was built in `ephpm/ephpm-ci:latest`, the same container image the
project's release workflow uses for its Linux x86-64 leg, with the same
command (`cargo xtask release 8.4`) and the same `profile.release` (`lto =
"fat"`, `codegen-units = 1`). It is as close to a published release binary as a
local build gets, but it is not one, and it has not been through the project's
release CI.

### Deviations from the documented defaults

- **Cooldown.** The runner defaults to `COOLDOWN=900`, which with seven runtimes
  and three rounds is over five hours of waiting. Both recordings used
  `COOLDOWN=60`, uniform across all runtimes, with the harness's runtime-order
  and endpoint-order rotation intact.
- **First recording, interrupted and resumed.** The primary run was interrupted
  after 74 of 84 measurements and resumed with the same `RUN_ID`;
  `frankenphp` round 3, `swoole` round 3, and `ephpm-worker` round 3 were
  re-measured, the first two never having started.
- **Second recording, interrupted and resumed.** The suite was killed during
  `ephpm-worker` round 3 and resumed with the same `RUN_ID`. `ephpm-worker`,
  `frankenphp` and `swoole` round 3 were measured after a longer-than-60s gap —
  more cooling, not less. Every other cell ran on the normal schedule.
- **Second recording, before-leg cadence.** The v0.8.7 "before" leg measured
  only the two ePHPm entries, three rounds each, consecutively rather than
  rotated among seven runtimes. Its rounds are ~3 minutes apart instead of ~19.
  This is why the per-request before/after above is read through the
  Nginx + PHP FPM ratio rather than directly.
- **Supplementary duration.** The first recording's supplementary run was one
  round of 20s; the second recording is three rounds of 30s. Absolute
  throughput is slightly lower at 30s across every runtime, so cross-recording
  absolute numbers should not be compared without that in mind. Within-recording
  comparisons are unaffected.

### What this does not measure

- Anything about ePHPm's embedded Turso database, litewire, its KV store, its
  clustering, or its native session handler. None are enabled.
- Memory footprint, cold-start, or sustained-load behaviour.
- Production capacity for any runtime. Worker counts are pinned at two to make
  the comparison fair, not because two is a sensible production value.

## Reproducing

```bash
# Choose which ephpm binary the two ePHPm images run.
bash bench/select-ephpm-binary.sh published            # the base image's v0.8.7
bash bench/select-ephpm-binary.sh /path/to/built/ephpm # a local build

# Primary run, upstream harness
COMPOSE_CMD="podman compose" \
ROUNDS=3 COOLDOWN=60 ENDPOINT_COOLDOWN=0 INITIAL_COOLDOWN=60 \
bash bench/run.sh all

# Supplementary run: first set SESSION_DRIVER=array and CACHE_STORE=array
# in app/.env.example and rebuild all images, then
COMPOSE_CMD="podman compose" \
ROUNDS=3 DURATION=30s COOLDOWN=60 ENDPOINT_COOLDOWN=0 INITIAL_COOLDOWN=60 \
bash bench/run.sh all
```

To build the `main` binary the way the second recording did:

```bash
docker run --rm -v "$PWD":/w -w /w ephpm/ephpm-ci:latest \
  cargo xtask release 8.4
# -> target/x86_64-unknown-linux-gnu/release/ephpm
```

The parsed metrics, summary, schedule, settings, and a per-round percentile
table are committed under `results/`; the raw `wrk` output stays gitignored as
upstream intends. `summary.csv` is the harness's own output (average latency and
P99 only); `percentiles.csv` is generated alongside it and carries P50/P75/P90/P99
per runtime, endpoint and round, which is what the tail tables above are built
from.

| Run ID | What |
| --- | --- |
| `20260902T001036Z` | First recording, primary run |
| `20260902T050000Z-main6557152` | Second recording, all seven runtimes on `main` @ 6557152 |
| `20260902T0700Z-v087before` | Second recording, the two ePHPm entries on published v0.8.7 |
