#!/usr/bin/env python3
"""Parse the raw wrk output under results/<run-id>/ into a tidy per-round CSV.

bench/summarize.sh emits average latency and P99 only, averaged across rounds,
and counts timeouts but not error responses. Every tail claim and every
round-to-round spread in RESULTS-EPHPM.md is built from this instead: it pulls
P50/P75/P90/P99 and both error counters, and keeps each round as its own row, so
an averaged number can always be traced back to the rounds behind it.

The `non2xx` column was added for the fourth recording; the CSVs committed for
the first three recordings predate it and do not carry it. The raw `wrk` output
is gitignored, so they cannot be regenerated.

    python3 bench/percentiles.py results/<run-id> > results/<run-id>/percentiles.csv

The raw wrk output it reads is gitignored, as upstream intends; the CSV this
writes is what gets committed.
"""

import csv
import re
import sys
from pathlib import Path

UNIT = {"us": 1e-3, "ms": 1.0, "s": 1e3, "m": 6e4}


def to_ms(tok: str) -> float:
    m = re.fullmatch(r"([0-9.]+)(us|ms|s|m)", tok)
    if not m:
        raise ValueError(tok)
    return float(m.group(1)) * UNIT[m.group(2)]


def parse(path: Path) -> dict:
    out = {}
    for line in path.read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "Latency" and len(f) >= 2 and re.fullmatch(r"[0-9.]+(us|ms|s|m)", f[1]):
            out["avg_ms"] = to_ms(f[1])
        elif f[0] in ("50%", "75%", "90%", "99%") and len(f) >= 2:
            out["p" + f[0][:-1]] = to_ms(f[1])
        elif f[0] == "Requests/sec:":
            out["rps"] = float(f[1])
        elif f[0] == "Socket" and f[1] == "errors:":
            out["timeouts"] = int(f[9])
        elif line.startswith("  Non-2xx or 3xx responses:"):
            out["non2xx"] = int(f[-1])
        elif len(f) >= 4 and f[1] == "requests" and f[2] == "in":
            out["requests"] = int(f[0])
    # wrk prints neither line when the count is zero, so absence is a zero and
    # has to be defaulted rather than left blank. Non-2xx matters as much as
    # timeouts and is not in bench/summarize.sh's output: a runtime that answers
    # a saturated queue with a cheap error response reports a throughput that is
    # not comparable with one that queues, and nothing else in the harness would
    # show it.
    out.setdefault("timeouts", 0)
    out.setdefault("non2xx", 0)
    return out


def main() -> int:
    run_dir = Path(sys.argv[1])
    rows = []
    for rt_dir in sorted(p for p in run_dir.iterdir() if p.is_dir()):
        for round_dir in sorted(rt_dir.glob("run-*")):
            rnd = round_dir.name.split("-")[-1]
            for endpoint in ("health", "static", "cpu", "db"):
                f = round_dir / f"{endpoint}.txt"
                if not f.is_file() or f.stat().st_size == 0:
                    continue
                d = parse(f)
                if "rps" not in d:
                    continue
                rows.append(
                    {
                        "runtime": rt_dir.name,
                        "endpoint": endpoint,
                        "round": rnd,
                        "rps": round(d["rps"], 1),
                        "avg_ms": round(d.get("avg_ms", 0), 2),
                        "p50_ms": round(d.get("p50", 0), 2),
                        "p75_ms": round(d.get("p75", 0), 2),
                        "p90_ms": round(d.get("p90", 0), 2),
                        "p99_ms": round(d.get("p99", 0), 2),
                        "requests": d.get("requests", 0),
                        "timeouts": d["timeouts"],
                        "non2xx": d["non2xx"],
                    }
                )
    w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
