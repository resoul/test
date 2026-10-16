import AppShell
import Nodes

#if canImport(UIKit)
    import AppShellUIKit
    import UIKit
#endif

/// Where the mail screens go.
public enum MailRoute: Hashable, Sendable {
    /// The list of messages; the root of the stack.
    case inbox
    /// One message.
    case message(id: Int)
}

/// A navigation stack of mail screens. The stack is the app's model of navigation: it decides
/// the path and makes each route's screen once; the platform's container shows it, and the
/// same code runs in tests without one.
@MainActor
public func makeMailStack() -> Stack<MailRoute> {
    Stack(root: .inbox) { route in
        switch route {
        case .inbox: NodeScreen(Node())
        case .message: NodeScreen(Node())
        }
    }
}

/// Opens a message and goes back, as the inbox's rows and the back button do.
///
/// - Returns: The path after each step.
@MainActor
public func browseMail(_ stack: Stack<MailRoute>) -> [[MailRoute]] {
    var paths = [stack.path]
    stack.push(.message(id: 7))
    paths.append(stack.path)
    stack.pop()
    paths.append(stack.path)
    return paths
}

#if canImport(UIKit)
    /// The stack in a `UINavigationController`, which shows its moves and reports the back
    /// gesture to it.
    @MainActor
    public func mailViewController() -> UIViewController {
        makeMailStack().makeViewController()
    }
#endif
