// Test-only scheduling barriers, injected into an archived Flux revision.
// No runtime code is copied into Trellis targets.
actor R01Gate {
    private var blocked = false
    private var arrivals = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func arm() {
        precondition(parked.isEmpty && observers.isEmpty)
        arrivals = 0
        blocked = true
    }

    func reset() {
        precondition(parked.isEmpty && observers.isEmpty)
        arrivals = 0
        blocked = false
    }

    func hit() async {
        arrivals += 1
        let ready = observers.filter { $0.0 <= arrivals }
        observers.removeAll { $0.0 <= arrivals }
        for (_, continuation) in ready { continuation.resume() }
        if blocked {
            await withCheckedContinuation { parked.append($0) }
        }
    }

    func wait(_ count: Int = 1) async {
        if arrivals >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func releaseOne() {
        precondition(!parked.isEmpty)
        parked.removeFirst().resume()
    }

    func release() {
        blocked = false
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

enum R01Hooks {
    static let read = R01Gate()
    static let replay = R01Gate()
    static let replayed = R01Gate()
    static let sinkEnded = R01Gate()
    static let latest = R01Gate()
    static let switched = R01Gate()
}
