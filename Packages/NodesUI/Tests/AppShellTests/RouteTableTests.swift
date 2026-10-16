import Foundation
import Nodes
import Testing

@testable import AppShell

private enum Shop: Hashable {
    case home
    case catalog
    case listing(category: String)
    case product(id: Int)
    case newArrivals
    case account
    case order(Int)
    case search(String)
    case file(String)
}

private let routes = RouteTable<Shop> {
    RoutePattern("/", .home)
    RoutePattern("/catalog", .catalog)
    RoutePattern(
        "/catalog/:category",
        route: { .listing(category: try $0.value("category")) },
        values: { route in
            guard case .listing(let category) = route else { return nil }
            return ["category": category]
        }
    )
    RoutePattern(
        "/catalog/:category/:id",
        route: { .product(id: try $0.value("id")) },
        values: { route in
            guard case .product(let id) = route else { return nil }
            return ["id": String(id)]
        }
    )
    RoutePattern("/catalog/new", .newArrivals)
    RoutePattern("/account", .account)
    RoutePattern(
        "/account/orders/:id",
        route: { .order(try $0.value("id")) },
        values: { route in
            guard case .order(let id) = route else { return nil }
            return ["id": String(id)]
        }
    )
    RoutePattern(
        "/search",
        route: { .search($0["q"] ?? "") },
        values: { _ in nil }
    )
    RoutePattern(
        "/files/*path",
        route: { .file(try $0.value("path")) },
        values: { route in
            guard case .file(let path) = route else { return nil }
            return ["path": path]
        }
    )
}

@Test
func aURLStandsForAScreenForEachBeginningAPatternTakes() throws {
    #expect(
        try routes.path(for: "/catalog/shoes/42")
            == [.home, .catalog, .listing(category: "shoes"), .product(id: 42)]
    )
    #expect(try routes.path(for: "/") == [.home])
    // `/account/orders` has no screen of its own.
    #expect(try routes.path(for: "/account/orders/7") == [.home, .account, .order(7)])
    #expect(
        try routes.path(for: URL(string: "shop://app/catalog/shoes")!)
            == [.home, .catalog, .listing(category: "shoes")]
    )
}

@Test
func aSegmentNamedGoesBeforeAParameter() throws {
    #expect(try routes.path(for: "/catalog/new") == [.home, .catalog, .newArrivals])
}

@Test
func aURLNotTakenWholeOrWithAWrongValueHasNoPath() {
    #expect(throws: RouteError.unknownPath("/catalog/shoes/42/reviews")) {
        try routes.path(for: "/catalog/shoes/42/reviews")
    }
    #expect(throws: RouteError.invalidParameter("id", "abc")) {
        try routes.path(for: "/catalog/shoes/abc")
    }
    #expect(throws: RouteError.unknownPath("/nowhere")) {
        try routes.path(for: "/nowhere")
    }
}

@Test
func theQueryAndTheRestOfThePathAreValuesToo() throws {
    #expect(try routes.path(for: "/search?q=red%20shoes") == [.home, .search("red shoes")])
    #expect(try routes.path(for: "/files/a/b%20c/d.txt") == [.home, .file("a/b c/d.txt")])
}

@Test
func aPathsURLTakesTheValuesOfAllItsRoutes() throws {
    let path: [Shop] = [.home, .catalog, .listing(category: "red shoes"), .product(id: 42)]

    #expect(routes.url(for: path) == "/catalog/red%20shoes/42")
    #expect(try routes.path(for: routes.url(for: path)!) == path)
    #expect(routes.url(for: .catalog) == "/catalog")
    #expect(routes.url(for: [.home]) == "/")
    #expect(routes.url(for: .file("a/b c")) == "/files/a/b%20c")
    // A product alone has no category to put in its URL.
    #expect(routes.url(for: .product(id: 42)) == nil)
    #expect(routes.url(for: .search("red")) == nil)
}

@Test @MainActor
func aStackOpensTheScreensOfAURL() throws {
    let stack = Stack(root: Shop.home) { _ in NodeScreen(Node()) }

    #expect(stack.setPath(try routes.path(for: "/catalog/shoes/42")) == .accepted)
    #expect(routes.url(for: stack.path) == "/catalog/shoes/42")
    stack.pop()
    #expect(routes.url(for: stack.path) == "/catalog/shoes")
}
