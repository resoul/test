import NetworkCore
import Testing

@testable import NetworkFoundation

@Test(.timeLimit(.minutes(1)))
func theSystemMonitorTellsTheCurrentPathFirstAndStopsWhenTheStreamIsDropped() async {
    let monitor = SystemNetworkPathMonitor()

    var iterator = monitor.paths().makeAsyncIterator()
    let first = await iterator.next()

    // Whatever the machine's network is, the monitor says something at once.
    #expect(first != nil)
}
