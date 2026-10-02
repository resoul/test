import Foundation
import NetworkCore
import Testing

private let unavailable = reply(503)

private func policy(_ attempts: Int = 3, maxDelay: TimeInterval = 30) -> RetryPolicy {
    RetryPolicy(
        maxAttempts: attempts,
        initialDelay: 0.5,
        multiplier: 2,
        maxDelay: maxDelay,
        jitter: 0.2
    )
}

@Test
func aGetThatFailsWithAServerErrorIsSentAgain() async throws {
    let transport = FakeTransport(script: [.success(unavailable), .success(reply(200, "ok"))])
    let waits = Waits()
    let client = makeClient(transport, retry: policy(), waits: waits)

    let response = try await client.send(HTTPRequest(.get, testURL))

    #expect(response.status == 200)
    #expect(await transport.requests.count == 2)
    #expect(waits.delays == [0.5])
}

@Test
func waitsGrowByTheMultiplierUpToTheCap() async throws {
    let transport = FakeTransport(script: [.success(unavailable)])
    let waits = Waits()
    let client = makeClient(transport, retry: policy(5, maxDelay: 1.5), waits: waits)

    await #expect(throws: HTTPError.self) { try await client.send(HTTPRequest(.get, testURL)) }

    #expect(waits.delays == [0.5, 1, 1.5, 1.5])
    #expect(await transport.requests.count == 5)
}

@Test
func whenAttemptsRunOutTheLastAnswerIsTheError() async throws {
    let transport = FakeTransport(script: [.success(unavailable)])
    let client = makeClient(transport, retry: policy(3))

    await #expect {
        try await client.send(HTTPRequest(.get, testURL))
    } throws: { error in
        guard case HTTPError.status(let response) = error else { return false }
        return response.status == 503
    }
    #expect(await transport.requests.count == 3)
}

@Test
func jitterMovesAWaitWithinItsFraction() async throws {
    func firstWait(random: Double) async throws -> TimeInterval {
        let waits = Waits()
        var client = makeClient(
            FakeTransport(script: [.success(unavailable), .success(reply(200))]),
            retry: policy(),
            waits: waits
        )
        client.environment.random = { random }
        _ = try await client.send(HTTPRequest(.get, testURL))
        return waits.delays[0]
    }

    #expect(abs(try await firstWait(random: 0) - 0.4) < 1e-9)
    #expect(abs(try await firstWait(random: 1) - 0.6) < 1e-9)
}

@Test
func aRepeatIsNeverAutomaticForAPostWithoutAnIdempotencyKey() async throws {
    for method in [HTTPMethod.post, .patch] {
        let transport = FakeTransport(script: [.success(unavailable), .success(reply(200))])
        let client = makeClient(transport, retry: policy())

        await #expect(throws: HTTPError.self) {
            try await client.send(HTTPRequest(method, testURL, body: Data("x".utf8)))
        }
        #expect(await transport.requests.count == 1, "\(method) must not be repeated")
    }
}

@Test
func aPostWithAnIdempotencyKeyAndPutAndDeleteAreRepeated() async throws {
    let requests = [
        HTTPRequest(.post, testURL, headers: ["Idempotency-Key": "abc"], body: Data("x".utf8)),
        HTTPRequest(.put, testURL, body: Data("x".utf8)),
        HTTPRequest(.delete, testURL),
    ]
    for request in requests {
        let transport = FakeTransport(script: [.success(unavailable), .success(reply(200))])
        let client = makeClient(transport, retry: policy())

        let response = try await client.send(request)

        #expect(response.status == 200)
        // The repeat is the request as it was, body and key included.
        let sent = await transport.requests
        #expect(sent.count == 2)
        #expect(sent[1].body == request.body)
        #expect(sent[1].headers["Idempotency-Key"] == request.headers["Idempotency-Key"])
    }
}

@Test
func statusesThatAreNotTemporaryAreNotRepeated() async throws {
    for status in [400, 401, 403, 404, 409, 422] {
        let transport = FakeTransport(script: [.success(reply(status))])
        let client = makeClient(transport, retry: policy())

        await #expect(throws: HTTPError.self) { try await client.send(HTTPRequest(.get, testURL)) }
        #expect(await transport.requests.count == 1, "\(status) must not be repeated")
    }
}

@Test
func retryAfterInSecondsSetsTheWaitWhenItIsLongerThanTheComputedOne() async throws {
    let transport = FakeTransport(script: [
        .success(reply(429, headers: ["Retry-After": "7"])), .success(reply(200)),
    ])
    let waits = Waits()
    let client = makeClient(transport, retry: policy(), waits: waits)

    _ = try await client.send(HTTPRequest(.get, testURL))

    #expect(waits.delays == [7])
}

@Test
func aShortRetryAfterDoesNotShortenTheBackoff() async throws {
    let transport = FakeTransport(script: [
        .success(reply(503, headers: ["Retry-After": "0"])), .success(reply(200)),
    ])
    let waits = Waits()
    let client = makeClient(transport, retry: policy(), waits: waits)

    _ = try await client.send(HTTPRequest(.get, testURL))

    #expect(waits.delays == [0.5])
}

@Test
func retryAfterAsADateIsMeasuredFromTheClock() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let when = formatter.string(from: now.addingTimeInterval(12))
    let transport = FakeTransport(script: [
        .success(reply(503, headers: ["Retry-After": when])), .success(reply(200)),
    ])
    let waits = Waits()
    let client = makeClient(transport, retry: policy(), waits: waits, now: now)

    _ = try await client.send(HTTPRequest(.get, testURL))

    #expect(waits.delays == [12])
}

@Test
func aRetryAfterBeyondThePolicysLimitIsNotWaitedOut() async throws {
    let transport = FakeTransport(script: [.success(reply(503, headers: ["Retry-After": "3600"]))])
    let waits = Waits()
    let client = makeClient(transport, retry: policy(), waits: waits)

    await #expect {
        try await client.send(HTTPRequest(.get, testURL))
    } throws: { error in
        guard case HTTPError.status(let response) = error else { return false }
        return response.status == 503
    }
    #expect(await transport.requests.count == 1)
    #expect(waits.delays.isEmpty)
}

@Test
func transportFailuresAreRepeatedOnlyWhenTheyAreTemporaryAndTheMethodIsSafe() async throws {
    struct Cause: Error {}
    func failure(_ kind: TransportFailure.Kind) -> Result<HTTPResponse, HTTPError> {
        .failure(.transport(TransportFailure(kind: kind, underlying: Cause())))
    }

    for kind in [TransportFailure.Kind.timedOut, .connectionLost] {
        let transport = FakeTransport(script: [failure(kind), .success(reply(200))])
        let client = makeClient(transport, retry: policy())
        #expect(try await client.send(HTTPRequest(.get, testURL)).status == 200)
        #expect(await transport.requests.count == 2)
    }

    for kind in [TransportFailure.Kind.cannotConnect, .notConnected, .secureConnectionFailed] {
        let transport = FakeTransport(script: [failure(kind), .success(reply(200))])
        let client = makeClient(transport, retry: policy())
        await #expect(throws: HTTPError.self) { try await client.send(HTTPRequest(.get, testURL)) }
        #expect(await transport.requests.count == 1, "\(kind) must not be repeated")
    }

    // The server may have acted before the connection broke, so a plain POST is not repeated.
    let transport = FakeTransport(script: [failure(.connectionLost), .success(reply(200))])
    let client = makeClient(transport, retry: policy())
    await #expect(throws: HTTPError.self) {
        try await client.send(HTTPRequest(.post, testURL, body: Data("x".utf8)))
    }
    #expect(await transport.requests.count == 1)
}

@Test
func aCancellationIsNeverRepeated() async throws {
    let transport = FakeTransport(script: [.failure(.cancelled), .success(reply(200))])
    let client = makeClient(transport, retry: policy())

    await #expect(throws: HTTPError.self) { try await client.send(HTTPRequest(.get, testURL)) }

    #expect(await transport.requests.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func cancellingDuringAWaitEndsItAndSendsNothingMore() async throws {
    let transport = FakeTransport(script: [.success(unavailable), .success(reply(200))])
    // A real sleep, and a wait long enough that only cancellation can end it.
    let client = HTTPClient(
        transport: transport,
        retry: RetryPolicy(maxAttempts: 3, initialDelay: 600, jitter: 0)
    )
    let task = Task { try await client.send(HTTPRequest(.get, testURL)) }
    while await transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    try await Task.sleep(for: .milliseconds(20))

    task.cancel()

    await #expect {
        try await task.value
    } throws: { error in
        if case HTTPError.cancelled = error { return true }
        return false
    }
    #expect(await transport.requests.count == 1)
}

@Test
func eachRetryIsReportedWithItsReasonAndWait() async throws {
    let events = Events()
    let client = makeClient(
        FakeTransport(script: [.success(unavailable), .success(reply(200))]),
        retry: policy(),
        events: events
    )

    _ = try await client.send(HTTPRequest(.get, testURL))

    #expect(
        events.all.contains(
            .retrying(
                method: "GET",
                url: "https://api.example.com/items",
                attempt: 1,
                delay: 0.5,
                reason: "status 503"
            )
        )
    )
    #expect(events.all.count == 5)
}
