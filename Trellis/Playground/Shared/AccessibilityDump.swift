import Foundation

#if canImport(AppKit)
    import AppKit
    import TrellisAppKit
#else
    import TrellisUIKit
    import UIKit
#endif

/// Prints what the platform accessibility API sees on the host (A11 evidence): labels,
/// traits/roles, values and screen frames, straight from `accessibilityElements`/
/// `accessibilityChildren()` — the same objects VoiceOver enumerates.
@MainActor
enum AccessibilityDump {
    #if canImport(AppKit)
        static func print(host: TrellisHostView) {
            Swift.print("A11DUMP begin host=\(host.nativeAccessibilityElementCount) elements")
            for child in host.accessibilityChildren() ?? [] { dump(child, depth: 1) }
            Swift.print("A11DUMP end")
        }

        private static func dump(_ any: Any, depth: Int) {
            guard let element = any as? NSAccessibilityElement else { return }
            let indent = String(repeating: "  ", count: depth)
            let role = element.accessibilityRole()?.rawValue ?? "nil"
            let label = element.accessibilityLabel() ?? "nil"
            let value = (element.accessibilityValue() as? String) ?? "nil"
            let frame = element.accessibilityFrame()
            let enabled = element.isAccessibilityEnabled()
            let selected = element.isAccessibilitySelected()
            Swift.print(
                "A11DUMP \(indent)role=\(role) label=\(label) value=\(value) enabled=\(enabled) selected=\(selected) frame=\(frame)"
            )
            for child in element.accessibilityChildren() ?? [] { dump(child, depth: depth + 1) }
        }
    #else
        static func print(host: TrellisHostView) {
            Swift.print("A11DUMP begin host=\(host.nativeProxyCount) proxies")
            for child in host.accessibilityElements ?? [] { dump(child, depth: 1) }
            Swift.print("A11DUMP end")
        }

        private static func dump(_ any: Any, depth: Int) {
            guard let element = any as? NSObject else { return }
            let indent = String(repeating: "  ", count: depth)
            let label = element.accessibilityLabel ?? "nil"
            let value = element.accessibilityValue ?? "nil"
            let traits = element.accessibilityTraits.rawValue
            let frame = element.accessibilityFrame
            Swift.print(
                "A11DUMP \(indent)element=\(element.isAccessibilityElement) label=\(label) value=\(value) traits=\(traits) frame=\(frame)"
            )
            for child in element.accessibilityElements ?? [] { dump(child, depth: depth + 1) }
        }
    #endif
}
