#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore
    import Testing

    @testable import NodesAppKit

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
    private func view(of bar: Bar) -> NodeNSView {
        let view = NodeNSView(root: bar)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        view.layout()
        view.layout()
        return view
    }

    @Test @MainActor
    func thePopUpShowsTheChoiceAndTheOptionsAndTellsWhatIsPicked() throws {
        let bar = Bar()
        let view = view(of: bar)
        let popUp = try #require(view.embeddedView(of: bar.sort.id) as? PopUpView)

        #expect(popUp.itemTitles == ["Date", "Sender", "Subject"])
        #expect(popUp.titleOfSelectedItem == "Date")

        var changes: [Sort] = []
        bar.sort.onChange = { changes.append($0) }
        // What the pop-up does when the user picks the third item.
        popUp.selectItem(at: 2)
        popUp.choose?(2)
        StateUpdates.flush()
        #expect(bar.sort.selection == .subject)
        #expect(changes == [.subject])
        #expect(popUp.titleOfSelectedItem == "Subject")
        view.host.detach()
    }

    @Test @MainActor
    func withNothingChosenThePlaceholderStandsFirstAndOff() throws {
        let bar = Bar()
        bar.sort.selection = nil
        bar.sort.placeholder = "Sort by"
        let view = view(of: bar)
        let popUp = try #require(view.embeddedView(of: bar.sort.id) as? PopUpView)

        #expect(popUp.itemTitles == ["Sort by", "Date", "Sender", "Subject"])
        #expect(popUp.titleOfSelectedItem == "Sort by")
        #expect(popUp.item(at: 0)?.isEnabled == false)
        var changes: [Sort] = []
        bar.sort.onChange = { changes.append($0) }
        // The option after the placeholder is the first one, not the placeholder.
        popUp.choose?(1)
        #expect(changes == [.date])
        view.host.detach()
    }

    extension NSPopUpButton {
        fileprivate var itemTitles: [String] { itemArray.map(\.title) }
    }
#endif
