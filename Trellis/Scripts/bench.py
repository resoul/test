#!/usr/bin/env python3
"""Build and run the C31 measurement harness (Bench/), then store the result.

Release build, TRELLIS_LOG=off unless --log is given. The JSON report goes to
docs/validation/measurements/<date>-<label>.json and a Markdown summary is printed (and
written next to it with --write-summary) so a card report can paste it. Measurements are
evidence, not a gate: nothing here fails on a timing. Counters that must be exact are
asserted by TrellisRenderTests (HostRenderStatisticsTests) instead.
"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "Bench"
OUT_DIR = ROOT / "docs/validation/measurements"


def run(command, env, cwd):
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(" ".join(map(str, command)) + "\n" + result.stdout + result.stderr)
    return result.stdout


def summary(report: dict) -> str:
    lines = [
        f"Дата {report['date']} · {report['host']} · {report['os']} · "
        f"{report['configuration']} · TRELLIS_LOG={report['logMode']} · итераций {report['iterations']}",
        "",
        "| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |",
        "|---|---|---|---|---|---|",
    ]
    for fixture in report["fixtures"]:
        params = ", ".join(f"{k}={v}" for k, v in sorted(fixture["parameters"].items()))
        for name, samples in sorted(fixture["timingsMs"].items()):
            lines.append(
                f"| {fixture['name']} | {params} | {name} | {samples['p50']} | {samples['p95']} | {samples['max']} |"
            )
    lines += ["", "| Fixture | Счётчики | Память MiB | Заметки |", "|---|---|---|---|"]
    for fixture in report["fixtures"]:
        counters = ", ".join(f"{k}={v}" for k, v in sorted(fixture["counters"].items())) or "—"
        memory = ", ".join(f"{k}={v}" for k, v in sorted(fixture["memoryMiB"].items())) or "—"
        notes = "; ".join(fixture["notes"]) or "—"
        lines.append(f"| {fixture['name']} | {counters} | {memory} | {notes} |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--label", default=f"macos-{platform.machine()}")
    parser.add_argument("--log", default="off", help="TRELLIS_LOG value; 'all' measures diagnostics overhead")
    parser.add_argument("--debug", action="store_true", help="build the harness in debug instead of release")
    parser.add_argument("--write-summary", action="store_true", help="also write the Markdown summary next to the JSON")
    args = parser.parse_args()

    env = os.environ.copy()
    configuration = "debug" if args.debug else "release"
    run(["swift", "build", "-c", configuration], env, BENCH)
    binary = BENCH / ".build" / configuration / "TrellisBench"
    env["TRELLIS_LOG"] = args.log
    env["TRELLIS_BENCH_ITERATIONS"] = str(args.iterations)
    env["TRELLIS_BENCH_CONFIGURATION"] = configuration
    with tempfile.TemporaryDirectory(prefix="trellis-bench-") as tmp:
        report_path = Path(tmp) / "report.json"
        env["TRELLIS_BENCH_OUTPUT"] = str(report_path)
        # The log (when on) shares stdout with nothing else now; keep it out of the terminal.
        subprocess.run([str(binary)], cwd=BENCH, env=env, text=True, capture_output=True, check=True)
        report = json.loads(report_path.read_text())

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.date.today().isoformat()
    suffix = "" if args.log == "off" else f"-log-{args.log}"
    path = OUT_DIR / f"{stamp}-{args.label}-{configuration}{suffix}.json"
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    text = summary(report)
    print(text)
    if args.write_summary:
        path.with_suffix(".md").write_text(text + "\n")
    print(f"\nWROTE {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
