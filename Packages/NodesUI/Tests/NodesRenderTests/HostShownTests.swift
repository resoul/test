import LayoutCore
import Nodes
import Testing

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import NodesAppKit

    @Test @MainActor
    func aNodeViewShowsItsTreeInAWindowAndNotHidden() {
        let view = NodeNSView(root: Node())
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        holder.addSubview(view)
        #expect(!view.host.isShown)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = holder
        #expect(view.host.isShown)

        // Hidden around it, as a tab not chosen is.
        holder.isHidden = true
        #expect(!view.host.isShown)
        holder.isHidden = false
        #expect(view.host.isShown)
        view.isHidden = true
        #expect(!view.host.isShown)
        view.isHidden = false

        view.removeFromSuperview()
        #expect(!view.host.isShown)
        view.host.detach()
    }
#endif

#if canImport(UIKit)
    import UIKit
    import NodesUIKit

    @Test @MainActor
    func aNodeViewShowsItsTreeInAWindowAndNotHidden() {
        let view = NodeView(root: Node())
        #expect(!view.host.isShown)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(view)
        #expect(view.host.isShown)
        view.isHidden = true
        #expect(!view.host.isShown)
        view.isHidden = false
        #expect(view.host.isShown)

        // A screen under the next one in a navigation controller is taken out of the window.
        view.removeFromSuperview()
        #expect(!view.host.isShown)
        view.host.detach()
    }
#endif
