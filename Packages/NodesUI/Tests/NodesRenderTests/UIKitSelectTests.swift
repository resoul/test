#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore
    import Testing
    import UIKit

    @testable import NodesUIKit

    private enum Sort: String, CaseIterable {
        case date, sender, subject

        var title: String { rawValue.capitalized }
    }

    @MainActor
    private final class Bar: Node {
        let sort = Select(options: Sort.allCases, selection: .date) { $0.title }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { sort }
        }
    }

    @MainActor
    private func view(of bar: Bar) -> NodeView {
        let view = NodeView(root: bar)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    @Test @MainActor
    func theButtonSaysTheChoiceAndItsMenuHasTheOptionsWithACheckByTheChosen() throws {
        let bar = Bar()
        let view = view(of: bar)
        let button = try #require(view.embeddedView(of: bar.sort.id) as? UIButton)

        #expect(button.configuration?.title == "Date")
        guard #available(iOS 14, tvOS 17, *) else { return }

        let actions = try #require(button.menu?.children as? [UIAction])
        #expect(actions.map(\.title) == ["Date", "Sender", "Subject"])
        #expect(actions.map(\.state) == [.on, .off, .off])
        #expect(button.showsMenuAsPrimaryAction)

        // Chosen in the menu: the node has it and says so; the button follows.
        var changes: [Sort] = []
        bar.sort.onChange = { changes.append($0) }
        actions[1].performWithSender(nil, target: nil)
        StateUpdates.flush()
        #expect(bar.sort.selection == .sender)
        #expect(changes == [.sender])
        #expect(button.configuration?.title == "Sender")
        let updated = try #require(button.menu?.children as? [UIAction])
        #expect(updated.map(\.state) == [.off, .on, .off])
        view.host.detach()
    }

    @Test @MainActor
    func theButtonFollowsTheOptionsThePlaceholderAndTheEnabledState() throws {
        let bar = Bar()
        let view = view(of: bar)
        let button = try #require(view.embeddedView(of: bar.sort.id) as? UIButton)

        bar.sort.selection = nil
        bar.sort.placeholder = "Sort by"
        bar.sort.options = [.date]
        bar.sort.isEnabled = false
        StateUpdates.flush()
        #expect(!button.isEnabled)
        #expect(button.configuration?.title == "Sort by")
        if #available(iOS 14, tvOS 17, *) {
            #expect((button.menu?.children as? [UIAction])?.map(\.title) == ["Date"])
        }
        view.host.detach()
    }
#endif
