# Policy fixtures

Each child directory is an intentionally invalid repository fragment. `Scripts/test_policy.py`
copies `policy.json` into one fragment and verifies that the named rule fails. Fixture files use
an extra `.fixture` suffix so SwiftPM and documentation tooling do not treat them as source.

These eight fixtures were transferred from Weave at the revision recorded in
`docs/source-provenance.md`. Additional positive and negative fixtures live beside
their expected diagnostics in `Scripts/test_policy.py`: nested comments, escaped/raw/
multiline strings, executable interpolation, public documentation, TODO task IDs,
guard/if spacing, Core imports, adapter guards and identity lookup.

Run `python3 Scripts/test_policy.py` from the package root. Tests create independent
temporary roots; normal repository lint deliberately excludes this fixture directory.
