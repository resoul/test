#!/usr/bin/env python3
"""Exercise fail-closed manifest and command handling without Xcode."""

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

from verify_bootstrap import (
    ALLOWED_DEPENDENCY_REQUIREMENT, ALLOWED_DEPENDENCY_URL, PRODUCTS, ROOT, Verification, manifest_issues,
)

FLUX_DEPENDENCY = {
    'sourceControl': [{
        'location': {'remote': [{'urlString': ALLOWED_DEPENDENCY_URL}]},
        'requirement': ALLOWED_DEPENDENCY_REQUIREMENT,
    }],
}
FLUX_PRODUCT_DEPENDENCY = {'product': ['Flux', 'flux', None, None]}


class VerifierTests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((ROOT / 'toolchain.json').read_text())
        all_targets = PRODUCTS | {'TrellisCoreTests', 'TrellisRenderTests', 'TrellisFluxTests'}
        self.manifest = {
            'name': 'Trellis', 'dependencies': [FLUX_DEPENDENCY], 'swiftLanguageVersions': ['6'],
            'toolsVersion': {'_version': '6.0.0'},
            'platforms': [{'platformName': k, 'version': v} for k, v in
                          {'macos': '14.0', 'ios': '16.0', 'tvos': '16.0'}.items()],
            'products': [{'name': name, 'targets': [name], 'type': {'library': ['automatic']}}
                         for name in PRODUCTS],
            'targets': [
                {'name': name, 'dependencies': [FLUX_PRODUCT_DEPENDENCY] if name == 'TrellisFlux' else []}
                for name in all_targets
            ],
        }

    def test_valid_manifest(self):
        self.assertEqual(manifest_issues(self.manifest, self.pins), [])

    def test_reject_contract_regressions(self):
        replacements = [('dependencies', []),
                        ('dependencies', [{'sourceControl': [{
                            'location': {'remote': [{'urlString': 'https://example.invalid/dependency'}]},
                            'requirement': ALLOWED_DEPENDENCY_REQUIREMENT}]}]),
                        ('dependencies', [{'sourceControl': [{
                            'location': {'remote': [{'urlString': ALLOWED_DEPENDENCY_URL}]},
                            'requirement': {'range': [{'lowerBound': '1.2.0', 'upperBound': '2.0.0'}]}}]}]),
                        ('dependencies', [FLUX_DEPENDENCY, FLUX_DEPENDENCY]),
                        ('swiftLanguageVersions', ['5']), ('platforms', []),
                        ('targets', []), ('products', []), ('name', 'Wrong'),
                        ('toolsVersion', {'_version': '5.9.0'}),
                        ('settings', {'unsafeFlags': ['-suppress-warnings']})]
        for key, value in replacements:
            with self.subTest(key=key, value=value):
                manifest = copy.deepcopy(self.manifest)
                manifest[key] = value
                self.assertTrue(manifest_issues(manifest, self.pins))

    def test_reject_flux_leaking_into_foundation_only_targets(self):
        manifest = copy.deepcopy(self.manifest)
        for target in manifest['targets']:
            if target['name'] == 'TrellisCore':
                target['dependencies'] = [FLUX_PRODUCT_DEPENDENCY]
        issues = manifest_issues(manifest, self.pins)
        self.assertTrue(any('Foundation-only' in issue for issue in issues))

    def test_reject_trellis_flux_without_flux_dependency(self):
        manifest = copy.deepcopy(self.manifest)
        for target in manifest['targets']:
            if target['name'] == 'TrellisFlux':
                target['dependencies'] = []
        issues = manifest_issues(manifest, self.pins)
        self.assertTrue(any('stub' in issue for issue in issues))

    def test_command_failure_is_recorded_and_stops(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / 'results.json').write_text('[{"passed": true}]')
            check = Verification(output)
            self.assertEqual(json.loads((output / 'results.json').read_text()), [])
            with self.assertRaises(RuntimeError):
                check.run('failure', [sys.executable, '-c', 'raise SystemExit(7)'])
            result = json.loads((output / 'results.json').read_text())
            self.assertEqual(result[0]['exitCode'], 7)
            self.assertFalse(result[0]['passed'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
