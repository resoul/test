import Foundation
import NetworkCore
import Testing

@Test
func headerNamesAreMatchedWithoutRegardToCase() {
    var headers: HTTPHeaders = ["Content-Type": "text/plain"]

    #expect(headers["content-type"] == "text/plain")
    headers["CONTENT-TYPE"] = "application/json"
    #expect(headers.all.count == 1)
    #expect(headers["Content-Type"] == "application/json")

    headers.add("a", for: "X-Multi")
    headers.add("b", for: "x-multi")
    #expect(headers.values(for: "X-MULTI") == ["a", "b"])
    headers["x-multi"] = nil
    #expect(headers["X-Multi"] == nil)
}

@Test
func headersCompareEqualWhateverTheCaseAndOrder() {
    let first: HTTPHeaders = ["A": "1", "B": "2"]
    let second: HTTPHeaders = ["b": "2", "a": "1"]

    #expect(first == second)
    #expect(first != ["A": "1"])
}

@Test
func methodsKnowWhetherRepeatingThemIsSafe() {
    for method in [HTTPMethod.get, .head, .options, .put, .delete] {
        #expect(method.isIdempotent, "\(method) should be idempotent")
    }
    for method in [HTTPMethod.post, .patch] {
        #expect(!method.isIdempotent, "\(method) should not be idempotent")
    }
    #expect(HTTPMethod("report").name == "REPORT")
}

@Test
func anOriginIsSchemeHostAndPortWithDefaults() throws {
    let a = try #require(HTTPOrigin(URL(string: "https://Example.com/a")!))
    let b = try #require(HTTPOrigin(URL(string: "https://example.com:443/b?x=1")!))
    let c = try #require(HTTPOrigin(URL(string: "https://example.com:8443/a")!))
    let d = try #require(HTTPOrigin(URL(string: "http://example.com/a")!))

    #expect(a == b)
    #expect(a != c)
    #expect(a != d)
    #expect(d.port == 80)
    #expect(HTTPOrigin(URL(string: "ftp://example.com/a")!) == nil)
    #expect(HTTPOrigin(URL(string: "file:///tmp/a")!) == nil)
}

@Test
func aJSONRequestCarriesItsBodyAndHeadersButKeepsOnesAlreadySet() throws {
    let request = try HTTPRequest.json(
        .post,
        testURL,
        body: Item(id: 1, name: "a"),
        headers: ["Accept": "application/vnd.api+json"]
    )

    #expect(request.method == .post)
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(request.headers["Accept"] == "application/vnd.api+json")
    #expect(
        try JSONDecoder().decode(Item.self, from: try #require(request.body))
            == Item(id: 1, name: "a")
    )
}

@Test
func aValueThatCannotBeEncodedIsAnEncodingErrorBeforeAnythingIsSent() {
    #expect {
        try HTTPRequest.json(.post, testURL, body: Double.nan)
    } throws: { error in
        if case HTTPError.encoding = error { return true }
        return false
    }
}
