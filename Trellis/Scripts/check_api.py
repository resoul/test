#!/usr/bin/env python3
"""Extract and compare Trellis's public Swift symbol surface, per module and SDK.

Each product module gets a baseline snapshot on the SDK its platform actually
requires: TrellisCore/TrellisRender/TrellisAppKit on macOS, TrellisUIKit on iOS.
TrellisUIKit is additionally probed on tvOS: if its surface differs from the iOS
baseline, a second tvOS-specific baseline is required instead of silently
reusing the iOS one (see docs/implementation-plan.md C04).
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
API_DIR = ROOT / "api"

MODULES = {
    "TrellisCore": {
        "sdk": "macosx", "target": "arm64-apple-macosx14.0", "baseline": "TrellisCore.json",
    },
    "TrellisRender": {
        "sdk": "macosx", "target": "arm64-apple-macosx14.0", "baseline": "TrellisRender.json",
    },
    "TrellisAppKit": {
        "sdk": "macosx", "target": "arm64-apple-macosx14.0", "baseline": "TrellisAppKit.json",
    },
    "TrellisUIKit": {
        "sdk": "iphoneos", "target": "arm64-apple-ios16.0", "baseline": "TrellisUIKit.json",
    },
    # TrellisFlux (R02) depends only on Foundation + the cross-platform Flux package,
    # like TrellisCore/TrellisRender: no UIKit/AppKit import, so no platform-specific
    # surface is expected. A single macOS baseline is extracted, same as those two;
    # verify_bootstrap.py's --matrix still builds/tests it on iOS/tvOS to confirm the
    # dependency itself resolves and compiles there.
    #
    # Known extraction gap (found R03): swift-symbolgraph-extract does not report public
    # API a module adds by extending a type owned by another module (TrellisFlux's
    # `NodeHostBridge.bindFlux(...)`, extending TrellisRender's type) under either module's
    # graph, with or without -emit-extension-block-symbols — the added method is invisible
    # to this baseline regardless. check_policy.py's PUBLIC_DOCUMENTATION rule (which parses
    # source, not the symbol graph) is the actual enforcement for such declarations' docs;
    # a real signature change there is not caught here and needs review by reading the diff.
    "TrellisFlux": {
        "sdk": "macosx", "target": "arm64-apple-macosx14.0", "baseline": "TrellisFlux.json",
    },
}

TVOS_PROBE = {
    "module": "TrellisUIKit", "sdk": "appletvos", "target": "arm64-apple-tvos16.0",
    "baseline": "TrellisUIKit.tvOS.json",
}

MACOS_MODULES_DIR = ROOT / ".build/arm64-apple-macosx/debug/Modules"
XCODE_DERIVED_DATA = ROOT / ".build/api-derived-data"


def run(command: list, env: dict, cwd: Path = ROOT) -> str:
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(" ".join(command) + "\n" + result.stdout + result.stderr)
    return result.stdout


def base_env() -> dict:
    env = os.environ.copy()
    cache = ROOT / ".build/api-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    env["CLANG_MODULE_CACHE_PATH"] = str(cache)
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(cache)
    return env


def build_macos_modules(env: dict) -> Path:
    # SwiftPM's default build system changed from "native" to "swiftbuild" in
    # newer toolchains (Xcode 26+); the new backend writes to .build/out/...
    # instead of .build/<triple>/debug/Modules. Force the native backend so
    # MACOS_MODULES_DIR stays valid regardless of which is the ambient
    # default. "native" is deprecated upstream but still functional; if it is
    # ever removed, this needs to switch to reading the new layout instead.
    run(["xcrun", "--sdk", "macosx", "swift", "build", "--disable-sandbox",
         "--build-system", "native", "-Xswiftc", "-warnings-as-errors"], env)
    if not MACOS_MODULES_DIR.exists():
        raise SystemExit("macOS build did not produce a Modules directory")
    return MACOS_MODULES_DIR


def build_xcode_modules(platform: str, sdk_name: str, product_subdir: str, env: dict) -> Path:
    derived = XCODE_DERIVED_DATA / platform
    run([
        "xcodebuild", "-scheme", "Trellis-Package", "-destination", f"generic/platform={platform}",
        "-derivedDataPath", str(derived), "-disableAutomaticPackageResolution",
        "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=NO", "SWIFT_VERSION=6.0",
        "SWIFT_STRICT_CONCURRENCY=complete", "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "SWIFT_SUPPRESS_WARNINGS=NO", "build",
    ], env)
    modules = derived / "Build" / "Products" / product_subdir
    if not modules.exists():
        raise SystemExit(f"xcodebuild did not produce {modules}")
    return modules


def modules_dir_for(sdk_name: str, env: dict) -> Path:
    if sdk_name == "macosx":
        return build_macos_modules(env)
    if sdk_name == "iphoneos":
        return build_xcode_modules("iOS", sdk_name, "Debug-iphoneos", env)
    if sdk_name == "appletvos":
        return build_xcode_modules("tvOS", sdk_name, "Debug-appletvos", env)
    raise SystemExit(f"Unsupported SDK {sdk_name}")


def normalized_symbol(symbol: dict) -> dict:
    return {
        "accessLevel": symbol.get("accessLevel"),
        "availability": symbol.get("availability", []),
        "declaration": "".join(item.get("spelling", "") for item in symbol["declarationFragments"]),
        "identifier": symbol["identifier"]["precise"],
        "kind": symbol["kind"]["identifier"],
        "pathComponents": symbol["pathComponents"],
    }


def extract(module_name: str, sdk_name: str, target: str, modules_dir: Path, env: dict) -> dict:
    pins = json.loads((ROOT / "toolchain.json").read_text())
    sdk_path = run(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], env).strip()
    with tempfile.TemporaryDirectory(prefix=f"trellis-{module_name}-", dir=ROOT / ".build") as directory:
        run([
            "xcrun", "swift-symbolgraph-extract", "-module-name", module_name,
            "-I", str(modules_dir), "-target", target, "-sdk", sdk_path,
            "-output-dir", directory,
        ], env)
        graph = json.loads((Path(directory) / f"{module_name}.symbols.json").read_text())
    symbols = sorted((normalized_symbol(item) for item in graph["symbols"]), key=lambda item: item["identifier"])
    return {
        "module": module_name, "platform": target, "schemaVersion": 1,
        "symbols": symbols, "toolchain": {"sdk": pins["sdkVersion"], "swift": pins["swiftCompilerVersion"]},
    }


def compare(name: str, baseline_path: Path, current: dict) -> tuple:
    if not baseline_path.exists():
        print(json.dumps({"added": [s["identifier"] for s in current["symbols"]], "changed": [], "removed": []},
                          indent=2))
        return False, [], [], [s["identifier"] for s in current["symbols"]]
    baseline = json.loads(baseline_path.read_text())
    if current == baseline:
        print(f"PASS {name} ({len(current['symbols'])} symbols)")
        return True, [], [], []
    old = {item["identifier"]: item for item in baseline["symbols"]}
    new = {item["identifier"]: item for item in current["symbols"]}
    removed = sorted(old.keys() - new.keys())
    added = sorted(new.keys() - old.keys())
    changed = sorted(identifier for identifier in old.keys() & new.keys() if old[identifier] != new[identifier])
    print(f"DIFF {name}")
    print(json.dumps({"added": added, "changed": changed, "removed": removed}, indent=2))
    return False, removed, changed, added


def write_baseline(baseline_path: Path, current: dict, review_note: Path, removed: list, changed: list) -> None:
    if review_note is None or not review_note.is_file():
        raise SystemExit("FAIL --update requires --review-note pointing to an existing ADR or migration note")
    if (removed or changed) and "adr" not in str(review_note).lower():
        raise SystemExit("FAIL breaking API updates require an ADR file as --review-note")
    API_DIR.mkdir(parents=True, exist_ok=True)
    baseline_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
    print(f"UPDATED {baseline_path.name} after review in {review_note}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", choices=sorted(MODULES), help="restrict to one module")
    parser.add_argument("--update", action="store_true", help="write the baseline instead of comparing")
    parser.add_argument("--review-note", type=Path, help="tracked ADR or migration note for a baseline update")
    parser.add_argument("--tvos", action="store_true", help="also probe TrellisUIKit on tvOS for divergence")
    args = parser.parse_args()
    env = base_env()
    modules = {args.module: MODULES[args.module]} if args.module else MODULES
    failed = False
    for name, spec in modules.items():
        modules_dir = modules_dir_for(spec["sdk"], env)
        current = extract(name, spec["sdk"], spec["target"], modules_dir, env)
        baseline_path = API_DIR / spec["baseline"]
        passed, removed, changed, added = compare(name, baseline_path, current)
        if args.update:
            if passed:
                continue
            write_baseline(baseline_path, current, args.review_note, removed, changed)
            continue
        failed = failed or not passed
    if args.tvos:
        ios_baseline = API_DIR / MODULES["TrellisUIKit"]["baseline"]
        if not ios_baseline.exists():
            raise SystemExit("FAIL --tvos requires an existing TrellisUIKit baseline to diff against")
        modules_dir = modules_dir_for(TVOS_PROBE["sdk"], env)
        tvos_current = extract(TVOS_PROBE["module"], TVOS_PROBE["sdk"], TVOS_PROBE["target"], modules_dir, env)
        ios_baseline_data = json.loads(ios_baseline.read_text())
        tvos_baseline_path = API_DIR / TVOS_PROBE["baseline"]
        same_shape = {**tvos_current, "platform": ios_baseline_data["platform"]}
        if same_shape["symbols"] == ios_baseline_data["symbols"]:
            print("PASS TrellisUIKit tvOS surface matches the iOS baseline; no separate file needed")
            if tvos_baseline_path.exists():
                print("NOTE a stale tvOS-specific baseline exists but is no longer required")
        elif args.update:
            write_baseline(tvos_baseline_path, tvos_current, args.review_note, [], ["tvos-divergence"])
        else:
            passed, *_ = compare("TrellisUIKit (tvOS)", tvos_baseline_path, tvos_current)
            if not passed:
                print("FAIL TrellisUIKit differs between iOS and tvOS; "
                      "run with --update --tvos --review-note <adr> to record a tvOS-specific baseline")
                failed = True
    if args.update:
        return 0
    if failed:
        print("FAIL public API differs; review it and update the baseline explicitly")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
