import Foundation
import NetworkCore
import Testing

private func connectedURL(
    base: String,
    path: String,
    query: [URLQueryItem] = [],
    headers: HTTPHeaders = [:]
) async throws -> HTTPRequest {
    let transport = FakeSocketTransport([.connection(FakeConnection())])
    let client = try WebSocketClient(
        baseURL: URL(string: base)!,
        path: path,
        query: query,
        headers: headers,
        transport: transport
    )
    await client.connect()
    #expect(await waitUntil { transport.connectCount == 1 })
    await client.close()
    return try #require(transport.requests.first)
}

@Test(.timeLimit(.minutes(1)))
func theSocketsAddressIsThePathOnTheBaseWithEachSegmentEncoded() async throws {
    let request = try await connectedURL(
        base: "wss://api.example.com/v1/",
        path: "/rooms/a b/live",
        query: [URLQueryItem(name: "since", value: "1+2&3")],
        headers: ["X-Mine": "1"]
    )

    #expect(
        request.url.absoluteString
            == "wss://api.example.com/v1/rooms/a%20b/live?since=1%2B2%263"
    )
    #expect(request.method == .get)
    #expect(request.headers["x-mine"] == "1")
}

@Test(.timeLimit(.minutes(1)))
func aBaseOfAnyOfTheFourSchemesIsAccepted() async throws {
    for scheme in ["ws", "wss", "http", "https"] {
        let request = try await connectedURL(base: "\(scheme)://example.com", path: "live")
        #expect(request.url.absoluteString == "\(scheme)://example.com/live")
    }
}

@Test
func aBaseWithAnotherSchemeOrAPathThatClimbsIsRefusedBeforeAnythingIsMade() {
    let transport = FakeSocketTransport([.connection(FakeConnection())])
    for (base, path) in [("ftp://example.com", "live"), ("wss://example.com/v1", "../admin")] {
        do {
            _ = try WebSocketClient(
                baseURL: URL(string: base)!,
                path: path,
                transport: transport
            )
            Issue.record("\(base) \(path) was accepted")
        } catch {
            guard case .invalidRequest = error else {
                Issue.record("expected invalidRequest, got \(error)")
                continue
            }
        }
    }
    #expect(transport.connectCount == 0)
}
