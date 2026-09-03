# ePHPm in the Laravel runtime benchmark

This fork adds two [ePHPm](https://github.com/ephpm/ephpm) entries and a
**FrankenPHP classic** entry to the benchmark, and records runs of all of them.
The app, the endpoints, the `wrk` parameters, and the harness are upstream's;
the additions are `runtimes/ephpm/`, `runtimes/ephpm-worker/`,
`runtimes/frankenphp-classic/`, `bench/select-ephpm-binary.sh`,
`bench/percentiles.py`, and the plumbing to list three more runtimes, to select
a class rather than a single runtime, and to run the suite under a non-Docker
engine.

There are **three recordings**. All are kept, because they measure different
things and the differences between them are the point:

| Recording | Date | ePHPm build | Shape | Profile |
| --- | --- | --- | --- | --- |
| **First** | 2026-09-02 (UTC) | `ephpm/ephpm:v0.8.7-php8.4`, unmodified | all 7 runtimes, 3 x 30s, plus a 1 x 20s second pass | `upstream`, then `runtime` |
| **Second** | 2026-09-02 (UTC), later | ePHPm `main` @ `6557152` | all 7 runtimes, 3 x 30s, plus a v0.8.7 "before" leg | `runtime` |
| **Third** | 2026-09-03 (UTC) | `ephpm/ephpm:v0.9.0-php8.4`, unmodified | **per-request class only** (3 runtimes incl. the new FrankenPHP classic), 3 x 30s | `runtime` |

Everything not ePHPm is identical between the first two. The third measures a
different set of runtimes on a different ePHPm build, so **it is not
cross-comparable with the other two in absolute terms**; read it on its own and
through its own control. The worker-class tables in this document are all from
the second recording and are unchanged by it.

## Which profile every number below came from

`BENCH_PROFILE` (README.md, "Benchmark profiles") selects the session and cache
store every image is built with. Both values are committed and either is one
environment variable away — nothing has to be edited to reproduce either one:

| `BENCH_PROFILE` | Session and cache store | What it measures |
| --- | --- | --- |
| `upstream` (default) | `database` | The shared SQLite session-write lock |
| `runtime` | `array` | The runtimes |

**Every differentiating number in this document was recorded with
`BENCH_PROFILE=runtime`.** The `upstream` numbers are kept, and labelled, in
"First recording"; they are what the harness measures as it ships, and they do
not separate the runtimes. Each run directory carries an `app-config.txt` naming
the drivers its containers actually ran, and `bench/run.sh` aborts rather than
record a run whose containers disagree with the requested profile.

## Verdict

### Per-request class — third recording

**ePHPm per-request beats both.** Against FrankenPHP running in its own default
classic mode it is 22-36% ahead on throughput and 16-31% lower at every
percentile bar one; against the Nginx + PHP FPM control it is 13-25% ahead on
throughput and lower at every percentile bar the same one. FrankenPHP classic is
the slowest of the three, at a flat 0.92x the control on all four endpoints.

| Throughput, mean of 3 rounds | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| ePHPm vs FrankenPHP classic | **+23.0%** | **+22.4%** | **+22.3%** | **+35.7%** |
| ePHPm vs Nginx + PHP FPM | **+13.2%** | **+12.7%** | **+12.9%** | **+25.4%** |
| FrankenPHP classic vs Nginx + PHP FPM | -7.9% | -8.0% | -7.8% | -7.6% |

The exception both times is ePHPm's P99 on `/api/cpu`: 122.1 ms, which is +1.1%
against the control's 120.8 ms and only -4.9% against FrankenPHP classic's
128.4 ms, where every other tail cell is 16-31% better. It is one round of
145.2 ms averaged with 106.3 and 114.8 — a single-round outlier in an otherwise
unusually tight recording (every other cell's three rounds fall within a few
percent of each other, and there were zero `wrk` timeouts anywhere). It is left
in rather than dropped.

**Read the size of the ePHPm win with care.** This is a different ePHPm build
from the second recording (published v0.9.0 vs a self-built `main` @ 6557152)
*and* a different, smaller rotation, so it is a new baseline rather than a
before/after. What can be said across recordings is the ratio to the same
control: ePHPm per-request went from roughly 0.95-1.03x Nginx + PHP FPM in the
second recording to 1.13-1.25x here, and the `/api/db` regression flagged in the
second recording's verdict (0.97x control) is not merely gone but reversed
(1.25x). That is suggestive of a real v0.9.0 improvement; it is **not
established** by this recording, which was not built to measure it.

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
"Two measurements, and why". Every verdict above comes from
`BENCH_PROFILE=runtime` (array sessions and cache).

## Read the two classes separately

| Class | Runtimes | Model |
| --- | --- | --- |
| **Worker** | FrankenPHP, Swoole, OpenSwoole, RoadRunner, **ePHPm worker** | Laravel is booted once per worker and stays resident. All five run Laravel Octane. |
| **Per-request** | Nginx + PHP FPM, **ePHPm per-request**, **FrankenPHP classic** | Every request pays a full PHP request startup, framework bootstrap, and shutdown. |

`ephpm` is a per-request runtime; read it against Nginx with PHP FPM and
FrankenPHP classic, not against the Octane runtimes. `ephpm-worker` is the entry
that belongs beside the Octane runtimes, and it gets there through Laravel
Octane's own worker loop, so the framework-side lifecycle is the same code in
both cases.

**The same FrankenPHP binary appears in both classes, and that is the point.**
`frankenphp` is FrankenPHP under Laravel Octane. `frankenphp-classic` is the
identical image with a Caddyfile whose `php_server` has no `worker` — which is
FrankenPHP's *default* mode, the one you get by installing it and pointing it at
`public/`. Upstream's suite only ever measured the Octane configuration, so the
mode most FrankenPHP users actually run, and the runtime architecturally closest
to ePHPm per-request, had never been recorded at all. `bench/run.sh per-request`
measures that class on its own.

Also note both classes hold worker/thread counts at **2**. That is a fairness
device, not a capacity claim, and it is the reason no absolute number in this
document should be read as "what this runtime can do."

## Two measurements, and why

### `BENCH_PROFILE=upstream`: the harness exactly as upstream ships it

Three rounds, 30s per endpoint, 10 threads, 100 connections, 100 warm-up
requests, `SESSION_DRIVER=database` and `CACHE_STORE=database` straight out of
the committed `app/.env.example`. This is the run to quote if you want "the
upstream harness, unmodified."

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
   SQLite serializes writers with a global write lock, so every runtime
   queues behind the same lock.

That bottleneck is identical for every runtime, so the `upstream` profile is
*fair*. It is just mostly a measurement of SQLite session-write contention
rather than of request handling, and the runtime differences in it are small
relative to the shared ceiling.

**This is the part worth taking upstream on its own.** The size of the effect is
easy to miss because it hides behind a comparison that still looks internally
consistent. Same host, same session, same images apart from the two drivers:

| | `BENCH_PROFILE=runtime` | `BENCH_PROFILE=upstream` |
| --- | ---: | ---: |
| FrankenPHP, `/api/static` | 1,863 req/s | 116 req/s |
| ePHPm worker, `/api/static` | 2,147 req/s | 30-70 req/s |
| Scaling, 1 -> 100 connections | scales | 130 -> 197 req/s |

A 16-60x drop, in the same direction for every runtime, with throughput almost
flat against concurrency — effective parallelism of about one, which is what a
single serialized writer looks like. Any harness that puts a `database` session
store in front of a SQLite connection is measuring that writer, not the server
under test.

### `BENCH_PROFILE=runtime`: the same harness with the shared lock removed

`SESSION_DRIVER=array` and `CACHE_STORE=array`, all images rebuilt, everything
else identical. `DB_CONNECTION` stays `sqlite`, so `/api/db` still does its four
real queries.

This is a deviation from upstream's default, and it is committed as such: it is
selected with `BENCH_PROFILE=runtime`, not by editing a file, so one clone
reproduces both configurations and neither depends on local state. It is
included because it is the only configuration that actually separates the
runtimes. The **second recording is `runtime`-only**: the first recording
already established what the `upstream` profile measures, and re-recording the
SQLite write lock would not say anything about a dispatch-queue change.

## Third recording — the per-request class, with FrankenPHP classic

**What this recording is for.** FrankenPHP runs classic (non-worker) by default,
but upstream's suite only ever measured it under Laravel Octane. That left the
per-request class with exactly two members, and left the runtime whose
architecture is closest to ePHPm per-request — an embedded ZTS PHP running one
request per thread inside a single server process — unmeasured in the mode that
actually competes with ePHPm. `runtimes/frankenphp-classic/` fixes that.

Three runtimes, three rounds, 30s per endpoint, 10 threads, 100 connections,
100 warm-up requests, 60s cooldown between runtime sessions, runtime and
endpoint rotation intact, `BENCH_PROFILE=runtime`. `bash bench/run.sh
per-request` measures the class as a unit, rotating the three arms round to
round exactly as `all` does.

**The ePHPm binary here is the published `ephpm/ephpm:v0.9.0-php8.4`,
unmodified**, not the `main` build the second recording used. The worker-class
tables elsewhere in this document are from the second recording on
`main` @ `6557152` and are unchanged. Do not read absolute numbers across the
two recordings; read this one through its own control.

### Matching concurrency for FrankenPHP classic

This is the fairness crux of the new arm, so here is the decision and the
reasoning behind it in full.

Every arm in the suite is pinned to **two concurrent PHP executions**:

| Runtime | Knob | What the knob caps |
| --- | --- | --- |
| Nginx + PHP FPM | `pm = static`, `pm.max_children = 2` | 2 OS processes, each running one request at a time |
| FrankenPHP (Octane) | `octane:start --workers=2` | 2 Octane workers |
| Swoole / OpenSwoole / RoadRunner | `octane:start --workers=2` | 2 Octane workers |
| ePHPm per-request | `[php] concurrency = 2` | 2 dedicated OS threads, each running one request at a time |
| ePHPm worker | `[php] concurrency = 2` | 2 persistent worker threads |
| **FrankenPHP classic** | `frankenphp { num_threads 2 }` | **2 ZTS PHP threads, each running one request at a time** |

**`num_threads` is the knob, and it is the honest analogue.** In classic mode
FrankenPHP hands an incoming request to a PHP thread, and that thread runs the
request to completion before it takes another. The thread count is therefore
exactly the number of PHP requests that can be executing simultaneously — the
same quantity `pm.max_children` caps and the same quantity ePHPm's
`concurrency` caps. There is no second candidate knob: nothing else in
FrankenPHP bounds concurrent PHP execution.

Left unset it would be `2 x CPUs`, which on this host (16C/32T) is **64** — a
32x concurrency advantage over every other arm.

`max_threads` is pinned to 2 as well. It already defaults to `num_threads`, so
today the line changes nothing; it is written down so the cap is stated rather
than inherited, because `max_threads` also accepts `auto`, and a future
FrankenPHP that flipped the default would start autoscaling past 2 without
anything failing. The container's own startup log is the receipt:

```
"msg":"FrankenPHP started 🐘","php_version":"8.4.24","num_threads":2,"max_threads":2,"max_requests":0
```

**Verified, not assumed.** Concurrency was measured before the run rather than
taken from the documentation — `/api/health`, 8s, rising connection counts:

| Connections | Requests/sec | P50 latency |
| ---: | ---: | ---: |
| 1 | 375.4 | 2.61 ms |
| 2 | 749.1 | 2.63 ms |
| 8 | 847.5 | 9.38 ms |
| 32 | 839.6 | 37.82 ms |

Throughput doubles exactly from one connection to two with latency unchanged,
then stops dead while latency grows linearly with offered concurrency. That is
effective parallelism of two, which is what the knob claims.

**Where the analogy is clean, and where it is not.** Stated plainly, because
the point of adding this arm is to be able to trust the comparison:

- *Clean:* all three per-request arms run **two long-lived PHP execution
  contexts that each handle one request at a time and are never recycled**.
  `pm.max_requests` is commented out in the FPM image, FrankenPHP classic
  reports `max_requests:0`, and ePHPm's per-request pool threads are long-lived.
  So all three amortise PHP module init and none of them pays a
  process/thread respawn during a measurement.
- *Not identical:* FPM's two contexts are **processes**; FrankenPHP classic's
  and ePHPm's are **threads** in one process. Thread-based embedders run a ZTS
  PHP, which pays a thread-local-storage indirection that FPM's NTS PHP does
  not. That is a real difference between FPM and the other two — and it is
  **symmetric between FrankenPHP classic and ePHPm**, which are the two arms
  this comparison is actually about. Both are ZTS embedders running one request
  per thread.
- *Not pinned anywhere, in any arm:* the non-PHP layer. Nginx picks its own
  worker processes, FrankenPHP's Go runtime took `GOMAXPROCS=32`, ePHPm's tokio
  runtime uses all cores. Upstream pins none of this and neither does this fork;
  pinning it would be a different benchmark.
- *The one place the mapping could be argued:* there is no process count to
  match for FrankenPHP classic, because a thread is the only unit it exposes.
  Reading "2 php-fpm processes" as "2 FrankenPHP instances" would be a
  different and much less useful experiment. `num_threads` is the only knob that
  caps concurrent PHP execution, so it is the one used.
- *Memory budget:* FrankenPHP's own sizing rule is
  `num_threads x memory_limit < available_memory`. At `2 x 128M` this arm gets
  the same 256M aggregate PHP budget as the FPM arm's two 128M children and
  ePHPm's `concurrency = 2` at 128M.

### Throughput, requests/sec

Cells are `mean [min-max]` across the three rounds. Zero `wrk` timeouts anywhere
in this recording.

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| **ePHPm per-request** | **1,022** <sub>[1010-1029]</sub> | **1,010** <sub>[997-1022]</sub> | **997** <sub>[987-1005]</sub> | **719** <sub>[711-725]</sub> |
| Nginx + PHP FPM | 903 <sub>[889-917]</sub> | 896 <sub>[890-903]</sub> | 884 <sub>[876-892]</sub> | 574 <sub>[570-577]</sub> |
| FrankenPHP classic | 831 <sub>[828-833]</sub> | 825 <sub>[818-833]</sub> | 815 <sub>[810-818]</sub> | 530 <sub>[512-546]</sub> |

### Ratio to control (Nginx + PHP FPM = 1.00), throughput

| Runtime | health | static | cpu | db |
| --- | ---: | ---: | ---: | ---: |
| **ePHPm per-request** | **1.13** | **1.13** | **1.13** | **1.25** |
| Nginx + PHP FPM | 1.00 | 1.00 | 1.00 | 1.00 |
| FrankenPHP classic | 0.92 | 0.92 | 0.92 | 0.92 |

FrankenPHP classic is remarkably flat against the control — 0.921 / 0.920 /
0.922 / 0.924 — which is what a uniform per-request overhead difference looks
like, as opposed to something workload-shaped.

### Latency, ms (lower is better)

| Runtime | | health | static | cpu | db |
| --- | --- | ---: | ---: | ---: | ---: |
| **ePHPm per-request** | P50 | **97.6** <sub>[97.0-98.7]</sub> | **98.7** <sub>[97.5-100.2]</sub> | **99.5** <sub>[98.6-100.9]</sub> | **138.9** <sub>[137.7-140.4]</sub> |
| | P90 | **98.8** <sub>[98.1-99.9]</sub> | **99.9** <sub>[98.6-101.2]</sub> | **101.2** <sub>[100.1-102.5]</sub> | **141.8** <sub>[140.8-143.8]</sub> |
| | P99 | **103.3** <sub>[101.5-104.5]</sub> | **107.1** <sub>[103.4-109.8]</sub> | 122.1 <sub>[106.3-145.2]</sub> | **145.4** <sub>[143.2-147.9]</sub> |
| Nginx + PHP FPM | P50 | 110.0 <sub>[108.7-111.4]</sub> | 111.0 <sub>[110.5-111.6]</sub> | 112.4 <sub>[111.4-113.2]</sub> | 172.8 <sub>[171.7-173.4]</sub> |
| | P90 | 112.4 <sub>[111.0-114.1]</sub> | 113.2 <sub>[112.6-114.1]</sub> | 115.0 <sub>[114.0-116.5]</sub> | 178.9 <sub>[177.3-182.2]</sub> |
| | P99 | 118.7 <sub>[114.8-122.4]</sub> | 119.5 <sub>[116.2-124.4]</sub> | **120.8** <sub>[118.6-123.7]</sub> | 193.1 <sub>[181.4-215.9]</sub> |
| FrankenPHP classic | P50 | 119.5 <sub>[119.2-119.7]</sub> | 120.6 <sub>[119.7-121.5]</sub> | 122.0 <sub>[121.6-122.8]</sub> | 187.7 <sub>[182.3-194.6]</sub> |
| | P90 | 121.6 <sub>[121.1-122.0]</sub> | 122.8 <sub>[121.9-123.6]</sub> | 124.0 <sub>[123.6-124.9]</sub> | 199.6 <sub>[192.2-206.9]</sub> |
| | P99 | 126.1 <sub>[125.1-127.0]</sub> | 128.1 <sub>[127.6-128.6]</sub> | 128.4 <sub>[128.0-128.8]</sub> | 210.5 <sub>[197.8-223.2]</sub> |

This is a closed-loop test at 100 connections, so mean latency is pinned to
`connections / throughput` and the P50 column is largely the throughput column
restated. The tail columns are the ones that carry independent information, and
the ordering there is the same: ePHPm, then FPM, then FrankenPHP classic, on
every endpoint except ePHPm's single outlier round on `/api/cpu`.

### The three arms are not the same PHP

Worth stating because it bears directly on how to read the FrankenPHP classic
result. Captured from each container during the run
(`results/<run-id>/<runtime>/run-1/php-runtime.txt`):

| Runtime | PHP | Thread safety | Execution context |
| --- | --- | --- | --- |
| Nginx + PHP FPM | 8.4.24 | **NTS** | 2 processes |
| FrankenPHP classic | 8.4.24 | **ZTS** | 2 threads, 1 process |
| ePHPm per-request | 8.4.23 | **ZTS** | 2 threads, 1 process |

FrankenPHP classic and Nginx + PHP FPM run the *same PHP release*, built the
same day from the same upstream source, and differ in thread-safety mode and
SAPI. ZTS PHP pays a thread-local-storage indirection that NTS does not, and a
5-10% penalty is the usual quoted figure. FrankenPHP classic landing at a flat
0.92x the FPM control is squarely inside that range, so the most likely reading
of that number is **"this is what embedding ZTS PHP costs", not "FrankenPHP's
server is slow"**.

Which makes the ePHPm number the interesting one: ePHPm is also an embedded ZTS
PHP running one request per thread, pays the same ZTS tax, and still lands at
1.13-1.25x the NTS control. Whatever ePHPm is doing differently in its
per-request path is worth more than the ZTS penalty costs.

Two disclosures on the table above. ePHPm is one patch release behind (8.4.23
against 8.4.24) because that is what the pinned `php-sdk` build for
`ephpm/ephpm:v0.9.0-php8.4` ships; nothing in the 8.4.23-to-8.4.24 range is
known to be performance-relevant, but it is a difference and it is not
controlled. And the interpretation of the ZTS gap above is an *interpretation* —
this harness does not isolate thread-safety mode, and doing so would need an NTS
FrankenPHP and a ZTS FPM, neither of which exists as a pinned image here.

### Host discipline for this recording

Reconstructed from the engine's own event log across the whole 06:47-07:16Z
window, not from a snapshot:

- Nine measurement windows, each ~2m05s, strictly serial: every container's
  `died` precedes the next container's `start`, with the configured ~61s gap
  between them. No two runtimes were ever up at once.
- Zero `wrk` timeouts in any of the 36 measurements.
- One unrelated container ran inside the window: a 16 ms `podman run` reading a
  config file out of the FPM image, at 06:51:26Z — in the cooldown gap between
  `nginx-fpm` round 1 (ended 06:51:07Z) and `ephpm` round 1 (started 06:52:08Z),
  not during any measurement.
- Host load average before the first measurement was 0.55; no other `wrk` was
  running.

This matters because the failure it guards against is quiet: a competing
100-connection `wrk` costs roughly 40% of throughput, and it shows up as one
arm's rounds being low, which reads as a slow runtime rather than a busy host.

## Second recording — ePHPm `main` @ 6557152

ePHPm commit
[`6557152`](https://github.com/ephpm/ephpm/commit/6557152b93ee8b5e24b0f9cf265e940d721b0e9e)
("fix(worker): FIFO-fair dispatch admission", PR #443), five commits after the
`v0.8.7` tag. Of those five, only #443 touches the request path; the others are
cluster write-forwarding (inactive here — no clustering), config-key
validation, a CI change, and a docs change.

Three rounds, 30s per endpoint, 10 threads, 100 connections, 100 warm-up
requests, 60s cooldown between runtime sessions, harness runtime/endpoint
rotation intact, `BENCH_PROFILE=runtime`. Cells are `mean [min-max]` across
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
# Build the pinned image once, on the profile the sweep is meant to run on.
BENCH_PROFILE=runtime RUN_ID=sweep-b0 bash bench/run.sh ephpm-worker

# Then one image, pinned across every arm; depth comes from the environment.
BENCH_PROFILE=runtime SKIP_BUILD=1 WORKER_BACKLOG=8 RUN_ID=sweep-b8 \
  bash bench/run.sh ephpm-worker
```

`BENCH_PROFILE` has to be repeated on every arm even though `SKIP_BUILD=1`
rebuilds nothing: the runner checks the running container's compiled config
against it and aborts on a mismatch, and the default is `upstream`.

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

### Caveat that cost a session: an image runs the profile it was built with

The Dockerfiles bake `session.driver` and `cache.default` into
`bootstrap/cache/config.php` with `php artisan config:cache`, so an image runs
whatever `BENCH_PROFILE` it was built with. That is invisible at run time — no
config file in the container tree says it, and no environment variable changes
it.

Historically this was worse: the `array` setting was an **uncommitted** edit to
`app/.env.example` rather than a committed knob, so an image's drivers were
whatever the working tree happened to hold at build time, and nobody with a
clean clone could reproduce the numbers at all
([ephpm/ephpm#456](https://github.com/ephpm/ephpm/issues/456)). Rebuilding
against a tree that had been restored to `SESSION_DRIVER=database` silently
reintroduced the SQLite session-write lock. The failure does not look like a
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

Two things now stand between that and a recorded number. The profile is a
committed build argument, so choosing one is `BENCH_PROFILE=runtime` rather
than an edit that can be forgotten or reverted. And `bench/run.sh` reads the
effective drivers out of the compiled config cache inside each running
container into `app-config.txt`:

```
session.driver=array cache.default=array db.default=sqlite
```

If those do not match the requested profile, the run **aborts** instead of
producing numbers — including under `SKIP_BUILD=1`, where the images are
deliberately not rebuilt. Read `app-config.txt`, never the source tree, when
deciding what an existing number measured.

## First recording — `ephpm/ephpm:v0.8.7-php8.4`

Kept as recorded. This is what the v0.8.7 release measures.

### `BENCH_PROFILE=runtime` (array sessions/cache, 1 round x 20s)

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

### `BENCH_PROFILE=upstream` (database sessions/cache, 3 rounds x 30s)

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

**`runtimes/ephpm`** — ePHPm's default per-request mode with
`[php] concurrency = 2`, which caps concurrent PHP execution at two and is
ePHPm's equivalent of the `pm.max_children = 2` the Nginx + PHP FPM image uses.
(Before ePHPm v0.9.0 those two knobs were spelled `mode = "fpm"` and
`workers = 2`; see "The v0.9.0 config rename".)

**`runtimes/ephpm-worker`** — ePHPm's `worker` mode with `[php] concurrency = 2`,
matching `--workers=2` on the Octane runtimes. The entrypoint is
`ephpm/octane-driver`, which implements Laravel Octane's `Client` contract and
drives Octane's own `Worker` loop.

**`runtimes/frankenphp-classic`** — the same pinned FrankenPHP image as
`runtimes/frankenphp`, with a Caddyfile whose `php_server` has no `worker`
directive. That is FrankenPHP's default mode. Concurrency is `num_threads 2`;
see "Matching concurrency for FrankenPHP classic".

**`bench/percentiles.py`** — extracts P50/P75/P90/P99 and per-round rows from
the raw `wrk` output. `bench/summarize.sh` emits average latency and P99 only,
averaged across rounds; every tail number and every `[min-max]` spread in this
document comes from this script instead.

**`bash bench/run.sh per-request` / `worker`** — measures one class as a unit,
with the harness's rotation, cooldowns and profile check intact. The two classes
are not comparable to each other, so re-recording one alone is a normal thing to
want, and a hand-written loop over single-runtime invocations loses the
rotation.

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
`frankenphp-classic` runs the same pinned FrankenPHP digest as `frankenphp`
(PHP 8.4.24), so the two FrankenPHP entries differ only in mode.

**Database.** The upstream harness already used SQLite, so nothing had to change
to make storage uniform: every runtime uses stock `pdo_sqlite` against a
`database/database.sqlite` seeded at image build with 100 users and 1,000
products.

ePHPm's own embedded database engine (Turso, via litewire's wire-protocol
translation) is deliberately **not** used, and neither is `ephpm/db-laravel`.
This benchmark varies the HTTP request path and holds storage constant.
Measuring ePHPm's embedded database against `pdo_sqlite` is a separate question
needing its own harness, and is not part of these numbers.

**OPcache.** The other images all share `runtimes/php.ini`, including
`frankenphp-classic`, which copies it to the same
`/usr/local/etc/php/conf.d/benchmark.ini` path as the Octane FrankenPHP image.
ePHPm embeds PHP and
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

### The v0.9.0 config rename

ePHPm v0.9.0 renamed the per-request configuration surface. The committed
`runtimes/ephpm*/ephpm.toml` used the old spellings and **would not have
started** on it:

| Before v0.9.0 | v0.9.0 |
| --- | --- |
| `[php] mode = "fpm"` | `[php] mode = "per_request"` |
| `[php] workers` / `[php] worker_count` | `[php] concurrency` (bounds both modes) |
| `[php] worker_backlog` | `[php] queue_depth` |
| `[php] overload_policy` | `[php] overload` |
| `[php] worker_script` | `[php.worker] script` |
| `[php] fpm_engine` | removed |

None of this fails quietly. Every `[php]` key is rejected by name and every
mode-selecting value is an enum, so the old config is a startup error, not a
silent fallback to a default:

```
error: failed to load configuration: unknown variant: found `fpm`,
expected ``per_request` or `worker`` for key "default.php.mode"
```

That is worth stating because the silent-fallback version of this rename would
have been the worst possible outcome for a benchmark: `mode` falling back to its
default and `workers = 2` being ignored would have handed ePHPm an autotuned
concurrency while every other arm stayed at two, and the run would have looked
fine. Both ePHPm arms' startup logs are checked in this recording and report
what the config asked for:

```
php execution configured mode="per_request" concurrency=2
  concurrency_source="explicit" queue_depth=2 admission="fifo" overload="wait"
php execution pool started thread_count=2 backlog=2 admission="fifo"
```

One new v0.9.0 diagnostic shows up in both ePHPm images and is expected here: a
startup warning that OPcache timestamp validation is off while the RESP listener
is disabled, so `ephpm deploy` / `ephpm cache reset` cannot reach the server.
For an immutable benchmark image whose code never changes that is exactly the
intended configuration; the warning is about a deployment workflow this harness
does not have.

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
- **Third recording, one class only.** It measures the three per-request
  runtimes and nothing else, rotated among themselves. That is a deliberate
  narrowing, not an interruption: the worker class was already recorded and the
  question the recording asks — how ePHPm per-request compares to FrankenPHP in
  the mode FrankenPHP defaults to — lives entirely inside the per-request class.
  Because the rotation is over three arms instead of seven, a given arm's rounds
  are ~10 minutes apart rather than ~19.
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

From a clean clone, with nothing edited. Both recordings are one environment
variable apart:

```bash
git clone https://github.com/ephpm/laravel-runtime-comparison
cd laravel-runtime-comparison

# Choose which ephpm binary the two ePHPm images run. Required before either
# command below: runtimes/ephpm-bin/ is gitignored, so a clean clone has no
# binary for the two ePHPm images to copy in.
bash bench/select-ephpm-binary.sh published            # the base image's v0.8.7
bash bench/select-ephpm-binary.sh /path/to/built/ephpm # a local build

# First recording, BENCH_PROFILE=upstream leg -- the harness as it ships,
# database sessions and cache, all seven runtimes queued behind one SQLite
# write lock. This is the default, so the variable can be omitted.
BENCH_PROFILE=upstream \
COMPOSE_CMD="podman compose" \
ROUNDS=3 DURATION=30s COOLDOWN=60 ENDPOINT_COOLDOWN=0 INITIAL_COOLDOWN=60 \
bash bench/run.sh all

# Every differentiating number in this document: BENCH_PROFILE=runtime, array
# sessions and cache. The images rebuild, because the drivers are baked in at
# build time.
BENCH_PROFILE=runtime \
COMPOSE_CMD="podman compose" \
ROUNDS=3 DURATION=30s COOLDOWN=60 ENDPOINT_COOLDOWN=0 INITIAL_COOLDOWN=60 \
bash bench/run.sh all
```

The third recording is the same command narrowed to the per-request class,
against the published v0.9.0 binary:

```bash
bash bench/select-ephpm-binary.sh published            # v0.9.0, the base image's own

BENCH_PROFILE=runtime \
COMPOSE_CMD="podman compose" \
ROUNDS=3 DURATION=30s COOLDOWN=60 ENDPOINT_COOLDOWN=0 INITIAL_COOLDOWN=60 \
RUN_ID=20260903T0650Z-perrequest-v090 \
bash bench/run.sh per-request
```

The first recording's `runtime` leg was one round of 20s
(`ROUNDS=1 DURATION=20s`); everything else about it matches the second command.
The second recording's v0.8.7 "before" leg is the same command restricted to
the two ePHPm entries (`bash bench/run.sh ephpm` and `bash bench/run.sh
ephpm-worker`) after
`bash bench/select-ephpm-binary.sh published`.

Confirm what a run actually measured by reading
`results/<run-id>/<runtime>/run-N/app-config.txt`, which is written from the
compiled config cache inside the container. `bench/run.sh` aborts if it
disagrees with `BENCH_PROFILE`, so a completed run cannot be of the other
profile.

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

| Run ID | Profile | What |
| --- | --- | --- |
| `20260902T001036Z` | `upstream` | First recording, the harness as it ships |
| `20260902T050000Z-main6557152` | `runtime` | Second recording, all seven runtimes on `main` @ 6557152 |
| `20260902T0700Z-v087before` | `runtime` | Second recording, the two ePHPm entries on published v0.8.7 |
| `20260903T0650Z-perrequest-v090` | `runtime` | Third recording, the per-request class on published v0.9.0 |

The first three `settings.txt` files predate the `BENCH_PROFILE` knob and so do
not carry a `bench_profile=` line; the profile for each is stated in the table
above. Runs recorded from here on record it themselves — the third recording's
does. The first recording's `runtime` leg is not among the committed run
directories; its numbers are the tables under "First recording".
