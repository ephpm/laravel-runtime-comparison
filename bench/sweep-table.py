#!/usr/bin/env python3
"""Turn a bench/session-sweep.sh result tree into a tidy CSV and a Markdown table.

The sweep's question is the *shape* of throughput against concurrency, so the
per-cell rows are kept (one per driver x connections x repeat) and the summary
reports mean with the observed min-max range rather than a mean alone. A flat
mean with a wide range and a rising mean with a narrow range are different
findings and collapsing them would hide that.

    python3 bench/sweep-table.py results/<run-id>

Writes <run-id>/sweep.csv and prints the Markdown tables.
"""

import csv
import re
import statistics
import sys
from pathlib import Path

UNIT = {"us": 1e-3, "ms": 1.0, "s": 1e3, "m": 6e4}
DRIVER_ORDER = ["array", "file", "file-nogc", "redis", "database"]


def to_ms(tok: str) -> float:
    m = re.fullmatch(r"([0-9.]+)(us|ms|s|m)", tok)
    if not m:
        raise ValueError(tok)
    return float(m.group(1)) * UNIT[m.group(2)]


def parse_wrk(path: Path) -> dict:
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
    # wrk omits both error lines entirely when the count is zero, so absence is
    # a zero rather than missing data.
    out.setdefault("timeouts", 0)
    out.setdefault("non2xx", 0)
    return out


def main() -> int:
    run_dir = Path(sys.argv[1])
    rows = []
    for driver_dir in sorted(p for p in run_dir.iterdir() if p.is_dir()):
        for conn_dir in sorted(driver_dir.glob("c*")):
            conns = int(conn_dir.name[1:])
            for rep_dir in sorted(conn_dir.glob("repeat-*")):
                f = rep_dir / "wrk.txt"
                if not f.is_file() or not f.stat().st_size:
                    continue
                d = parse_wrk(f)
                if "rps" not in d:
                    continue
                rows.append(
                    {
                        "driver": driver_dir.name,
                        "connections": conns,
                        "repeat": int(rep_dir.name.split("-")[-1]),
                        "rps": round(d["rps"], 1),
                        "avg_ms": round(d.get("avg_ms", 0), 2),
                        "p50_ms": round(d.get("p50", 0), 2),
                        "p90_ms": round(d.get("p90", 0), 2),
                        "p99_ms": round(d.get("p99", 0), 2),
                        "requests": d.get("requests", 0),
                        "timeouts": d["timeouts"],
                        "non2xx": d["non2xx"],
                    }
                )

    rows.sort(key=lambda r: (DRIVER_ORDER.index(r["driver"]) if r["driver"] in DRIVER_ORDER else 99,
                             r["connections"], r["repeat"]))
    out_csv = run_dir / "sweep.csv"
    with out_csv.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    drivers = [d for d in DRIVER_ORDER if any(r["driver"] == d for r in rows)]
    conns = sorted({r["connections"] for r in rows})

    def cells(driver, c):
        return [r for r in rows if r["driver"] == driver and r["connections"] == c]

    def fmt(vals, nd=0):
        if not vals:
            return "-"
        m = statistics.mean(vals)
        return f"{m:,.{nd}f} [{min(vals):,.{nd}f}-{max(vals):,.{nd}f}]"

    print(f"\nWrote {out_csv}\n")

    print("### Throughput, req/s — mean [min-max] across repeats\n")
    print("| conns | " + " | ".join(drivers) + " |")
    print("| --- | " + " | ".join("---" for _ in drivers) + " |")
    for c in conns:
        print(f"| {c} | " + " | ".join(fmt([r["rps"] for r in cells(d, c)]) for d in drivers) + " |")

    print("\n### P99 latency, ms — mean [min-max] across repeats\n")
    print("| conns | " + " | ".join(drivers) + " |")
    print("| --- | " + " | ".join("---" for _ in drivers) + " |")
    for c in conns:
        print(f"| {c} | " + " | ".join(fmt([r["p99_ms"] for r in cells(d, c)], 1) for d in drivers) + " |")

    print("\n### Scaling factor vs the same driver at 1 connection\n")
    print("| conns | " + " | ".join(drivers) + " |")
    print("| --- | " + " | ".join("---" for _ in drivers) + " |")
    base = {d: statistics.mean([r["rps"] for r in cells(d, 1)]) for d in drivers if cells(d, 1)}
    for c in conns:
        out = []
        for d in drivers:
            v = cells(d, c)
            out.append(f"{statistics.mean([r['rps'] for r in v]) / base[d]:.2f}x" if v and d in base else "-")
        print(f"| {c} | " + " | ".join(out) + " |")

    print("\n### Ratio to `database` at the same concurrency\n")
    print("| conns | " + " | ".join(drivers) + " |")
    print("| --- | " + " | ".join("---" for _ in drivers) + " |")
    for c in conns:
        db = cells("database", c)
        out = []
        for d in drivers:
            v = cells(d, c)
            if v and db:
                out.append(f"{statistics.mean([r['rps'] for r in v]) / statistics.mean([r['rps'] for r in db]):.1f}x")
            else:
                out.append("-")
        print(f"| {c} | " + " | ".join(out) + " |")

    print("\n### Errors — total timeouts / non-2xx across all repeats\n")
    print("| conns | " + " | ".join(drivers) + " |")
    print("| --- | " + " | ".join("---" for _ in drivers) + " |")
    for c in conns:
        out = []
        for d in drivers:
            v = cells(d, c)
            out.append(f"{sum(r['timeouts'] for r in v)} / {sum(r['non2xx'] for r in v)}" if v else "-")
        print(f"| {c} | " + " | ".join(out) + " |")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
