#!/usr/bin/env python3

import csv
import html
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RUNTIME_NAMES = {
    "frankenphp": "FrankenPHP",
    "swoole": "Swoole",
    "openswoole": "OpenSwoole",
    "roadrunner": "RoadRunner",
    "nginx-fpm": "Nginx with PHP FPM",
    "ephpm": "ePHPm (per-request)",
    "ephpm-worker": "ePHPm (worker)",
    "frankenphp-classic": "FrankenPHP (classic)",
}
ENDPOINT_NAMES = {
    "db": "Database",
    "health": "Health",
    "static": "Static JSON",
    "cpu": "CPU",
}


def svg_text(x, y, value, size=14, weight=400, anchor="start", fill="#202124"):
    return (
        f'<text x="{x}" y="{y}" font-family="Arial, Helvetica, sans-serif" '
        f'font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" '
        f'fill="{fill}">{html.escape(str(value))}</text>'
    )


def read_summary(path):
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    required = {
        "runtime",
        "endpoint",
        "runs",
        "avg_requests_per_sec",
        "min_requests_per_sec",
        "max_requests_per_sec",
        "avg_p99_latency_ms",
    }
    if not rows or not required.issubset(rows[0]):
        raise ValueError("summary.csv does not contain the expected benchmark columns")

    for row in rows:
        row["runs"] = int(row["runs"])
        for key in (
            "avg_requests_per_sec",
            "min_requests_per_sec",
            "max_requests_per_sec",
            "avg_p99_latency_ms",
        ):
            row[key] = float(row[key])
        row["total_timeout_errors"] = int(row.get("total_timeout_errors", 0))
    return rows


def throughput_chart(endpoint, rows, output_dir, run_id):
    values = sorted(
        (row for row in rows if row["endpoint"] == endpoint),
        key=lambda row: row["avg_requests_per_sec"],
        reverse=True,
    )
    if len(values) != len(RUNTIME_NAMES):
        raise ValueError(f"missing runtime data for endpoint: {endpoint}")

    width = 900
    height = 455
    plot_left = 210
    plot_right = 760
    plot_top = 135
    row_gap = 55
    max_value = max(row["max_requests_per_sec"] for row in values) * 1.12

    def scale(value):
        return plot_left + value / max_value * (plot_right - plot_left)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        '<rect width="900" height="455" fill="#ffffff"/>',
        f'<title id="title">{ENDPOINT_NAMES[endpoint]} endpoint throughput</title>',
        '<desc id="desc">Average requests per second for each PHP runtime. Thin lines show the lowest and highest result from three runs.</desc>',
        svg_text(35, 44, f'{ENDPOINT_NAMES[endpoint]} endpoint throughput', 25, 500),
        svg_text(35, 73, "Average requests per second across three runs", 15, 400, fill="#5f6368"),
        svg_text(35, 96, "Thin lines show the lowest and highest run", 13, 400, fill="#5f6368"),
    ]

    for tick in range(5):
        value = max_value * tick / 4
        x = scale(value)
        parts.append(f'<line x1="{x:.1f}" y1="{plot_top - 15}" x2="{x:.1f}" y2="{plot_top + row_gap * 4 + 32}" stroke="#e5e7eb" stroke-width="1"/>')
        parts.append(svg_text(f"{x:.1f}", plot_top - 24, f"{value:.0f}", 12, 400, "middle", "#6b7280"))

    for index, row in enumerate(values):
        y = plot_top + index * row_gap
        average_x = scale(row["avg_requests_per_sec"])
        min_x = scale(row["min_requests_per_sec"])
        max_x = scale(row["max_requests_per_sec"])
        color = "#16839a" if index == 0 else "#9ca3af"
        parts.append(svg_text(plot_left - 15, y + 6, RUNTIME_NAMES[row["runtime"]], 14, 400, "end"))
        parts.append(f'<rect x="{plot_left}" y="{y - 13}" width="{average_x - plot_left:.1f}" height="26" fill="{color}"/>')
        parts.append(f'<line x1="{min_x:.1f}" y1="{y}" x2="{max_x:.1f}" y2="{y}" stroke="#374151" stroke-width="2"/>')
        parts.append(f'<line x1="{min_x:.1f}" y1="{y - 6}" x2="{min_x:.1f}" y2="{y + 6}" stroke="#374151" stroke-width="2"/>')
        parts.append(f'<line x1="{max_x:.1f}" y1="{y - 6}" x2="{max_x:.1f}" y2="{y + 6}" stroke="#374151" stroke-width="2"/>')
        parts.append(svg_text(850, y + 5, f'{row["avg_requests_per_sec"]:.1f}', 13, 500, "end"))

    timeout_rows = [row for row in values if row["total_timeout_errors"]]
    if timeout_rows:
        timeout_note = ", ".join(
            f'{RUNTIME_NAMES[row["runtime"]]} recorded {row["total_timeout_errors"]}'
            for row in timeout_rows
        )
        parts.append(
            svg_text(
                35,
                408,
                f"{timeout_note} socket timeouts across the three runs.",
                12,
                500,
                fill="#9a3412",
            )
        )
    parts.append(svg_text(35, 431, f"Source: benchmark run {run_id}, three runs", 12, 400, fill="#6b7280"))
    parts.append("</svg>")
    (output_dir / f"{endpoint}-throughput.svg").write_text("\n".join(parts) + "\n", encoding="utf-8")


def tail_latency_chart(rows, output_dir, run_id):
    width = 900
    height = 710
    panel_width = 410
    panel_height = 270
    positions = [(35, 110), (460, 110), (35, 400), (460, 400)]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        '<rect width="900" height="710" fill="#ffffff"/>',
        '<title id="title">Tail latency by endpoint</title>',
        '<desc id="desc">Average 99th percentile latency for each PHP runtime across three runs. Lower values are better.</desc>',
        svg_text(35, 44, "Tail latency by endpoint", 25, 500),
        svg_text(35, 73, "Average P99 latency in milliseconds across three runs. Lower is better.", 15, 400, fill="#5f6368"),
    ]

    for endpoint, (left, top) in zip(("db", "health", "static", "cpu"), positions):
        values = sorted(
            (row for row in rows if row["endpoint"] == endpoint),
            key=lambda row: row["avg_p99_latency_ms"],
        )
        max_value = max(row["avg_p99_latency_ms"] for row in values) * 1.18
        plot_left = left + 135
        plot_right = left + panel_width - 20
        parts.append(svg_text(left, top, ENDPOINT_NAMES[endpoint], 17, 500))

        for index, row in enumerate(values):
            y = top + 42 + index * 38
            x = plot_left + row["avg_p99_latency_ms"] / max_value * (plot_right - plot_left)
            color = "#16839a" if index == 0 else "#9ca3af"
            parts.append(svg_text(plot_left - 12, y + 5, RUNTIME_NAMES[row["runtime"]], 12, 400, "end"))
            parts.append(f'<line x1="{plot_left}" y1="{y}" x2="{plot_right}" y2="{y}" stroke="#eceff1" stroke-width="1"/>')
            parts.append(f'<circle cx="{x:.1f}" cy="{y}" r="6" fill="{color}"/>')
            label_anchor = "end" if x > plot_right - 42 else "start"
            label_x = x - 9 if label_anchor == "end" else x + 9
            parts.append(svg_text(f"{label_x:.1f}", y + 5, f'{row["avg_p99_latency_ms"]:.0f}', 12, 500, label_anchor))

    parts.append(svg_text(35, 690, f"Source: benchmark run {run_id}, three runs", 12, 400, fill="#6b7280"))
    parts.append("</svg>")
    (output_dir / "tail-latency.svg").write_text("\n".join(parts) + "\n", encoding="utf-8")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {Path(sys.argv[0]).name} <run-id>")

    run_id = sys.argv[1]
    result_root = Path(os.environ.get("RESULT_ROOT", ROOT / "results"))
    output_dir = Path(os.environ.get("CHART_OUTPUT_DIR", ROOT / "docs" / "charts"))
    summary = result_root / run_id / "summary.csv"
    rows = read_summary(summary)
    if any(row["runs"] < 3 for row in rows):
        raise ValueError("charts require at least three completed runs per runtime and endpoint")

    output_dir.mkdir(parents=True, exist_ok=True)
    for endpoint in ("db", "health", "static", "cpu"):
        throughput_chart(endpoint, rows, output_dir, run_id)
    tail_latency_chart(rows, output_dir, run_id)
    print(f"Charts written to {output_dir}")


if __name__ == "__main__":
    main()
