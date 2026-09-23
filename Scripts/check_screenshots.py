#!/usr/bin/env python3
"""Render every Playground scenario on macOS and compare it byte-for-byte with the
reference PNGs in docs/validation/screenshots/macOS.

The reference screenshots are the visual evidence for C19/C24: a layout change that
moves a single pixel in any scenario must show up here as a diff, not be discovered by
eye weeks later (ADR 0006 was found by measuring pixels by hand). `--update` rewrites the
references from the current build and must be paired with a tracked review note (an ADR
or a validation report) that explains why the picture changed, exactly like
check_api.py's baseline update.

Requires the macOS Xcode toolchain; the export runs the Playground-macOS app headlessly
via its `--export-all <dir>` flag (see Playground/macOS/PlaygroundApp.swift).
"""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Playground/Playground.xcodeproj"
SCHEME = "Playground-macOS"
REFERENCE_DIR = ROOT / "docs/validation/screenshots/macOS"
DERIVED_DATA = ROOT / ".build/screenshot-derived-data"


def run(command: list, cwd: Path = ROOT) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(" ".join(command) + "\n" + result.stdout + result.stderr)
    return result.stdout


def build_app() -> Path:
    run(
        [
            "xcodebuild",
            "-project", str(PROJECT),
            "-scheme", SCHEME,
            "-configuration", "Debug",
            "-derivedDataPath", str(DERIVED_DATA),
            "build",
        ]
    )
    app = DERIVED_DATA / "Build/Products/Debug" / f"{SCHEME}.app"
    binary = app / "Contents/MacOS" / SCHEME
    if not binary.exists():
        raise SystemExit(f"built app not found at {binary}")
    return binary


def export(binary: Path, out_dir: Path) -> None:
    # The app resolves `docs/validation/screenshots` relative to its cwd only for the
    # interactive toolbar button; `--export-all` takes an explicit absolute path.
    run([str(binary), "--export-all", str(out_dir)])


def compare(out_dir: Path) -> list:
    problems = []
    rendered = {p.name: p for p in out_dir.glob("*.png")}
    reference = {p.name: p for p in REFERENCE_DIR.glob("*.png")}
    for name in sorted(reference.keys() - rendered.keys()):
        problems.append(f"{name}: reference exists but the scenario was not rendered")
    for name in sorted(rendered.keys() - reference.keys()):
        problems.append(f"{name}: rendered but has no reference (run with --update)")
    for name in sorted(rendered.keys() & reference.keys()):
        if rendered[name].read_bytes() != reference[name].read_bytes():
            problems.append(f"{name}: differs from reference")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="rewrite the reference PNGs from the current build")
    parser.add_argument("--review-note", type=Path, help="tracked ADR or validation note justifying an update")
    parser.add_argument("--keep", type=Path, help="also copy the rendered PNGs to this directory for inspection")
    args = parser.parse_args()

    if args.update:
        if args.review_note is None or not (ROOT / args.review_note).exists():
            raise SystemExit("--update requires --review-note pointing at a tracked ADR or validation note")

    binary = build_app()
    with tempfile.TemporaryDirectory(prefix="trellis-screenshots-") as tmp:
        out_dir = Path(tmp)
        export(binary, out_dir)
        rendered = sorted(out_dir.glob("*.png"))
        if not rendered:
            raise SystemExit("no scenario was exported")
        if args.keep:
            args.keep.mkdir(parents=True, exist_ok=True)
            for png in rendered:
                shutil.copy2(png, args.keep / png.name)

        if args.update:
            REFERENCE_DIR.mkdir(parents=True, exist_ok=True)
            for png in rendered:
                shutil.copy2(png, REFERENCE_DIR / png.name)
            print(f"UPDATED {len(rendered)} reference screenshots (review note: {args.review_note})")
            return 0

        problems = compare(out_dir)
    if problems:
        for line in problems:
            print("FAIL " + line)
        print("Rerun with --keep <dir> to inspect the rendered PNGs; --update --review-note <file> accepts them.")
        return 1
    print(f"PASS {len(rendered)} scenario screenshots match docs/validation/screenshots/macOS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
