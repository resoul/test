#if canImport(UIKit)
    import LayoutCore
    import LayoutUIKit
    import UIKit

    /// A view that lays out its subviews with a spec: it overrides `layoutSpec()` and nothing
    /// else. Its subviews are elements of the spec as they are; labels measure their text.
    public final class ProfileView: LayoutView {
        /// The picture.
        public let avatar = UIView()
        /// The name.
        public let name = UILabel()
        /// The button.
        public let follow = UIButton(type: .system)

        /// A view with its subviews added.
        public override init(frame: CGRect) {
            super.init(frame: frame)
            name.numberOfLines = 0
            follow.setTitle("Follow", for: .normal)
            [avatar, name, follow].forEach(addSubview)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// The row; it follows `layoutTheme`'s spacing.
        public override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                avatar.size(48)
                name.flex(grow: 1, shrink: 1)
                follow
            }
            .alignItems(.center)
            .gap(.s4)
            .padding(.s5)
        }
    }
#elseif canImport(AppKit)
    import AppKit
    import LayoutAppKit
    import LayoutCore

    /// A view that lays out its subviews with a spec: it overrides `layoutSpec()` and nothing
    /// else. Its subviews are elements of the spec as they are; text fields measure their text.
    public final class ProfileView: LayoutNSView {
        /// The picture.
        public let avatar = NSView()
        /// The name.
        public let name = NSTextField(wrappingLabelWithString: "")
        /// The button.
        public let follow = NSButton(title: "Follow", target: nil, action: nil)

        /// A view with its subviews added.
        public override init(frame: NSRect) {
            super.init(frame: frame)
            [avatar, name, follow].forEach(addSubview)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// The row; it follows `layoutTheme`'s spacing.
        public override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                avatar.size(48)
                name.flex(grow: 1, shrink: 1)
                follow
            }
            .alignItems(.center)
            .gap(.s4)
            .padding(.s5)
        }
    }
#endif
