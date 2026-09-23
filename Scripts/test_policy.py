#!/usr/bin/env python3
"""Positive/negative policy fixtures, scanner regressions and CLI checks.

Uses unittest and temporary fixture roots, without Swift or third-party packages.
Original eight on-disk fixtures come from Weave; additional Swift fixtures live
in this file so each expected diagnostic stays beside its source.
"""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from check_policy import LINTER_VERSION, ROOT, lint
from swift_lex import mask_swift

DOC = '/// Ownership: value. Isolation: none. Errors: none. Cancellation: none.\n'


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='trellis-policy-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copy2(ROOT / 'policy.json', self.root / 'policy.json')

    def write(self, source, path='Sources/TrellisCore/Fixture.swift'):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
        return target

    def rules(self):
        return [item[0] for item in lint(self.root)]

    def test_original_negative_fixtures(self):
        cases = {
            'platform-import': 'PLATFORM_IMPORT',
            'platform-condition': 'PLATFORM_CONDITION',
            'unsafe-concurrency': 'UNSAFE_CONCURRENCY',
            'cocoa-lifecycle': 'COCOA_LIFECYCLE',
            'secret': 'SECRET_GITHUB_TOKEN',
            'markdown-link': 'MARKDOWN_LINK',
            'public-documentation': 'PUBLIC_DOCUMENTATION',
            'force-operation': 'FORCE_OPERATION',
        }
        for fixture, rule in cases.items():
            with self.subTest(fixture=fixture):
                root = self.root / fixture
                shutil.copytree(ROOT / 'Tests/PolicyFixtures' / fixture, root)
                shutil.copy2(ROOT / 'policy.json', root / 'policy.json')
                result = subprocess.run(
                    [sys.executable, str(ROOT / 'Scripts/check_policy.py'),
                     '--root', str(root), '--expect', rule], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_comment_and_literal_noise_is_ignored(self):
        self.write(r'''// try! bad() fatalError("x") value! import UIKit
/* outer /* inner try! nope() */ nonisolated(unsafe) */
let escaped = "a\" fatalError( and try! and value!"
let raw = ##"import UIKit \" try!"##
let multi = """
try! bad() import UIKit
"""
let rawMulti = #"""
value! nonisolated(unsafe)
"""#
let negative = !flag
let different = a != b
''')
        self.assertEqual(self.rules(), [])

    def test_interpolations_are_executable(self):
        snippets = [
            r'let x = "result \(try! work())"',
            r'let x = #"result \#(try! work())"#',
            r'let x = ##"result \##(try! work())"##',
            'let x = """\nresult \\(try! work())\n"""',
            r'let x = "\(outer("\(try! work())"))"',
            r'let x = "\(value!)"',
        ]
        for snippet in snippets:
            with self.subTest(snippet=snippet):
                self.write(snippet)
                self.assertEqual(self.rules(), ['FORCE_OPERATION'])

    def test_raw_literal_wrong_escape_is_not_interpolation(self):
        self.write(r'let x = ##"\(try! work()) \#(fatalError())"##')
        self.assertEqual(self.rules(), [])

    def test_comment_in_interpolation_and_nested_parentheses(self):
        self.write(r'let x = "\(f(/* ) try! */ (value))) \(try! work())"')
        self.assertEqual(self.rules(), ['FORCE_OPERATION'])

    def test_mask_preserves_offsets(self):
        raw = '/* α\n /* nested */ */\nlet s = """\ntry! ignored()\n"""\ntry! real()\n'
        masked = mask_swift(raw)
        self.assertEqual(len(raw), len(masked.code))
        self.assertEqual([i for i, c in enumerate(raw) if c == '\n'],
                         [i for i, c in enumerate(masked.code) if c == '\n'])
        self.write(raw)
        self.assertEqual([(r[0], r[2]) for r in lint(self.root)], [('FORCE_OPERATION', 6)])

    def test_unclosed_literals_fail_closed(self):
        for source in ['let x = "unterminated', '/* unterminated', r'let x = "\(foo(']:
            with self.subTest(source=source):
                self.write(source)
                self.assertIn('SWIFT_LEXICAL', self.rules())

    def test_public_docs_properties_modifiers_and_attributes(self):
        self.write(DOC + '@MainActor\npublic final class Good {\n' + DOC
                   + '@available(\n macOS 14,\n *\n)\npublic private(set) var value = 0\n}\n')
        # Explicit setter access should not hide the getter's documentation check.
        self.assertEqual(self.rules(), [])
        for declaration in ['public var value: Int { 0 }', 'public let value = 0',
                            'public private(set) var value = 0',
                            'public override init() {}', 'open class Bad {}',
                            'public\nstruct Bad {}']:
            with self.subTest(declaration=declaration):
                self.write(declaration)
                self.assertEqual(self.rules(), ['PUBLIC_DOCUMENTATION'])

    def test_doc_text_does_not_trigger_force_and_is_required(self):
        self.write(DOC + '/// Ready! Example: try! work()\npublic struct Good {}')
        self.assertEqual(self.rules(), [])
        self.write('/// Ownership: value.\npublic struct Missing {}')
        self.assertEqual(self.rules(), ['PUBLIC_DOCUMENTATION'])
        self.write('/** Ownership: value. Isolation: none. Errors: none. Cancellation: none. */\npublic struct Good {}')
        self.assertEqual(self.rules(), [])

    def test_prior_docs_cannot_cover_later_declaration(self):
        self.write(DOC + 'public struct Good {}\npublic struct Bad {}')
        self.assertEqual(self.rules(), ['PUBLIC_DOCUMENTATION'])

    def test_todo_in_comments_only(self):
        self.write('// TODO(C03): implement\n/* FIXME(PROJ-42): follow up */\nlet text = "TODO"')
        self.assertEqual(self.rules(), [])
        self.write('// TODO: lost owner\n/* FIXME(2026-09-10): not a task */')
        self.assertEqual(self.rules(), ['TODO_OWNER', 'TODO_OWNER'])

    def test_secrets_remain_visible_in_comments_and_strings(self):
        tokens = [('gh' + 'p_' + 'a' * 24, 'SECRET_GITHUB_TOKEN'),
                  ('github_' + 'pat_' + 'a' * 24, 'SECRET_GITHUB_TOKEN'),
                  ('xox' + 'b-' + 'a' * 24, 'SECRET_SLACK_TOKEN'),
                  ('AK' + 'IA' + 'A' * 16, 'SECRET_AWS_KEY'),
                  ('-----BEGIN ' + 'PRIVATE KEY-----', 'SECRET_PRIVATE_KEY')]
        for token, rule in tokens:
            for source in [f'// {token}', f'let s = "{token}"']:
                with self.subTest(rule=rule, source_kind=source[:2]):
                    self.write(source)
                    found = lint(self.root)
                    self.assertEqual([v[0] for v in found], [rule])
                    self.assertNotIn(token, str(found))

    def test_guard_if_positive_and_negative(self):
        invalid = [
            'guard ready else { return }\nif ready { work() }',
            'guard\n let a = value,\n check(a)\nelse {\n if failed { return }\n return\n}\nif ready {}',
            'guard values.contains(where: { $0.ok }) else { return }\nif ready {}',
            'guard let x = f({ () -> Bool in return true }) else { return }\nif ready {}',
            'guard ready else { return }; if ready {}',
            'guard ready else { return }\n// comment alone is not blank\nif ready {}',
        ]
        valid = [
            'guard ready else { return }\n\nif ready {}',
            'guard ready else { return }\nguard other else { return }',
            'guard ready else { return }\nwork()',
            'func f() {\n guard ready else { return }\n}',
            'guard ready else { return }\n\n// comment\nif ready {}',
            'guard ready else { throw failure }\nreturn value',
            'if ready { work() }\nreturn value',
        ]
        for source in invalid:
            with self.subTest(source=source):
                self.write(source)
                self.assertEqual(self.rules(), ['GUARD_IF_BLANK_LINE'])
        for source in valid:
            with self.subTest(source=source):
                self.write(source)
                self.assertEqual(self.rules(), [])

    def test_core_import_boundary(self):
        for module in ['QuartzCore', 'CoreGraphics', 'TrellisRender']:
            with self.subTest(module=module):
                self.write(f'import {module}')
                self.assertEqual(self.rules(), ['CORE_IMPORT'])
        self.write('import Foundation')
        self.assertEqual(self.rules(), [])

    def test_render_import_boundary(self):
        self.write('import QuartzCore\nimport CoreGraphics\nimport TrellisCore',
                   'Sources/TrellisRender/Good.swift')
        self.assertEqual(self.rules(), [])
        self.write('@_exported import UIKit', 'Sources/TrellisRender/Bad.swift')
        self.assertEqual(self.rules(), ['PLATFORM_IMPORT'])

    def test_adapter_guards_and_conditions(self):
        path = 'Sources/TrellisUIKit/Host.swift'
        valid = '#if canImport(UIKit)\nimport UIKit\n#endif'
        self.write(valid, path)
        self.assertEqual(self.rules(), [])
        for source in ['import UIKit', '#if canImport(UIKit)\n#else\nimport UIKit\n#endif',
                       '#if canImport(UIKit)\nimport AppKit\n#endif']:
            with self.subTest(source=source):
                self.write(source, path)
                self.assertEqual(self.rules(), ['ADAPTER_GUARD'])
        self.write(valid, path)
        self.write('#if canImport(UIKit)\n#endif')
        self.assertEqual(self.rules(), ['PLATFORM_CONDITION'])

    def test_linear_lookup_narrow_scope(self):
        self.write('let x = items.first { $0.identity == id }', 'Sources/TrellisRender/Bad.swift')
        self.assertEqual(self.rules(), ['LINEAR_IDENTITY_LOOKUP'])
        self.write('let x = items[id]', 'Sources/TrellisRender/Bad.swift')
        self.write('let x = items.first { $0.id == id }')
        self.assertEqual(self.rules(), [])

    def test_markdown_encoded_links_and_code_examples(self):
        self.write('ok', 'docs/file with spaces.md')
        self.write('[ok](file%20with%20spaces.md#heading)\n[ok](<file with spaces.md>)\n'
                   '```md\n[example](missing.md)\n```\n', 'docs/index.md')
        self.assertEqual(self.rules(), [])
        self.write('[missing](absent.md)', 'README.md')
        self.assertEqual(self.rules(), ['MARKDOWN_LINK'])

    def test_generated_paths_and_fixture_trees_are_excluded(self):
        for path in ['.build/Sources/Bad.swift', 'Tests/PolicyFixtures/case/README.md',
                     'DerivedData/a/README.md', 'result.xcresult/README.md']:
            self.write('[missing](absent.md)\ntry! work()', path)
        self.assertEqual(self.rules(), [])

    def test_config_version_and_exact_exception(self):
        config = json.loads((self.root / 'policy.json').read_text())
        config['policyVersion'] = 'old'
        config['allowedExceptions'] = [{'path': 'Sources/*', 'rules': ['FORCE_OPERATION'], 'reason': 'too broad'}]
        (self.root / 'policy.json').write_text(json.dumps(config))
        self.assertEqual(self.rules(), ['ALLOWLIST_REASON', 'POLICY_VERSION'])
        config['policyVersion'] = LINTER_VERSION
        config['allowedExceptions'] = [{'path': 'Sources/TrellisCore/Fixture.swift',
                                        'rules': ['FORCE_OPERATION'], 'reason': 'fixture'}]
        (self.root / 'policy.json').write_text(json.dumps(config))
        self.write('try! work()')
        self.assertEqual(self.rules(), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
