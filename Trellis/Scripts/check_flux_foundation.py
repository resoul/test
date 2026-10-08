#!/usr/bin/env python3
"""R01 audit of an exact Flux revision in an isolated temporary checkout."""
import argparse
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REVISION = '7e98033b26e793e36f3902fdc073f5d26969f6c6'
FIXTURES = ROOT / 'docs/validation/r01-flux'


def replace(path, old, new, count=1):
    source = path.read_text()
    if source.count(old) != count:
        raise RuntimeError(f'Instrumentation mismatch: {path.name}: {old!r}')
    path.write_text(source.replace(old, new))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout', type=Path, default=ROOT.parent / 'old/flux')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    archive = subprocess.check_output(['git', '-C', str(args.checkout), 'archive', REVISION])
    with tempfile.TemporaryDirectory(prefix='trellis-r01-') as directory:
        package = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(package)  # Trusted local git archive, not an uploaded tarball.
        commands = []

        def run(name, extra):
            command = ['swift', 'test', '--package-path', str(package),
                       '-Xswiftc', '-swift-version', '-Xswiftc', '6',
                       '-Xswiftc', '-strict-concurrency=complete', *extra]
            print(f'RUN {name}', flush=True)
            with (args.output / f'{name}.log').open('w') as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            commands.append({'name': name, 'command': command, 'exitCode': result.returncode})
            print(f'{name}: exit {result.returncode}', flush=True)
            return result.returncode

        baseline = run('baseline', [])
        current = package / 'Sources/Flux/Primitives/CurrentValue.swift'
        replace(current, 'let current = await storage.value',
                'let current = await storage.value\n        await R01Hooks.read.hit()', 3)
        replace(current, 'continuation.yield(current)',
                'await R01Hooks.replay.hit()\n                    continuation.yield(current)\n                    await R01Hooks.replayed.hit()')
        core = package / 'Sources/Flux/Core/Flux.swift'
        replace(core, '            guard !Task.isCancelled else { return }\n            subBox.markCompleted()',
                '            await R01Hooks.sinkEnded.hit()\n            guard !Task.isCancelled else { return }\n            subBox.markCompleted()', 2)
        transform = package / 'Sources/Flux/Operators/Flux+Transform.swift'
        replace(transform, '                                guard !Task.isCancelled else { return }\n                                continuation.yield(v)',
                '                                guard !Task.isCancelled else { return }\n                                await R01Hooks.latest.hit()\n                                continuation.yield(v)')
        replace(transform, '                        })\n                    }\n                    innerBox.cancelCurrent()',
                '                        })\n                        await R01Hooks.switched.hit()\n                    }\n                    innerBox.cancelCurrent()')
        shutil.copyfile(FIXTURES / 'Hooks.swift', package / 'Sources/Flux/R01Hooks.swift')
        shutil.copyfile(FIXTURES / 'FoundationAudit.swift', package / 'Tests/FluxTests/R01Audit.swift')
        audit = run('audit', ['--filter', 'R01Audit'])
        (args.output / 'results.json').write_text(json.dumps({
            'revision': REVISION,
            'toolchain': subprocess.check_output(
                ['swift', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
            'environment': {key: os.environ.get(key) for key in ('DEVELOPER_DIR', 'SDKROOT')},
            'commands': commands,
            'meaning': 'Audit assertions characterize known defects; green does not approve dependency.'
        }, indent=2) + '\n')
        return baseline or audit


if __name__ == '__main__':
    raise SystemExit(main())
