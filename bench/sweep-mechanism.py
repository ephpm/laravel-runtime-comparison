#!/usr/bin/env python3
"""Session writes per second, per driver per connection level.

This is the most direct evidence the sweep produces. Each cell runs in a fresh
container and `wrk` never returns a cookie, so every request mints a new session
id and the store's size at the end of a cell IS the number of session writes that
cell performed. Dividing by the window length gives the store's actual sustained
write rate.

A store that is not a contention point tracks the runtime: its write rate rises
with concurrency until the workers saturate. A store behind one global writer
lock has a ceiling, and that ceiling is the same number at 1 connection and at
100 -- which is what "serialised" means, stated as a rate rather than inferred
from a throughput curve.

    python3 bench/sweep-mechanism.py results/<run-id> [window_seconds]
"""

import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

DRIVER_ORDER = ["array", "file", "file-nogc", "redis", "database"]


def main() -> int:
    run_dir = Path(sys.argv[1])
    window = float(sys.argv[2]) if len(sys.argv) > 2 else 25.0

    # The warm-up requests land in the store before the window opens, so they are
    # subtracted out; the sweep issues WARMUP_REQUESTS plus one readiness probe.
    warmup = 201

    by = defaultdict(list)
    with (run_dir / "mechanism.csv").open() as fh:
        for row in csv.DictReader(fh):
            if row["sessions_written"] in ("", "NA"):
                continue
            written = int(row["sessions_written"])
            if row["driver"] != "array":
                written -= warmup
            by[(row["driver"], int(row["connections"]))].append(max(written, 0) / window)

    drivers = [d for d in DRIVER_ORDER if any(k[0] == d for k in by)]
    conns = sorted({k[1] for k in by})

    print("\n### Session writes per second — mean [min-max] across repeats\n")
    print("| conns | " + " | ".join(drivers) + " |")
    print("| --- | " + " | ".join("---" for _ in drivers) + " |")
    for c in conns:
        cells = []
        for d in drivers:
            v = by.get((d, c))
            if not v:
                cells.append("-")
            elif d == "array":
                cells.append("0 (no persistence)")
            else:
                cells.append(f"{statistics.mean(v):,.0f} [{min(v):,.0f}-{max(v):,.0f}]")
        print(f"| {c} | " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
