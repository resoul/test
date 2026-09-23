#!/usr/bin/env python3
"""Run the implemented C03/C04/C05 quality gate: policy, build, tests, API baseline, scenario screenshots, log env."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix', action='store_true', help='also compile generic Apple destinations')
    parser.add_argument('--skip-api', action='store_true',
                        help='skip Scripts/check_api.py (it builds iOS/tvOS via xcodebuild)')
    parser.add_argument('--skip-screenshots', action='store_true',
                        help='skip Scripts/check_screenshots.py (builds and runs Playground-macOS; needs a window server)')
    args = parser.parse_args()
    commands = [
        [sys.executable, 'Scripts/check_policy.py'],
        [sys.executable, 'Scripts/test_policy.py'],
        [sys.executable, 'Scripts/test_verifier.py'],
        [sys.executable, 'Scripts/verify_bootstrap.py', *(['--matrix'] if args.matrix else [])],
    ]
    if not args.skip_api:
        commands.append([sys.executable, 'Scripts/check_api.py', '--tvos'])
    if not args.skip_screenshots:
        commands.append([sys.executable, 'Scripts/check_screenshots.py'])
    commands.append([sys.executable, 'Scripts/check_log_env.py'])
    for command in commands:
        print('RUN ' + ' '.join(command), flush=True)
        result = subprocess.run(command, cwd=ROOT)
        if result.returncode:
            return result.returncode
    print('PASS C03/C04/C05 quality gates.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
