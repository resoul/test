#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore

    /// A node that takes text from the keyboard: the ones the keyboard bar moves between.
    ///
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation:
    /// `endEditing()`.
    @MainActor
    public protocol TextInputNode: EmbeddedNode {
        /// Gives the node the keyboard.
        func beginEditing()
        /// Takes the keyboard from the node.
        func endEditing()
    }

    extension TextField: TextInputNode {}
    extension TextEditor: TextInputNode {}

    extension TextInputNode {
        /// The text input `offset` places after this one in the order the tree is read in —
        /// before it for a negative offset; `nil` past either end.
        package func neighbor(_ offset: Int) -> (any TextInputNode)? {
            guard let inputs = host?.embeddedItems().compactMap({ $0.node as? any TextInputNode }),
                let index = inputs.firstIndex(where: { $0 === self }),
                inputs.indices.contains(index + offset)
            else { return nil }

            return inputs[index + offset]
        }
    }

    /// The keyboard bar of `KeyboardBar.navigation`: previous and next input, and Done. The
    /// two that lead nowhere are turned off; `refresh()` says so again once the input takes the
    /// keyboard, since the tree may have changed.
    @MainActor
    package final class KeyboardNavigationBar: Node {
        private weak var input: (any TextInputNode)?
        let previous: Button
        let next: Button
        let done: Button

        package init(input: any TextInputNode) {
            self.input = input
            let style = TextStyle(.button)
            previous = Button("▲", style: style) { [weak input] in
                input?.neighbor(-1)?.beginEditing()
            }
            next = Button("▼", style: style) { [weak input] in input?.neighbor(1)?.beginEditing() }
            done = Button("Done", style: style) { [weak input] in input?.endEditing() }
            super.init()
            previous.accessibility.label = "Previous field"
            next.accessibility.label = "Next field"
            done.accessibility.label = "Done"
            refresh()
        }

        /// Turns off the buttons that have nowhere to go.
        package func refresh() {
            previous.isEnabled = input?.neighbor(-1) != nil
            next.isEnabled = input?.neighbor(1) != nil
        }

        package override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                previous
                next
                FlexContainer(.row) {}.flex(grow: 1)
                done
            }
            .gap(12)
            .padding(horizontal: 12, vertical: 6)
            .alignItems(.center)
        }
    }
#endif
