import Foundation
import NetworkCore
import Testing

@Test
func aSuccessfulAnswerIsReturnedAsItCame() async throws {
    let transport = FakeTransport(script: [.success(reply(200, "hello", headers: ["X-A": "1"]))])
    let client = makeClient(transport)

    let response = try await client.send(HTTPRequest(.get, testURL))

    #expect(response.status == 200)
    #expect(String(decoding: response.body, as: UTF8.self) == "hello")
    #expect(response.headers["x-a"] == "1")
}

@Test
func anEmptyNoContentAnswerIsSuccessWithoutABody() async throws {
    let client = makeClient(FakeTransport(script: [.success(reply(204))]))

    let response = try await client.send(HTTPRequest(.delete, testURL))

    #expect(response.status == 204)
    #expect(response.body.isEmpty)
}

@Test
func anUnexpectedStatusIsAnErrorThatCarriesTheWholeResponse() async throws {
    let client = makeClient(FakeTransport(script: [.success(reply(404, #"{"error":"gone"}"#))]))

    await #expect {
        try await client.send(HTTPRequest(.get, testURL))
    } throws: { error in
        guard case HTTPError.status(let response) = error else { return false }
        return response.status == 404
            && String(decoding: response.body, as: UTF8.self).contains("gone")
    }
}

@Test
func aCallerCanAcceptAStatusLikeNotFoundAsAnAnswer() async throws {
    let client = makeClient(FakeTransport(script: [.success(reply(404))]))

    let response = try await client.send(
        HTTPRequest(.get, testURL),
        expecting: .success(or: 404)
    )

    #expect(response.status == 404)
}

@Test
func aSuccessBodyDecodesAsJSON() async throws {
    let client = makeClient(FakeTransport(script: [.success(reply(200, #"{"id":7,"name":"n"}"#))]))

    let item = try await client.send(HTTPRequest(.get, testURL), as: Item.self)

    #expect(item == Item(id: 7, name: "n"))
}

@Test
func anEmptyBodyAndABadBodyAreDifferentErrorsFromAStatus() async throws {
    let empty = makeClient(FakeTransport(script: [.success(reply(204))]))
    await #expect {
        try await empty.send(HTTPRequest(.get, testURL), as: Item.self)
    } throws: { error in
        if case HTTPError.emptyResponse = error { return true }
        return false
    }

    let bad = makeClient(FakeTransport(script: [.success(reply(200, #"{"id":"not a number"}"#))]))
    await #expect {
        try await bad.send(HTTPRequest(.get, testURL), as: Item.self)
    } throws: { error in
        if case HTTPError.decoding = error { return true }
        return false
    }
}

@Test
func defaultHeadersAreAddedWhereARequestDoesNotSetThem() async throws {
    let transport = FakeTransport(script: [.success(reply(200))])
    var client = makeClient(transport)
    client.defaultHeaders = ["Accept": "application/json", "X-App": "demo"]

    _ = try await client.send(HTTPRequest(.get, testURL, headers: ["accept": "text/plain"]))

    let sent = try #require(await transport.requests.first)
    #expect(sent.headers["Accept"] == "text/plain")
    #expect(sent.headers["X-App"] == "demo")
}

@Test
func theResponseLimitReachesTheTransport() async throws {
    let transport = FakeTransport(script: [.success(reply(200))])
    var client = makeClient(transport)
    client.maxResponseBytes = 1234

    _ = try await client.send(HTTPRequest(.get, testURL))

    #expect(await transport.limits == [1234])
}

@Test
func aTransportFailureAndACancellationArePassedOnAsTheyAre() async throws {
    struct Cause: Error {}
    let failing = makeClient(
        FakeTransport(script: [
            .failure(.transport(TransportFailure(kind: .notConnected, underlying: Cause())))
        ])
    )
    await #expect {
        try await failing.send(HTTPRequest(.get, testURL))
    } throws: { error in
        guard case HTTPError.transport(let failure) = error else { return false }
        return failure.kind == .notConnected && failure.underlying is Cause
    }

    let cancelled = makeClient(FakeTransport(script: [.failure(.cancelled)]))
    await #expect {
        try await cancelled.send(HTTPRequest(.get, testURL))
    } throws: { error in
        if case HTTPError.cancelled = error { return true }
        return false
    }
}

@Test
func aTaskCancelledBeforeSendingNeverReachesTheTransport() async throws {
    let transport = FakeTransport(script: [.success(reply(200))])
    let client = makeClient(transport)

    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return try await client.send(HTTPRequest(.get, testURL))
    }
    task.cancel()

    await #expect {
        try await task.value
    } throws: { error in
        if case HTTPError.cancelled = error { return true }
        return false
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func eventsDescribeTheRequestWithoutItsQueryHeadersOrBody() async throws {
    let events = Events()
    let client = makeClient(
        FakeTransport(script: [.success(reply(200))]),
        events: events
    )

    _ = try await client.send(
        HTTPRequest(
            .post,
            testURL,
            headers: ["Authorization": "Bearer hunter2"],
            body: Data("pw".utf8)
        )
    )

    #expect(
        events.all == [
            .sending(method: "POST", url: "https://api.example.com/items", attempt: 1),
            .received(
                method: "POST",
                url: "https://api.example.com/items",
                status: 200,
                attempt: 1
            ),
        ]
    )
    let text = "\(events.all)"
    #expect(!text.contains("secret") && !text.contains("hunter2") && !text.contains("frag"))
}
