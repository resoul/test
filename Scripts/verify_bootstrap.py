#!/usr/bin/env python3
"""Verify Trellis toolchain, formatting, package contracts, tests and consumer.

Derived from Weave's verifier; no remote dependency resolution or lockfile pins.
Optional --matrix compiles generic destinations; it does not run devices.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from check_policy import LINTER_VERSION

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = {'TrellisCore', 'TrellisRender', 'TrellisUIKit', 'TrellisAppKit', 'TrellisFlux'}
FOUNDATION_ONLY_PRODUCTS = {'TrellisCore', 'TrellisRender', 'TrellisUIKit', 'TrellisAppKit'}
ALLOWED_DEPENDENCY_URL = 'https://github.com/resoul/flux.git'
ALLOWED_DEPENDENCY_REQUIREMENT = {'exact': ['1.2.1']}


def manifest_issues(manifest, pins):
    issues = []
    dependencies = manifest.get('dependencies') or []
    if len(dependencies) != 1 or 'sourceControl' not in dependencies[0]:
        issues.append('Trellis must declare exactly one external git package dependency (Flux)')
    else:
        entry = dependencies[0]['sourceControl'][0]
        location = entry.get('location', {}).get('remote', [{}])[0].get('urlString')
        requirement = entry.get('requirement')
        if location != ALLOWED_DEPENDENCY_URL:
            issues.append('Only the reviewed Flux git URL is an allowed dependency, not ' + str(location))
        if requirement != ALLOWED_DEPENDENCY_REQUIREMENT:
            issues.append(
                'Flux must be pinned to an exact reviewed release (currently 1.2.1), not ' + str(requirement))
    if manifest.get('name') != 'Trellis':
        issues.append('Package name must be Trellis')
    if manifest.get('swiftLanguageVersions') != [pins['swiftLanguageMode']]:
        issues.append('Swift 6 language mode is required')
    if manifest.get('toolsVersion', {}).get('_version') != pins['swiftToolsVersion'] + '.0':
        issues.append('Swift tools version differs from toolchain.json')
    platforms = {p['platformName']: p['version'] for p in manifest.get('platforms', [])}
    if platforms != {'macos': '14.0', 'ios': '16.0', 'tvos': '16.0'}:
        issues.append('Deployment baselines must be macOS 14, iOS 16 and tvOS 16')
    products = manifest.get('products', [])
    if {p['name'] for p in products} != PRODUCTS:
        issues.append('Expected five Trellis library products (Core/Render/UIKit/AppKit/Flux)')
    if any(p.get('targets') != [p['name']] or 'library' not in p.get('type', {}) for p in products):
        issues.append('Each product must export its same-named library target')
    targets = manifest.get('targets', [])
    expected_targets = PRODUCTS | {'TrellisCoreTests', 'TrellisRenderTests', 'TrellisFluxTests'}
    if {t['name'] for t in targets} != expected_targets:
        issues.append('Unexpected stage-1/TrellisFlux target graph')
    target_dependencies = {t['name']: t.get('dependencies', []) for t in targets}

    def depends_on_flux(name):
        return any(
            isinstance(entry, dict) and 'product' in entry and entry['product'][0] == 'Flux'
            for entry in target_dependencies.get(name, [])
        )

    for name in FOUNDATION_ONLY_PRODUCTS:
        if depends_on_flux(name):
            issues.append(name + ' must stay Foundation-only: it must not depend on Flux')
    if not depends_on_flux('TrellisFlux'):
        issues.append('TrellisFlux must depend on the Flux product to be a real integration, not a stub')
    if 'unsafeFlags' in json.dumps(manifest):
        issues.append('Consumer packages must not inherit unsafe compiler flags')
    return issues


class Verification:
    def __init__(self, output):
        self.output = output
        output.mkdir(parents=True, exist_ok=True)
        self.results = []
        # Replace stale results immediately: a failed run must not look like an old pass.
        self.save()
        self.environment = os.environ.copy()
        cache = output / 'module-cache'
        cache.mkdir(exist_ok=True)
        self.environment['CLANG_MODULE_CACHE_PATH'] = str(cache)
        self.environment['SWIFTPM_MODULECACHE_OVERRIDE'] = str(cache)

    def save(self):
        (self.output / 'results.json').write_text(json.dumps(self.results, indent=2) + '\n')

    def record(self, name, command, code, log):
        (self.output / f'{name}.log').write_text(log)
        self.results.append({'name': name, 'command': command, 'exitCode': code, 'passed': code == 0})
        self.save()
        print(f'{"PASS" if code == 0 else "FAIL"} {name}', flush=True)
        if code:
            raise RuntimeError(log[-6000:])

    def run(self, name, command, cwd=ROOT, timeout=600):
        print('RUN ' + ' '.join(command), flush=True)
        try:
            result = subprocess.run(command, cwd=cwd, env=self.environment,
                                    capture_output=True, text=True, timeout=timeout)
            self.record(name, command, result.returncode, result.stdout + result.stderr)
            return result.stdout
        except subprocess.TimeoutExpired as error:
            log = error.stdout or b''
            if isinstance(log, bytes):
                log = log.decode(errors='replace')
            self.record(name, command, 124, log + '\nCommand timed out\n')
        except OSError as error:
            self.record(name, command, 127, str(error))

    def require(self, name, condition, detail):
        self.record(name, ['contract-check'], 0 if condition else 1, detail + '\n')


def swift(*args):
    if args and args[0] in {'package', 'build', 'test', 'run'}:
        storage = ROOT / '.build' / 'verification-swiftpm'
        for name in ('cache', 'configuration', 'security'):
            (storage / name).mkdir(parents=True, exist_ok=True)
        args = (args[0], '--cache-path', str(storage / 'cache'),
                '--config-path', str(storage / 'configuration'),
                '--security-path', str(storage / 'security'), *args[1:])
    return ['xcrun', '--sdk', 'macosx', 'swift', *args]


def find_simulator_udid(check, platform_label, sdk_version):
    raw = check.run(f'{platform_label.lower()}-simulator-list',
                    ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'])
    runtime_suffix = f'{platform_label}-{sdk_version.replace(".", "-")}'
    devices = json.loads(raw).get('devices', {})
    for runtime_id, entries in devices.items():
        if not runtime_id.endswith(runtime_suffix):
            continue
        for device in entries:
            if device.get('isAvailable', True):
                return device['udid']
    raise RuntimeError(
        f'No available {platform_label} {sdk_version} Simulator found for runtime {runtime_suffix}; '
        'install it via Xcode > Settings > Platforms or update toolchain.json sdkVersion')


def check_consumer(check):
    consumer = check.output / 'consumer'
    source = consumer / 'Sources' / 'Smoke'
    source.mkdir(parents=True, exist_ok=True)
    # JSON quoting is valid for this ordinary Swift path literal, not shell escaping.
    package_path = json.dumps(str(ROOT))
    (consumer / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TrellisConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: ''' + package_path + ''')],
    targets: [.executableTarget(name: "Smoke", dependencies: [
        .product(name: "TrellisCore", package: "Trellis"),
        .product(name: "TrellisRender", package: "Trellis"),
        .product(name: "TrellisAppKit", package: "Trellis"),
        .product(name: "TrellisFlux", package: "Trellis")
    ])],
    swiftLanguageModes: [.v6]
)
''')
    (source / 'Smoke.swift').write_text('''import Foundation
import TrellisCore
import TrellisRender
import TrellisAppKit
import TrellisFlux

enum SmokeFailure: Error {
    case nonemptyRegistry
    case unexpectedTreeState
    case unexpectedArrangement
    case unexpectedEventState
    case unexpectedFluxState
    case unexpectedFocusState
    case unexpectedAccessibilityState
    case unexpectedTextState
    case unexpectedAnimationState
    case unexpectedCollectionState
}

/// R12: an ItemProvider, delegate and row actions declared outside TrellisCore, proving the
/// ListNode/GridNode/TableNode consumer API (P6.10/P6.11) compiles without `@testable`.
struct Mail: Sendable, Equatable {
    let subject: String
}

@MainActor
struct MailProvider: ItemProvider {
    func makeNode(for item: Mail, id: Int) -> Node {
        let node = Node()
        node.style.height = 44
        node.accessibility.label = item.subject
        return node
    }

    func update(_ node: Node, with item: Mail, id: Int) {
        node.accessibility.label = item.subject
    }
}

@MainActor
final class MailCoordinator: CollectionDelegate {
    private(set) var selected: [Int] = []

    func collectionDidSelect(_ id: Int) { selected.append(id) }
}

/// A subclass declared outside TrellisCore, proving `open class Node` is overridable
/// without `@testable` (D02, F14) and that dispose() can add owned-work cancellation.
final class Card: Node {
    private(set) var disposed = false

    override func dispose() {
        disposed = true
        super.dispose()
    }
}

/// Mirrors the C21 worked example (docs/validation/c21-arrangement-contract.md), proving
/// `Leaf`/`Row`/`Column`, the builder's sequence/nesting forms, `.size`/`.grow` modifiers, and
/// `open func arrangeSubnodes()` (C22) all compile and override from outside TrellisCore
/// without `@testable`.
final class ProfileCard: Node {
    let avatar = Node()
    let title = Node()
    let subtitle = Node()

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(spacing: 12, align: .center) {
            Leaf(avatar).size(width: 48, height: 48)
            Column(spacing: 4) {
                Leaf(title)
                Leaf(subtitle)
            }
            .grow(1)
        }
    }
}

/// Proves the event/control hooks remain overridable by an ordinary external consumer and
/// that the public committed-snapshot pointer path can be assembled without `@testable`.
final class EventControl: ControlNode {
    private(set) var received: [EventType] = []

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        received.append(event.type)
    }
}

@main
struct Smoke {
    @MainActor
    static func main() async throws {
        let _: NodeID.Type = NodeID.self
        let _: TrellisHostView.Type = TrellisHostView.self
        var style = LayoutStyle()
        style.width = 120
        style.gap = -1
        guard style.width == .points(120), style.gap == 0 else {
            throw SmokeFailure.nonemptyRegistry
        }
        var appearance = VisualStyle()
        appearance.cornerRadius = .infinity
        guard appearance.cornerRadius == 0 else { throw SmokeFailure.nonemptyRegistry }
        let timing = Animation.easeOut(duration: .milliseconds(180))
        guard timing.curve == .easeOut, Animation.smooth.duration == .milliseconds(250) else {
            throw SmokeFailure.unexpectedAnimationState
        }
        // M09: `.spring`/`.snappy` without `@testable` — a real consumer only ever sees the
        // normalized, clamped result, never TrellisRender's CASpringAnimation conversion.
        guard Animation.snappy.curve == .spring(response: 0.35, dampingFraction: 0.86),
            Animation.spring(response: 0, dampingFraction: 2).curve
                == .spring(response: 0.05, dampingFraction: 1)
        else {
            throw SmokeFailure.unexpectedAnimationState
        }
        let animationNode = Node()
        animationNode.animate(.none) { animationNode.style.width = 24 }
        guard animationNode.style.width == .points(24) else {
            throw SmokeFailure.unexpectedAnimationState
        }
        let registry = LayerRegistry()
        guard registry.count == 0 else { throw SmokeFailure.nonemptyRegistry }

        let root = Node()
        let card = Card()
        root.addSubnode(card)
        guard root.subnodes.map(\\.id) == [card.id], card.supernode === root else {
            throw SmokeFailure.unexpectedTreeState
        }
        card.dispose()
        guard card.disposed, root.subnodes.isEmpty else {
            throw SmokeFailure.unexpectedTreeState
        }

        let profileCard = ProfileCard()
        guard profileCard.arrangeSubnodes() is Row else {
            throw SmokeFailure.unexpectedArrangement
        }
        guard profileCard.resolveArrangement() else {
            throw SmokeFailure.unexpectedArrangement
        }
        guard profileCard.subnodes.map(\\.id) == [profileCard.avatar.id, profileCard.subnodes[1].id],
            profileCard.subnodes[1].subnodes.map(\\.id) == [profileCard.title.id, profileCard.subtitle.id]
        else {
            throw SmokeFailure.unexpectedArrangement
        }

        let eventRoot = Node()
        let eventControl = EventControl()
        eventRoot.addSubnode(eventControl)
        let eventBounds = LayoutFrame(width: 200, height: 100)
        let eventLayout = LayoutResult(
            placements: [
                LayoutPlacement(identity: eventRoot.id, frame: eventBounds),
                LayoutPlacement(identity: eventControl.id, frame: LayoutFrame(width: 100, height: 40)),
            ],
            treeIdentity: eventRoot.id
        )
        guard eventRoot.applyLayoutResult(eventLayout),
            let hitSnapshot = HitTestSnapshot(root: eventRoot, mountEpoch: 1, bounds: eventBounds)
        else {
            throw SmokeFailure.unexpectedEventState
        }
        var activations = 0
        eventControl.activation = { activations += 1 }
        let sessions = PointerSessions()
        let pointer = PointerData(point: LayoutPoint(x: 20, y: 20), pointerID: 7)
        guard case .delivered = sessions.send(
            .pointerDown,
            pointer,
            snapshot: hitSnapshot,
            root: eventRoot
        ) else {
            throw SmokeFailure.unexpectedEventState
        }
        guard case .delivered = sessions.send(
            .pointerUp,
            pointer,
            snapshot: hitSnapshot,
            root: eventRoot
        ),
            activations == 1,
            eventControl.received == [.pointerDown, .pointerUp],
            !eventControl.isPressed,
            sessions.activeCount == 0
        else {
            throw SmokeFailure.unexpectedEventState
        }

        // A13: the public focus + accessibility path (A03–A07) without `@testable`: metadata
        // on nodes, a committed semantic snapshot, the engine's traversal and key routing,
        // the semantic tree, and an accessibility action through the control's activation.
        eventControl.accessibility.label = "Buy"
        eventControl.accessibility.customActions = [AccessibilityCustomAction(id: "share", name: "Share")]
        eventControl.onAccessibilityAction = { action in action == .custom("share") }
        let semantics = SemanticSnapshot(
            geometry: hitSnapshot,
            root: eventRoot,
            geometryGeneration: 1,
            revision: 1
        )
        guard semantics.focusCandidates(scope: nil) == [eventControl.id],
            semantics.record(for: eventControl.id)?.accessibility.label == "Buy"
        else {
            throw SmokeFailure.unexpectedFocusState
        }
        let engine = FocusEngine()
        engine.apply(semantics, root: eventRoot)
        guard case .moved = engine.move(.next, root: eventRoot), engine.focusedID == eventControl.id,
            eventControl.isFocused
        else {
            throw SmokeFailure.unexpectedFocusState
        }
        guard engine.sendKey(KeyData(key: .returnKey), type: .keyDown, root: eventRoot) == .handled,
            eventControl.isPressed,
            engine.sendKey(KeyData(key: .returnKey), type: .keyUp, root: eventRoot) == .handled,
            activations == 2, eventControl.lastActivationSource == .keyboard,
            engine.move(.next, root: eventRoot) == .unchanged
        else {
            throw SmokeFailure.unexpectedFocusState
        }
        let tree = AccessibilityTree.build(from: semantics, scope: nil)
        guard tree.readingOrder == [eventControl.id],
            tree.element(for: eventControl.id)?.role == .button,
            tree.element(for: eventControl.id)?.customActions.map(\\.id) == ["share"],
            eventControl.performAccessibilityAction(.activate), activations == 3,
            eventControl.lastActivationSource == .accessibility,
            eventControl.performAccessibilityAction(.custom("share")),
            !eventControl.performAccessibilityAction(.increment)
        else {
            throw SmokeFailure.unexpectedAccessibilityState
        }
        eventControl.isEnabled = false
        guard !eventControl.performAccessibilityAction(.activate), activations == 3 else {
            throw SmokeFailure.unexpectedAccessibilityState
        }

        // T12: the public text path (T01–T11) without `@testable` — construction, the
        // canonical `document` (D55), run-level style overrides through the public
        // `trellisText` dynamic member, paragraph fields, and D57's accessibility auto-sync,
        // all overridable/usable from an ordinary external module the same as `Card`/
        // `ProfileCard`/`EventControl` above.
        let label = TextNode(text: "Buy now")
        guard label.text == "Buy now", label.accessibility.isElement, label.accessibility.label == "Buy now",
            label.accessibility.role == .text
        else {
            throw SmokeFailure.unexpectedTextState
        }
        var mixed = TextDocument("Plain, ")
        var emphasized = AttributedString("bold")
        emphasized.trellisText.weight = .bold
        emphasized.trellisText.color = ThemeColor(red: 0.9, green: 0.3, blue: 0.1)
        mixed.append(emphasized)
        label.document = mixed
        label.textStyle = TextStyle(pointSize: 15, alignment: .center)
        label.maxLines = 2
        label.truncation = .clip
        guard label.document.runs.count >= 1, label.textStyle.pointSize == 15, label.maxLines == 2,
            label.truncation == .clip, label.accessibility.label == label.text
        else {
            throw SmokeFailure.unexpectedTextState
        }
        let textRoot = Node()
        textRoot.addSubnode(label)
        let textLayout = LayoutResult(
            placements: [
                LayoutPlacement(identity: textRoot.id, frame: LayoutFrame(width: 200, height: 60)),
                LayoutPlacement(identity: label.id, frame: LayoutFrame(width: 180, height: 40)),
            ],
            treeIdentity: textRoot.id
        )
        guard textRoot.applyLayoutResult(textLayout), label.calculatedFrame?.width == 180 else {
            throw SmokeFailure.unexpectedTextState
        }

        // R02: the real Flux dependency, resolved and pinned through TrellisFlux, is
        // usable end to end from an ordinary external consumer.
        guard TrellisFlux.fluxVersion == "1.2.1" else {
            throw SmokeFailure.unexpectedFluxState
        }
        let counter = CurrentValue(0)
        await counter.set(1)
        var counterIterator = counter.stream.makeAsyncIterator()
        guard await counterIterator.next() == 1 else {
            throw SmokeFailure.unexpectedFluxState
        }
        await counter.set(2)
        guard await counterIterator.next() == 2, await counter.value == 2 else {
            throw SmokeFailure.unexpectedFluxState
        }

        // R12: the three collection containers from the public API only.
        let mail = StateSubject(
            CollectionSnapshot(
                dataKey: "mail",
                revision: 1,
                items: (0..<100).map { CollectionItem(id: $0, value: Mail(subject: "Mail \($0)")) }
            )
        )
        let list = ListNode(source: mail, provider: MailProvider())
        let grid = GridNode(
            source: mail,
            provider: MailProvider(),
            layout: GridLayout(columns: .adaptive(minimumWidth: 120), columnSpacing: 8)
        )
        let table = TableNode(source: mail, provider: MailProvider())
        table.swipeActionsPolicy = .automatic
        table.trailingActions = { id in
            [RowAction(id: "delete", title: "Delete", style: .destructive) { _ in .completed }]
        }
        list.loader.onLoadMore = { _ in .completed }
        grid.loader.onRefresh = { _ in .completed }
        let coordinator = MailCoordinator()
        table.events.delegate = coordinator
        table.events.select(3)
        var closureSelected: [Int] = []
        table.events.onSelect = { closureSelected.append($0) }
        table.events.select(4)
        var early: CollectionScrollResult?
        list.scrollTo(10) { early = $0 }
        guard coordinator.selected == [3], closureSelected == [4], early == .notAttached,
            list.window.snapshot.count == 100, grid.window.snapshot.count == 100,
            table.window.snapshot.count == 100
        else {
            throw SmokeFailure.unexpectedCollectionState
        }
        list.dispose()
        grid.dispose()
        table.dispose()

        print("PASS external consumer")
    }
}
''')
    check.run('consumer', swift('run', '--disable-sandbox',
                               '-Xswiftc', '-warnings-as-errors', 'Smoke'), cwd=consumer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/bootstrap-validation')
    args = parser.parse_args()
    check = Verification(args.output.resolve())
    try:
        pins = json.loads((ROOT / 'toolchain.json').read_text())
        check.require('linter-pin', pins['policyLinterVersion'] == LINTER_VERSION,
                      'Linter/toolchain versions must match')
        compiler = check.run('swift-version', swift('--version'))
        xcode = check.run('xcode-version', ['xcodebuild', '-version'])
        formatter = check.run('format-version', ['xcrun', 'swift-format', '--version']).strip()
        check.require('pinned-toolchain',
                      f"Swift version {pins['swiftCompilerVersion']} " in compiler
                      and f"Xcode {pins['xcodeVersion']}\n" in xcode
                      and f"Build version {pins['xcodeBuild']}" in xcode
                      and formatter == pins['swiftFormatVersion'],
                      'Use the explicitly reviewed toolchain.json pins')
        sdk = check.run('macos-sdk-version', ['xcrun', '--sdk', 'macosx', '--show-sdk-version']).strip()
        check.require('macos-sdk-pin', sdk == pins['sdkVersion'], 'Expected SDK ' + pins['sdkVersion'])
        check.run('format', ['xcrun', 'swift-format', 'lint', '--strict', '--configuration',
                             '.swift-format', '--recursive', 'Package.swift', 'Sources', 'Tests'])
        manifest = json.loads(check.run('manifest', swift('package', '--disable-sandbox', 'dump-package')))
        issues = manifest_issues(manifest, pins)
        check.require('package-contract', not issues, '\n'.join(issues) or 'PASS dependency-free stage-1 manifest')
        # No resolve step: there are no external dependencies to fetch.
        check.run('library-build', swift('build', '--disable-sandbox',
                                         '-Xswiftc', '-warnings-as-errors'))
        check.run('tests', swift('test', '--disable-sandbox',
                                '-Xswiftc', '-warnings-as-errors'))
        check_consumer(check)
        if args.matrix:
            # Device destinations are build-only: no attached hardware in CI or on a
            # developer Mac runs a signed test bundle. Simulator destinations instead
            # resolve a concrete booted-capable device and run (not just build) the
            # full Trellis-Package test suite (C27): TrellisCoreTests unconditionally,
            # and TrellisRenderTests minus its AppKit-only file (guarded by canImport).
            build_destinations = [
                ('macos-universal', 'generic/platform=macOS', 'macosx', ['ARCHS=arm64 x86_64']),
                ('ios-device', 'generic/platform=iOS', 'iphoneos', []),
                ('tvos-device', 'generic/platform=tvOS', 'appletvos', []),
            ]
            for name, destination, sdk_name, arch in build_destinations:
                version = check.run(name + '-sdk', ['xcrun', '--sdk', sdk_name, '--show-sdk-version']).strip()
                check.require(name + '-sdk-pin', version == pins['sdkVersion'], 'Expected SDK ' + pins['sdkVersion'])
                check.run(name, ['xcodebuild', '-scheme', 'Trellis-Package', '-destination', destination,
                                 '-derivedDataPath', str(check.output / 'xcode' / name),
                                 '-disableAutomaticPackageResolution', 'CODE_SIGNING_ALLOWED=NO',
                                 'ONLY_ACTIVE_ARCH=NO', 'SWIFT_VERSION=6.0',
                                 'SWIFT_STRICT_CONCURRENCY=complete', 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES',
                                 'SWIFT_SUPPRESS_WARNINGS=NO', *arch, 'build'])
            test_destinations = [
                ('ios-simulator', 'iOS', 'iphonesimulator'),
                ('tvos-simulator', 'tvOS', 'appletvsimulator'),
            ]
            for name, platform_label, sdk_name in test_destinations:
                version = check.run(name + '-sdk', ['xcrun', '--sdk', sdk_name, '--show-sdk-version']).strip()
                check.require(name + '-sdk-pin', version == pins['sdkVersion'], 'Expected SDK ' + pins['sdkVersion'])
                udid = find_simulator_udid(check, platform_label, pins['sdkVersion'])
                check.run(name, ['xcodebuild', 'test', '-scheme', 'Trellis-Package',
                                 '-destination', f'platform={platform_label} Simulator,id={udid}',
                                 '-derivedDataPath', str(check.output / 'xcode' / name),
                                 '-disableAutomaticPackageResolution', 'CODE_SIGNING_ALLOWED=NO',
                                 'SWIFT_VERSION=6.0', 'SWIFT_STRICT_CONCURRENCY=complete',
                                 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'SWIFT_SUPPRESS_WARNINGS=NO'])
        print('PASS bootstrap; logs: ' + str(check.output))
        return 0
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
