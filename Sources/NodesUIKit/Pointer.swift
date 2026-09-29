#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import ObjectiveC
    import UIKit

    // A pointer over the tree — a trackpad or a mouse on iPad: the node a press would go to
    // shows itself under it, and a node's tip shows where it rests.
    //
    // The hover recognizer and the tip interaction do not exist on a TV. Naming their classes
    // in code makes the TV build refer to symbols its UIKit lacks, and it fails to link, even
    // inside an extension marked unavailable there. So the view finds the classes by name at
    // run time: on a TV they are not found, and nothing is set up.
    extension NodeView {
        func followPointer() {
            guard pointer == nil,
                let hoverClass = NSClassFromString("UIHoverGestureRecognizer")
                    as? UIGestureRecognizer.Type
            else { return }

            let pointer = PointerTracker(view: self)
            self.pointer = pointer
            let hover = hoverClass.init()
            hover.addTarget(pointer, action: #selector(PointerTracker.hovered(_:)))
            addGestureRecognizer(hover)
            if let tipsClass = NSClassFromString("UIToolTipInteraction") as? NSObject.Type,
                let tips = tipsClass.init() as? any UIInteraction
            {
                (tips as? NSObject)?.setValue(pointer, forKey: "delegate")
                addInteraction(tips)
            }
        }

        func pointerContentMoved() {
            pointer?.contentMoved()
        }
    }

    /// Takes the pointer's moves and the requests for tips for a node view.
    @MainActor
    final class PointerTracker: NSObject {
        private weak var view: NodeView?
        /// Where the pointer rests over the tree, in its points; `nil` while it is elsewhere.
        private var at: LayoutPoint?

        init(view: NodeView) {
            self.view = view
        }

        @objc func hovered(_ recognizer: UIGestureRecognizer) {
            guard let view else { return }

            switch recognizer.state {
            case .began, .changed:
                let location = recognizer.location(in: view)
                at = LayoutPoint(
                    x: Double(location.x) / view.factor,
                    y: Double(location.y) / view.factor
                )
            default:
                at = nil
            }
            view.host.pointerMoved(to: at)
        }

        func contentMoved() {
            guard let at, let view else { return }

            view.host.pointerMoved(to: at)
        }

        /// The tip interaction asks what to show at `point`, in the view: the innermost
        /// node's tip there, over that node's part that shows, so that moving to another
        /// node asks again.
        @objc(toolTipInteraction:configurationAtPoint:)
        func toolTip(_ interaction: NSObject, at point: CGPoint) -> NSObject? {
            guard let view else { return nil }

            let at = LayoutPoint(x: Double(point.x) / view.factor, y: Double(point.y) / view.factor)
            guard let tip = view.host.toolTip(at: at) else { return nil }

            return PointerTracker.configuration(tip.text, in: view.zoomed(tip.frame))
        }

        /// A tip configuration: `UIToolTipConfiguration(toolTip:in:)`, reached through the
        /// runtime.
        static func configuration(_ text: String, in rect: CGRect) -> NSObject? {
            typealias Make =
                @convention(c) (AnyClass, Selector, NSString, CGRect) -> Unmanaged<NSObject>?
            let selector = NSSelectorFromString("configurationWithToolTip:inRect:")
            guard let type = NSClassFromString("UIToolTipConfiguration"),
                let method = class_getClassMethod(type, selector)
            else { return nil }

            let make = unsafeBitCast(method_getImplementation(method), to: Make.self)
            return make(type, selector, text as NSString, rect)?.takeUnretainedValue()
        }
    }
#endif
