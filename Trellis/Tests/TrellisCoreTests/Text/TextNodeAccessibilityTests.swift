import Testing

@testable import TrellisCore

// T08 (implementation-plan-4.md §5, D57): TextNode fills accessibility.isElement/label/role
// from the document's plain characters, on creation and on every text change, without
// overriding a value the author set explicitly. AccessibilityTree integration (native label ==
// text, `.combine` joining several TextNodes into one label) lives alongside A06's existing
// fixtures in Tests/TrellisCoreTests/Semantics/AccessibilityTreeTests.swift.

@Test @MainActor
func t08_creatingATextNodeFillsIsElementLabelAndRoleFromTheText() {
    let node = TextNode(text: "Hello")

    #expect(node.accessibility.isElement)
    #expect(node.accessibility.label == "Hello")
    #expect(node.accessibility.role == .text)
}

@Test @MainActor
func t08_changingTextUpdatesTheAutomaticLabelToMatch() {
    let node = TextNode(text: "Hello")

    node.text = "Goodbye"

    #expect(node.accessibility.label == "Goodbye")
    #expect(node.accessibility.isElement)
    #expect(node.accessibility.role == .text)
}

@Test @MainActor
func t08_changingTextRepublishesSemanticsEvenWhenTheAuthorNeverTouchedAccessibility() {
    let node = TextNode(text: "Hello")
    let semanticsBefore = node.semanticsRevision

    node.text = "Goodbye"

    #expect(node.semanticsRevision > semanticsBefore)
}

@Test @MainActor
func t08_settingTheSameTextAgainIsAccessibilityNoOpToo() {
    let node = TextNode(text: "Hello")
    let semanticsBefore = node.semanticsRevision

    node.text = "Hello"

    #expect(node.semanticsRevision == semanticsBefore)
}

@Test @MainActor
func t08_anAuthoredLabelSurvivesLaterTextChanges() {
    let node = TextNode(text: "Hello")

    node.accessibility.label = "Greeting"
    node.text = "Goodbye"

    #expect(node.accessibility.label == "Greeting")
    // The fields the author never touched keep tracking the text.
    #expect(node.accessibility.isElement)
    #expect(node.accessibility.role == .text)
}

@Test @MainActor
func t08_anAuthoredRoleSurvivesLaterTextChanges() {
    let node = TextNode(text: "Section title")

    node.accessibility.role = .header
    node.text = "Updated title"

    #expect(node.accessibility.role == .header)
    #expect(node.accessibility.label == "Updated title")
}

@Test @MainActor
func t08_authorCanOptOutByClearingIsElement() {
    let node = TextNode(text: "Decorative")

    node.accessibility.isElement = false
    node.text = "Still decorative"

    #expect(!node.accessibility.isElement)
    // The label the author did not touch keeps tracking the text regardless.
    #expect(node.accessibility.label == "Still decorative")
}

@Test @MainActor
func t08_optOutSurvivesASecondTextChangeTooNotJustTheFirst() {
    // Regression: an earlier draft's shadow tracking copied the author's override into its own
    // "last automatic value" record on the very next sync, so a *second* text change could no
    // longer tell the override apart from an untouched default and silently reasserted
    // `isElement = true` over it.
    let node = TextNode(text: "Decorative")

    node.accessibility.isElement = false
    node.text = "Still decorative"
    node.text = "Changed again"

    #expect(!node.accessibility.isElement)
    #expect(node.accessibility.label == "Changed again")
}

@Test @MainActor
func t08_authorCanReplaceAccessibilityWholesaleAndAllThreeFieldsStick() {
    let node = TextNode(text: "Hello")

    node.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Custom label",
        role: .header
    )
    node.text = "Goodbye"

    #expect(node.accessibility.label == "Custom label")
    #expect(node.accessibility.role == .header)
}

@Test @MainActor
func t08_creatingFromAnEmptyStringStillFillsALabel() {
    let node = TextNode(text: "")

    #expect(node.accessibility.isElement)
    #expect(node.accessibility.label == "")
    #expect(node.accessibility.role == .text)
}
