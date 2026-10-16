import Foundation
import NetworkCore
import Testing

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func validators(_ headers: HTTPHeaders, keeping: HTTPValidators? = nil) -> HTTPValidators {
    HTTPValidators(headers: headers, now: now, keeping: keeping)
}

@Test
func maxAgeCountsFromTheResponseMinusItsAge() {
    #expect(validators(["Cache-Control": "max-age=600"]).freshUntil == now.addingTimeInterval(600))
    #expect(
        validators(["Cache-Control": "max-age=600", "Age": "100"]).freshUntil
            == now.addingTimeInterval(500)
    )
    // An age past the lifetime is stale at once, not in the past.
    #expect(
        validators(["Cache-Control": "max-age=60", "Age": "100"]).freshUntil == now
    )
}

@Test
func noCacheIsStaleAtOnceAndBeatsMaxAge() {
    let result = validators(["Cache-Control": "no-cache, max-age=600"])

    #expect(result.freshUntil == now)
    #expect(!result.isFresh(at: now))
}

@Test
func directivesAreReadWithoutRegardToCaseSpacingOrQuotes() {
    #expect(
        validators(["cache-control": "Public,  MAX-AGE = \"120\" "]).freshUntil
            == now.addingTimeInterval(120)
    )
    #expect(HTTPValidators.forbidsStoring(["Cache-Control": "private, No-Store"]))
    #expect(!HTTPValidators.forbidsStoring(["Cache-Control": "private, max-age=5"]))
    #expect(!HTTPValidators.forbidsStoring([:]))
}

@Test
func directivesRepeatedAcrossHeaderLinesAreAllRead() {
    var headers = HTTPHeaders()
    headers.add("max-age=30", for: "Cache-Control")
    headers.add("no-store", for: "Cache-Control")

    #expect(HTTPValidators.forbidsStoring(headers))
    #expect(validators(headers).freshUntil == now.addingTimeInterval(30))
}

@Test
func expiresIsUsedWithoutMaxAgeAndAnInvalidDateMeansExpired() {
    let expires = validators(["Expires": "Sun, 06 Nov 1994 08:49:37 GMT"])
    #expect(expires.freshUntil == Date(timeIntervalSince1970: 784_111_777))

    #expect(validators(["Expires": "tomorrow, probably"]).freshUntil == now)
    // `max-age` wins over `Expires`.
    #expect(
        validators(["Cache-Control": "max-age=10", "Expires": "Sun, 06 Nov 1994 08:49:37 GMT"])
            .freshUntil == now.addingTimeInterval(10)
    )
}

@Test
func aResponseThatSaysNothingAboutFreshnessIsFreshForAsLongAsTheCacheKeepsIt() {
    let result = validators(["ETag": "\"v1\""])

    #expect(result.freshUntil == nil)
    #expect(result.isFresh(at: now.addingTimeInterval(86_400 * 365)))
}

@Test
func aCheckAnsweredWithNotModifiedKeepsTheValidatorsItDoesNotRepeat() {
    let stored = HTTPValidators(etag: "\"v1\"", lastModified: "Sat, 01 Jan 2022 00:00:00 GMT")

    let renewed = validators(["Cache-Control": "max-age=60", "ETag": "\"v2\""], keeping: stored)

    #expect(renewed.etag == "\"v2\"", "a validator the answer does state replaces the old one")
    #expect(renewed.lastModified == "Sat, 01 Jan 2022 00:00:00 GMT")
    #expect(renewed.freshUntil == now.addingTimeInterval(60))
}

@Test
func conditionalHeadersNameOnlyTheValidatorsThereAre() {
    let both = HTTPValidators(etag: "\"v1\"", lastModified: "Sat, 01 Jan 2022 00:00:00 GMT")
    #expect(both.canRevalidate)
    #expect(both.conditionalHeaders["If-None-Match"] == "\"v1\"")
    #expect(both.conditionalHeaders["If-Modified-Since"] == "Sat, 01 Jan 2022 00:00:00 GMT")

    let onlyDate = HTTPValidators(lastModified: "Sat, 01 Jan 2022 00:00:00 GMT")
    #expect(onlyDate.conditionalHeaders["If-None-Match"] == nil)
    #expect(onlyDate.canRevalidate)

    let neither = HTTPValidators(freshUntil: now)
    #expect(!neither.canRevalidate)
    #expect(neither.conditionalHeaders.isEmpty)
}

@Test
func validatorsSurviveEncodingAsTheyAreStoredWithACacheEntry() throws {
    let original = HTTPValidators(
        etag: "\"v1\"",
        lastModified: "Sat, 01 Jan 2022 00:00:00 GMT",
        freshUntil: now
    )

    let decoded = try JSONDecoder().decode(
        HTTPValidators.self,
        from: try JSONEncoder().encode(original)
    )

    #expect(decoded == original)
}
