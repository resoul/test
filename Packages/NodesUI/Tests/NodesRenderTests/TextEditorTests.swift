#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    @testable import NodesRender

    @Test @MainActor
    func aTextEditorTakesWhatTheUserTypesAndCutsItToItsLimit() {
        let editor = TextEditor(placeholder: "Notes")
        var changes: [String] = []
        editor.onChange = { changes.append($0) }
        editor.maxLength = 5

        editor.userChanged("abc")
        editor.userChanged("abcdefgh")
        #expect(editor.text == "abcde")
        // A change that leaves the text as it is tells nothing.
        editor.userChanged("abcdefghi")
        #expect(changes == ["abc", "abcde"])

        // Set by code, the text shows in full, without onChange, and is not cut.
        editor.text = "abcdefghij"
        #expect(editor.text == "abcdefghij")
        #expect(changes == ["abc", "abcde"])
    }

    @Test @MainActor
    func aTextFieldCutsWhatIsTypedToItsLimitAndShowsNoClearButtonUnlessAsked() {
        let field = TextField(placeholder: "Code")
        #expect(field.clearButton == .never)
        field.maxLength = 3
        var changes: [String] = []
        field.onChange = { changes.append($0) }

        field.userChanged("12")
        field.userChanged("12345")
        field.userChanged("123456")
        #expect(field.text == "123")
        #expect(changes == ["12", "123"])
        field.maxLength = nil
        field.userChanged("123456")
        #expect(field.text == "123456")
    }

    @Test @MainActor
    func theEditorIsAsHighAsItsTextBetweenItsLeastAndMostLinesAndScrollsBeyond() {
        let editor = TextEditor()
        editor.minLines = 3
        editor.maxLines = 6
        // 20-point lines, 16 points of insets: 76 to 136.
        func fit(_ content: Double) -> (height: Double, scrolls: Bool) {
            editor.height(forContent: content, lineHeight: 20, insets: 16)
        }

        #expect(fit(40) == (76, false))
        #expect(fit(76) == (76, false))
        #expect(fit(100) == (100, false))
        #expect(fit(136) == (136, false))
        #expect(fit(200) == (136, true))

        editor.maxLines = nil
        #expect(fit(1000) == (1000, false))
        // A most lower than the least is the least.
        editor.maxLines = 1
        #expect(fit(1000) == (76, true))
    }
#endif
