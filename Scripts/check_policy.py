#!/usr/bin/env python3
"""Deterministic Trellis policy checks, using only the Python standard library.

Derived from Weave check_policy.py. This is a narrow lexical linter, not a
Swift compiler or proof of complexity. See policy.json for rule boundaries.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

from swift_lex import mask_swift

LINTER_VERSION = "2.0.0"
ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '.build', '.swiftpm', 'DerivedData', 'PolicyFixtures',
           'xcuserdata', '__pycache__'}
REQUIRED_DOCS = ('Ownership:', 'Isolation:', 'Errors:', 'Cancellation:')
TOKEN = re.compile(r'\b[A-Za-z_][A-Za-z_0-9]*\b|[^\s]')
DECLARATION = re.compile(
    r'\b(?P<access>public|open)\b(?!\s*\(\s*set\s*\))\s+'
    r'(?:(?:(?:private|internal|fileprivate)\s*\(\s*set\s*\)|final|indirect|static|class|override|required|convenience|mutating|'
    r'nonmutating|nonisolated|distributed|lazy|weak|unowned)\s+)*'
    r'(?P<kind>class|struct|enum|protocol|actor|func|init|deinit|typealias|'
    r'var|let|subscript|extension)\b'
)
PATTERNS = {
    'UNSAFE_CONCURRENCY': re.compile(
        r'@unchecked\s+Sendable|nonisolated\s*\(\s*unsafe\s*\)|@preconcurrency'),
    'FORCE_OPERATION': re.compile(r'\btry\s*!|\bfatalError\s*\(|(?<=[\w\]\)])!(?!=)'),
    'COCOA_LIFECYCLE': re.compile(
        r'\b(?:viewDidLoad|loadView|viewWillAppear|viewDidAppear|'
        r'applicationDidFinishLaunching|sceneDidBecomeActive)\b'),
    'PLATFORM_CONDITION': re.compile(r'#(?:if|elseif)\s+os\s*\('),
}
SECRETS = {
    'SECRET_PRIVATE_KEY': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'SECRET_GITHUB_TOKEN': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'),
    'SECRET_SLACK_TOKEN': re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{16,}\b'),
    'SECRET_AWS_KEY': re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
}


def files(root):
    # Prune generated directories instead of traversing a potentially huge .build.
    for directory, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in IGNORED and not d.endswith('.xcresult')
                         and not (Path(directory) / d).is_symlink())
        for name in sorted(names):
            path = Path(directory) / name
            if not path.is_symlink():
                yield path, path.relative_to(root).as_posix()


def guard_if_offsets(code, raw):
    tokens = list(TOKEN.finditer(code))
    for index, token in enumerate(tokens):
        if token.group() != 'guard':
            continue
        stack = []
        cursor = index + 1
        while cursor < len(tokens):
            value = tokens[cursor].group()
            if value == 'else' and not stack:
                break
            if value in '([{':
                stack.append(value)
            elif value in ')]}' and stack:
                stack.pop()
            cursor += 1
        if cursor + 1 >= len(tokens) or tokens[cursor + 1].group() != '{':
            continue
        cursor += 2
        depth = 1
        while cursor < len(tokens) and depth:
            value = tokens[cursor].group()
            depth += (value == '{') - (value == '}')
            cursor += 1
        if depth or cursor >= len(tokens):
            continue
        end = tokens[cursor - 1].end()
        if tokens[cursor].group() == ';':
            cursor += 1
        if cursor < len(tokens) and tokens[cursor].group() == 'if':
            between = raw[end:tokens[cursor].start()]
            if not re.search(r'\n[ \t\r]*\n', between):
                yield tokens[cursor].start()


def documentation_before(offset, raw, masked):
    # Attributes can be multiline. Remove them from the gap between documentation
    # and declaration, preserving balanced argument lists and source positions.
    attributes = []
    for match in re.finditer(r'@\w+(?:\.\w+)*', masked.code[:offset]):
        end = match.end()
        cursor = end
        while cursor < offset and masked.code[cursor].isspace():
            cursor += 1
        if cursor < offset and masked.code[cursor] == '(':
            depth = 1
            cursor += 1
            while cursor < offset and depth:
                depth += (masked.code[cursor] == '(') - (masked.code[cursor] == ')')
                cursor += 1
            end = cursor
        attributes.append((match.start(), end))
    gap = list(masked.code[:offset])
    for start, end in attributes:
        gap[start:end] = ' ' * (end - start)
    gap = ''.join(gap)
    docs = []
    cursor = offset
    for start, end in reversed(masked.comments):
        if end > cursor:
            continue
        if gap[end:cursor].strip():
            break
        comment = raw[start:end]
        if not comment.startswith(('///', '/**')):
            break
        docs.append(comment)
        cursor = start
    return '\n'.join(reversed(docs))


def lint(root):
    violations = []
    try:
        policy = json.loads((root / 'policy.json').read_text())
        if not isinstance(policy, dict):
            raise ValueError('policy must be an object')
    except (OSError, ValueError) as error:
        return [('POLICY_CONFIG', 'policy.json', 1, str(error))]
    if policy.get('policyVersion') != LINTER_VERSION:
        violations.append(('POLICY_VERSION', 'policy.json', 1, 'policy and linter versions differ'))
    exceptions = policy.get('allowedExceptions', [])
    if not isinstance(exceptions, list):
        return [('POLICY_CONFIG', 'policy.json', 1, 'allowedExceptions must be a list')]
    for item in exceptions:
        if (not isinstance(item, dict) or not isinstance(item.get('path'), str)
                or not item.get('rules') or not item.get('reason')
                or any(c in item['path'] for c in '*?[')
                or '..' in Path(item['path']).parts or Path(item['path']).is_absolute()):
            violations.append(('ALLOWLIST_REASON', 'policy.json', 1,
                               'exception requires an exact relative path, rules and reason'))
    valid_exceptions = [item for item in exceptions if isinstance(item, dict)]

    def emit(rule, relative, raw, offset, detail):
        if any(item.get('path') == relative and rule in item.get('rules', [])
               and item.get('reason') for item in valid_exceptions):
            return
        violations.append((rule, relative, raw.count('\n', 0, offset) + 1, detail))

    platform_modules = {'UIKit', 'AppKit', 'Cocoa', 'SwiftUI', 'Metal'}
    prefixes = tuple(policy.get('platformImplementationPrefixes', []))
    for path, relative in files(root):
        try:
            raw = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            continue
        except OSError as error:
            violations.append(('READ_ERROR', relative, 1, str(error)))
            continue
        for rule, pattern in SECRETS.items():
            for match in pattern.finditer(raw):
                # Never print the matched credential.
                emit(rule, relative, raw, match.start(), 'possible credential')
        if relative.endswith(('.swift', '.swift.fixture')) and relative.startswith('Sources/'):
            masked = mask_swift(raw)
            code = masked.code
            platform = relative.startswith(prefixes)
            for offset, message in masked.errors:
                emit('SWIFT_LEXICAL', relative, raw, offset, message)
            for rule, pattern in PATTERNS.items():
                if rule == 'COCOA_LIFECYCLE' and platform:
                    continue
                for match in pattern.finditer(code):
                    emit(rule, relative, raw, match.start(), rule.lower().replace('_', ' '))
            imports = re.finditer(r'\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)', code)
            for match in imports:
                module = match.group(1)
                if module in platform_modules and not platform:
                    emit('PLATFORM_IMPORT', relative, raw, match.start(), 'native import outside adapter')
                if relative.startswith('Sources/TrellisCore/') and module != 'Foundation':
                    emit('CORE_IMPORT', relative, raw, match.start(), 'Core permits only Foundation')
                if module in platform_modules and platform:
                    expected = 'UIKit' if relative.startswith('Sources/TrellisUIKit/') else 'AppKit'
                    conditions = []
                    for directive in re.finditer(r'(?m)^\s*#(if|elseif|else|endif)\b([^\n]*)', code[:match.start()]):
                        kind, expression = directive.group(1), directive.group(2).strip()
                        enabled = expression == f'canImport({expected})'
                        if kind == 'if':
                            conditions.append(enabled)
                        elif kind in {'else', 'elseif'} and conditions:
                            conditions[-1] = enabled if kind == 'elseif' else False
                        elif kind == 'endif' and conditions:
                            conditions.pop()
                    if not any(conditions) or module in ({'AppKit', 'Cocoa'} if expected == 'UIKit' else {'UIKit'}):
                        emit('ADAPTER_GUARD', relative, raw, match.start(), 'native import needs matching canImport host guard')
            if not platform:
                for match in re.finditer(r'\bcanImport\s*\(', code):
                    emit('PLATFORM_CONDITION', relative, raw, match.start(), 'canImport belongs in adapter files')
            for declaration in DECLARATION.finditer(code):
                docs = documentation_before(declaration.start(), raw, masked)
                if not all(field in docs for field in REQUIRED_DOCS):
                    emit('PUBLIC_DOCUMENTATION', relative, raw, declaration.start(),
                         'missing ownership/isolation/errors/cancellation documentation')
            for start, end in masked.comments:
                for match in re.finditer(r'\b(?:TODO|FIXME)\b(?!\([A-Z][A-Z0-9]*-?\d+\))', raw[start:end]):
                    emit('TODO_OWNER', relative, raw, start + match.start(), 'use TODO(C03) or FIXME(PROJ-123)')
            for offset in guard_if_offsets(code, raw):
                emit('GUARD_IF_BLANK_LINE', relative, raw, offset, 'separate guard and following if with a blank line')
            if relative.startswith(('Sources/TrellisCore/Layout/', 'Sources/TrellisRender/')):
                for match in re.finditer(r'\.first\s*\{\s*\$0\.(?:identity|id)\s*==', code):
                    emit('LINEAR_IDENTITY_LOOKUP', relative, raw, match.start(), 'use indexed identity lookup')
        if relative.endswith(('.md', '.md.fixture')):
            # Ignore code examples; percent-encoded relative paths are legitimate links.
            prose = re.sub(r'(?ms)^```[^\n]*\n.*?^```[^\n]*$',
                           lambda m: ''.join('\n' if c == '\n' else ' ' for c in m.group()), raw)
            for match in re.finditer(r'(?<!!)\[[^\]]+\]\(([^)]+)\)', prose):
                target = match.group(1).strip()
                if target.startswith('<') and '>' in target:
                    target = target[1:target.index('>')]
                else:
                    target = re.split(r'\s+["\']', target, maxsplit=1)[0]
                url = urlsplit(target)
                if not url.path or url.scheme or url.netloc:
                    continue
                if not (path.parent / unquote(url.path)).exists():
                    emit('MARKDOWN_LINK', relative, raw, match.start(), target)
    return sorted(violations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--version', action='store_true')
    parser.add_argument('--expect', help='require this diagnostic (fixture compatibility)')
    args = parser.parse_args()
    if args.version:
        print(LINTER_VERSION)
        return 0
    violations = lint(args.root.resolve())
    for rule, path, line, detail in violations:
        print(f'{path}:{line}: {rule}: {detail}')
    passed = any(v[0] == args.expect for v in violations) if args.expect else not violations
    print(f'{"PASS" if passed else "FAIL"} policy {LINTER_VERSION} ({len(violations)} diagnostics)')
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
