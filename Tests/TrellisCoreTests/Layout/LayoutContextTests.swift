import Testing

@testable import TrellisCore

@Test
func test_layoutContext_noCancellationNeverReportsCancelled() {
    #expect(LayoutContext.noCancellation.isCancelled == false)
}

@Test
func test_layoutContext_noCancellationCheckCancellationNeverThrows() throws {
    try LayoutContext.noCancellation.checkCancellation()
}

@Test
func test_layoutContext_customPredicateReportsCancellationState() {
    let notCancelled = LayoutContext(cancellationCheck: { false })
    let cancelled = LayoutContext(cancellationCheck: { true })

    #expect(notCancelled.isCancelled == false)
    #expect(cancelled.isCancelled)
}

@Test
func test_layoutContext_checkCancellationThrowsOnlyWhenCancelled() {
    let context = LayoutContext(cancellationCheck: { true })

    #expect(throws: LayoutCancellationError.cancelled) {
        try context.checkCancellation()
    }
}

@Test
func test_layoutContext_currentTaskReflectsThatTasksCancellation() async {
    let task = Task { () -> Bool in
        let context = LayoutContext.currentTask()
        while !Task.isCancelled {
            await Task.yield()
        }
        return context.isCancelled
    }
    task.cancel()

    let observedCancelled = await task.value

    #expect(observedCancelled)
}
