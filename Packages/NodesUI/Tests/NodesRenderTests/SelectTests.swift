#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore
    import Testing

    @testable import NodesRender

    private enum Sort: String, CaseIterable {
        case date, sender, subject

        var title: String { rawValue.capitalized }
    }

    @Test @MainActor
    func aSelectSaysWhatIsChosenOrItsPlaceholderAndTellsTheUsersChoiceOnly() {
        let select = Select(options: Sort.allCases, selection: nil, placeholder: "Sort by") {
            $0.title
        }
        var changes: [Sort] = []
        select.onChange = { changes.append($0) }

        #expect(select.label == "Sort by")
        select.userChose(.sender)
        #expect(select.selection == .sender)
        #expect(select.label == "Sender")
        #expect(changes == [.sender])

        // From code: it shows, and nobody is told.
        select.selection = .subject
        #expect(select.label == "Subject")
        #expect(changes == [.sender])

        // The option chosen again is a choice too.
        select.userChose(.subject)
        #expect(changes == [.sender, .subject])
    }

    @Test @MainActor
    func theOptionsAndTheEnabledStateAreObservable() {
        let select = Select(options: [Sort.date], selection: .date) { $0.title }
        var runs = 0
        let observer = Observer { runs += 1 }
        observer.track {
            _ = select.options
            _ = select.isEnabled
        }
        #expect(runs == 0)

        select.options = Sort.allCases
        StateUpdates.flush()
        #expect(runs == 1)
        select.isEnabled = false
        StateUpdates.flush()
        #expect(runs == 2)
        #expect(!select.isEnabled)
    }
#endif
