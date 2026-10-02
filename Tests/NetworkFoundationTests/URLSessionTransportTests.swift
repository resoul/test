import Foundation
import NetworkCore
import Testing

@testable import NetworkFoundation

private func transport(redirects: URLSessionTransport.RedirectPolicy = .follow)
    -> URLSessionTransport
{
    // A session of its own, so that no test shares cookies or a cache with another.
    URLSessionTransport(session: URLSession(configuration: .ephemeral), redirects: redirects)
}

private func text(_ response: HTTPResponse) -> String {
    String(decoding: response.body, as: UTF8.self)
}

@Test(.timeLimit(.minutes(1)))
func aRequestReachesTheServerAsItWasAndTheAnswerComesBackWhole() async throws {
    let server = try await LocalServer.start { _ in
        ServerReply(201, "created", headers: [("X-Reply", "yes"), ("Content-Type", "text/plain")])
    }
    defer { server.stop() }

    let response = try await transport().send(
        HTTPRequest(
            .post,
            server.url("/things?a=1"),
            headers: ["X-Mine": "one", "Content-Type": "application/json"],
            body: Data(#"{"k":1}"#.utf8)
        ),
        maxResponseBytes: nil
    )

    #expect(response.status == 201)
    #expect(text(response) == "created")
    #expect(response.headers["x-reply"] == "yes")
    let seen = try #require(server.requests.first)
    #expect(seen.method == "POST")
    #expect(seen.path == "/things?a=1")
    #expect(seen.headers["x-mine"] == "one")
    #expect(seen.headers["content-type"] == "application/json")
    #expect(String(decoding: seen.body, as: UTF8.self) == #"{"k":1}"#)
}

@Test(.timeLimit(.minutes(1)))
func theTransportReturnsAnyStatusWithoutJudgingIt() async throws {
    let server = try await LocalServer.start { request in
        switch request.path {
        case "/empty": ServerReply(204)
        case "/missing": ServerReply(404, "nope")
        default: ServerReply(500, "boom")
        }
    }
    defer { server.stop() }
    let transport = transport()

    let empty = try await transport.send(
        HTTPRequest(.delete, server.url("/empty")),
        maxResponseBytes: nil
    )
    let missing = try await transport.send(
        HTTPRequest(.get, server.url("/missing")),
        maxResponseBytes: nil
    )
    let broken = try await transport.send(
        HTTPRequest(.get, server.url("/broken")),
        maxResponseBytes: nil
    )

    #expect(empty.status == 204 && empty.body.isEmpty)
    #expect(missing.status == 404 && text(missing) == "nope")
    #expect(broken.status == 500 && text(broken) == "boom")
}

@Test(.timeLimit(.minutes(1)))
func aHeadRequestHasNoBodyEvenWhenItAnnouncesALength() async throws {
    let server = try await LocalServer.start { _ in
        var reply = ServerReply(200, "twelve bytes")
        reply.announcedLength = 12
        return reply
    }
    defer { server.stop() }

    let response = try await transport().send(
        HTTPRequest(.head, server.url("/")),
        maxResponseBytes: 4
    )

    #expect(response.status == 200)
    #expect(response.body.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func anAnswerThatAnnouncesMoreThanTheLimitIsRefusedBeforeItsBodyIsRead() async throws {
    let server = try await LocalServer.start { _ in
        // URLSession hands over the answer once the first sizable piece of the body has come, so
        // the server sends one and then goes quiet, as a server with a long body would.
        var reply = ServerReply(200, String(repeating: "x", count: 20_000))
        reply.announcedLength = 5_000_000
        reply.keepOpen = .seconds(5)
        return reply
    }
    defer { server.stop() }

    await #expect {
        try await transport().send(HTTPRequest(.get, server.url("/")), maxResponseBytes: 1000)
    } throws: { error in
        guard case HTTPError.responseTooLarge(let limit) = error else { return false }
        return limit == 1000
    }
}

@Test(.timeLimit(.minutes(1)))
func aBodyThatGrowsPastTheLimitIsCutOffEvenWithoutAnAnnouncedLength() async throws {
    let big = String(repeating: "x", count: 100_000)
    let server = try await LocalServer.start { _ in
        var reply = ServerReply(200, big)
        reply.announcesLength = false
        return reply
    }
    defer { server.stop() }
    let transport = transport()

    await #expect {
        try await transport.send(HTTPRequest(.get, server.url("/")), maxResponseBytes: 10_000)
    } throws: { error in
        if case HTTPError.responseTooLarge = error { return true }
        return false
    }
    // Within the limit the same answer arrives whole.
    let whole = try await transport.send(
        HTTPRequest(.get, server.url("/")),
        maxResponseBytes: 100_000
    )
    #expect(whole.body.count == 100_000)
}

@Test(.timeLimit(.minutes(1)))
func aRequestThatGetsNoAnswerInTimeFailsAsATimeout() async throws {
    let server = try await LocalServer.start { _ in ServerReply(200, "late", delay: .seconds(3)) }
    defer { server.stop() }

    await #expect {
        try await transport().send(
            HTTPRequest(.get, server.url("/"), timeout: 0.3),
            maxResponseBytes: nil
        )
    } throws: { error in
        guard case HTTPError.transport(let failure) = error else { return false }
        return failure.kind == .timedOut
    }
}

@Test(.timeLimit(.minutes(1)))
func cancellingTheTaskCancelsTheRequestAndTheServerSeesTheConnectionClose() async throws {
    let server = try await LocalServer.start { _ in ServerReply(200, "never", delay: .seconds(20)) }
    defer { server.stop() }
    let transport = transport()

    let task = Task {
        try await transport.send(HTTPRequest(.get, server.url("/")), maxResponseBytes: nil)
    }
    while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    task.cancel()

    await #expect {
        try await task.value
    } throws: { error in
        if case HTTPError.cancelled = error { return true }
        return false
    }
    // The cancellation reached the socket, not only the waiting task.
    for _ in 0..<400 where server.abandoned == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(server.abandoned == 1)
}

@Test(.timeLimit(.minutes(1)))
func aServerThatIsNotListeningIsAConnectionFailure() async throws {
    let server = try await LocalServer.start { _ in ServerReply() }
    let url = server.url("/")
    server.stop()
    try await Task.sleep(for: .milliseconds(100))

    await #expect {
        try await transport().send(HTTPRequest(.get, url), maxResponseBytes: nil)
    } throws: { error in
        guard case HTTPError.transport(let failure) = error else { return false }
        return failure.kind == .cannotConnect
    }
}

@Test
func aURLThatIsNotHTTPIsRefusedBeforeAnythingIsSent() async throws {
    for text in ["file:///etc/hosts", "ftp://example.com/a", "mailto:a@b.c"] {
        await #expect {
            try await transport().send(HTTPRequest(.get, URL(string: text)!), maxResponseBytes: nil)
        } throws: { error in
            if case HTTPError.invalidRequest = error { return true }
            return false
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func aRedirectWithinTheOriginIsFollowedAndKeepsTheCredentials() async throws {
    let server = try await LocalServer.start { request in
        request.path == "/old"
            ? ServerReply(302, headers: [("Location", "/new")]) : ServerReply(200, "arrived")
    }
    defer { server.stop() }

    let response = try await transport().send(
        HTTPRequest(.get, server.url("/old"), headers: ["Authorization": "Bearer t"]),
        maxResponseBytes: nil
    )

    #expect(text(response) == "arrived")
    #expect(response.url.path == "/new")
    #expect(server.requests.map(\.path) == ["/old", "/new"])
    #expect(server.requests[1].headers["authorization"] == "Bearer t")
}

@Test(.timeLimit(.minutes(1)))
func aRedirectToAnotherOriginDropsTheCredentialsButNotOtherHeaders() async throws {
    let elsewhere = try await LocalServer.start { _ in ServerReply(200, "elsewhere") }
    defer { elsewhere.stop() }
    let origin = try await LocalServer.start { _ in
        ServerReply(302, headers: [("Location", elsewhere.url("/landing").absoluteString)])
    }
    defer { origin.stop() }

    let response = try await transport().send(
        HTTPRequest(
            .get,
            origin.url("/start"),
            headers: [
                "Authorization": "Bearer secret", "Cookie": "session=1",
                "Proxy-Authorization": "Basic x", "X-Trace": "keep",
            ]
        ),
        maxResponseBytes: nil
    )

    #expect(text(response) == "elsewhere")
    // The first server got everything; the one redirected to got only what is not a credential.
    #expect(origin.requests[0].headers["authorization"] == "Bearer secret")
    let landed = try #require(elsewhere.requests.first)
    #expect(landed.headers["authorization"] == nil)
    #expect(landed.headers["cookie"] == nil)
    #expect(landed.headers["proxy-authorization"] == nil)
    #expect(landed.headers["x-trace"] == "keep")
}

@Test(.timeLimit(.minutes(1)))
func aRefusedRedirectIsReturnedAsTheRedirectItself() async throws {
    let server = try await LocalServer.start { _ in
        ServerReply(302, headers: [("Location", "/new")])
    }
    defer { server.stop() }

    let response = try await transport(redirects: .refuse).send(
        HTTPRequest(.get, server.url("/old")),
        maxResponseBytes: nil
    )

    #expect(response.status == 302)
    #expect(response.headers["location"] == "/new")
    #expect(server.requests.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func cookiesInTheSessionAreNotSentUnlessTheRequestCarriesThem() async throws {
    let server = try await LocalServer.start { _ in ServerReply(200) }
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    let storage = try #require(configuration.httpCookieStorage)
    storage.setCookie(
        try #require(
            HTTPCookie(properties: [
                .domain: "127.0.0.1", .path: "/", .name: "session", .value: "leaky",
            ])
        )
    )
    let transport = URLSessionTransport(session: URLSession(configuration: configuration))

    _ = try await transport.send(HTTPRequest(.get, server.url("/")), maxResponseBytes: nil)

    #expect(server.requests[0].headers["cookie"] == nil)
}

@Test
func systemErrorsAreSortedIntoKinds() {
    func kind(_ code: URLError.Code) -> TransportFailure.Kind? {
        guard case .transport(let failure) = URLSessionTransport.map(URLError(code)) else {
            return nil
        }
        return failure.kind
    }

    #expect(kind(.timedOut) == .timedOut)
    #expect(kind(.networkConnectionLost) == .connectionLost)
    #expect(kind(.cannotConnectToHost) == .cannotConnect)
    #expect(kind(.dnsLookupFailed) == .cannotConnect)
    #expect(kind(.notConnectedToInternet) == .notConnected)
    #expect(kind(.serverCertificateUntrusted) == .secureConnectionFailed)
    #expect(kind(.cannotParseResponse) == .other)
    guard case .cancelled = URLSessionTransport.map(URLError(.cancelled)) else {
        Issue.record("A URLError.cancelled was not a cancellation")
        return
    }
    guard case .cancelled = URLSessionTransport.map(CancellationError()) else {
        Issue.record("A CancellationError was not a cancellation")
        return
    }
}
