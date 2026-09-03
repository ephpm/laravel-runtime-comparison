#!/usr/bin/env python3
"""Check that no two measurement windows in a sweep overlapped.

The engine's own event log is the preferred evidence for this and is what the
other recordings in RESULTS-EPHPM.md use, but podman's journald event log is not
readable in this VM. This is the fallback: every cell records the UTC instant
`wrk` started and finished, so the windows can be checked for intersection
directly. It is weaker evidence than the event log -- it shows the load
generator never ran twice at once, not that no unrelated container was up -- and
the writeup says so.

    python3 bench/sweep-timeline.py results/<run-id>
"""

import csv
import sys
from datetime import datetime
from pathlib import Path


def main() -> int:
    run_dir = Path(sys.argv[1])
    rows = []
    with (run_dir / "mechanism.csv").open() as fh:
        for r in csv.DictReader(fh):
            rows.append(
                (
                    datetime.strptime(r["started_at"], "%Y-%m-%dT%H:%M:%SZ"),
                    datetime.strptime(r["finished_at"], "%Y-%m-%dT%H:%M:%SZ"),
                    f"{r['driver']} c={r['connections']} r={r['repeat']}",
                )
            )
    rows.sort()

    overlaps = []
    gaps = []
    for (s1, e1, n1), (s2, e2, n2) in zip(rows, rows[1:]):
        if s2 < e1:
            overlaps.append((n1, n2, e1, s2))
        else:
            gaps.append((s2 - e1).total_seconds())

    durations = [(e - s).total_seconds() for s, e, _ in rows]
    print(f"windows:            {len(rows)}")
    print(f"first window start: {rows[0][0]}Z")
    print(f"last window end:    {rows[-1][1]}Z")
    print(f"window length:      min {min(durations):.0f}s  max {max(durations):.0f}s")
    print(f"gap between windows: min {min(gaps):.0f}s  max {max(gaps):.0f}s  median {sorted(gaps)[len(gaps)//2]:.0f}s")
    print(f"OVERLAPPING WINDOWS: {len(overlaps)}")
    for n1, n2, e1, s2 in overlaps:
        print(f"  {n1} ended {e1}Z but {n2} started {s2}Z")
    return 1 if overlaps else 0


if __name__ == "__main__":
    raise SystemExit(main())
