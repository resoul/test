#!/usr/bin/env python3
"""Exercise TRELLIS_LOG end to end: real process env, real stdout, no injected sink.

Unit tests cover parseLogAreas/formatLogLine/logIfEnabled as pure functions, but
Log.enabled is a static let fixed at first access per process, so "all"/"off"/a
comma list/the unset default can only be told apart across separate process runs.
"""

import json
from pathlib import Path
import subprocess
import sys
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
WORKDIR = ROOT / ".build" / "log-env-check"

AREAS = ("tree", "schedule", "host")


def write_consumer():
    source = WORKDIR / "Sources" / "LogSmoke"
    source.mkdir(parents=True, exist_ok=True)
    package_path = json.dumps(str(ROOT))
    (WORKDIR / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TrellisLogSmoke",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: ''' + package_path + ''')],
    targets: [.executableTarget(name: "LogSmoke", dependencies: [
        .product(name: "TrellisCore", package: "Trellis")
    ])],
    swiftLanguageModes: [.v6]
)
''')
    (source / "LogSmoke.swift").write_text('''import TrellisCore

@main
struct LogSmoke {
    static func main() {
        Log.on(.tree, "created", "kind=Test")
        Log.on(.schedule, "request", host: 1, generation: 41, "frame=390x844")
        Log.on(.host, "mount", host: 1, "bounds=390x844 scale=3.0")
    }
}
''')


def run_smoke(env_value: Optional[str]) -> str:
    import os
    env = os.environ.copy()
    if env_value is None:
        env.pop("TRELLIS_LOG", None)
    else:
        env["TRELLIS_LOG"] = env_value
    result = subprocess.run(
        ["xcrun", "--sdk", "macosx", "swift", "run", "--disable-sandbox", "LogSmoke"],
        cwd=WORKDIR, env=env, text=True, capture_output=True,
    )
    if result.returncode:
        raise SystemExit(f"LogSmoke failed (TRELLIS_LOG={env_value!r}):\n{result.stdout}{result.stderr}")
    return result.stdout


def present_areas(stdout: str) -> set:
    return {area for area in AREAS if f"[trellis.{area}]" in stdout}


def expect(name: str, stdout: str, expected: set) -> list:
    found = present_areas(stdout)
    if found != expected:
        return [f"{name}: expected areas {sorted(expected)}, got {sorted(found)}\n---\n{stdout}"]
    return []


def main() -> int:
    write_consumer()
    failures = []
    failures += expect("unset (DEBUG default)", run_smoke(None), set(AREAS))
    failures += expect("all", run_smoke("all"), set(AREAS))
    failures += expect("off", run_smoke("off"), set())
    failures += expect("list: schedule,commit", run_smoke("schedule,commit"), {"schedule"})
    if failures:
        print("\n\n".join(failures))
        print("FAIL TRELLIS_LOG environment behavior")
        return 1
    print("PASS TRELLIS_LOG environment behavior (unset/all/off/list against real stdout)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
