import Foundation

/// The values a URL gave a route: its `:parameters`, its `*rest`, and its query.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct RouteParameters: Hashable, Sendable {
    /// The path's parameters by name, decoded.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let values: [String: String]

    /// The query's items by name, decoded; the last of a repeated name.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let query: [String: String]

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(values: [String: String] = [:], query: [String: String] = [:]) {
        self.values = values
        self.query = query
    }

    /// The parameter `name` of the path, else of the query.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public subscript(name: String) -> String? {
        values[name] ?? query[name]
    }

    /// The parameter `name` as a `T` — an `Int`, a `UUID`, any type made from its text.
    ///
    ///     .product(id: try $0.value("id"))
    ///
    /// Ownership: returns a value. Isolation: none. Errors: `RouteError` when the URL has no
    /// such parameter, or one that is not a `T`. Cancellation: not applicable.
    public func value<T: LosslessStringConvertible>(_ name: String, as type: T.Type = T.self)
        throws -> T
    {
        guard let text = self[name] else { throw RouteError.missingParameter(name) }
        guard let value = T(text) else { throw RouteError.invalidParameter(name, text) }

        return value
    }
}

/// Why a URL has no path in a route table.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum RouteError: Error, Hashable, Sendable {
    /// No pattern takes the whole path.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case unknownPath(String)
    /// A route asked for a parameter the URL does not have.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case missingParameter(String)
    /// A parameter's text is not what the route takes: its name and its text.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case invalidParameter(String, String)
}

/// A URL path that stands for a route, as on a web server: `/catalog/:category/:id`.
/// A segment `:name` takes any one segment, `*name` the rest of the path; the others are
/// taken as they are.
///
/// A route without values stands for its path alone:
///
///     RoutePattern("/catalog", .catalog)
///
/// A route with values makes the route from the URL's values, and gives them back for a
/// URL of the route (`nil` for a route it does not stand for):
///
///     RoutePattern(
///         "/catalog/:category/:id",
///         route: { .product(id: try $0.value("id")) },
///         values: { route in
///             guard case .product(let id) = route else { return nil }
///             return ["id": String(id)]
///         }
///     )
///
/// A value a route leaves out — the category of a product — comes from the routes under it
/// in the path.
///
/// Ownership: keeps its closures. Isolation: none: the closures are `Sendable` and run
/// where the table is used. Errors: none. Cancellation: not applicable.
public struct RoutePattern<Route: Hashable & Sendable>: Sendable {
    enum Segment: Hashable, Sendable {
        case literal(String)
        case parameter(String)
        case rest(String)
    }

    let template: String
    let segments: [Segment]
    let make: @Sendable (RouteParameters) throws -> Route
    let values: @Sendable (Route) -> [String: String]?

    /// The pattern `template` standing for `route`, which has no values.
    ///
    /// Ownership: keeps `route`. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(_ template: String, _ route: Route) {
        self.init(template, route: { _ in route }, values: { $0 == route ? [:] : nil })
    }

    /// The pattern `template`: `route` makes the route from a URL's values, `values` gives
    /// back the values of a route it stands for, and `nil` for any other.
    ///
    /// Ownership: keeps the closures. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        _ template: String,
        route: @escaping @Sendable (RouteParameters) throws -> Route,
        values: @escaping @Sendable (Route) -> [String: String]?
    ) {
        self.template = template
        segments = RoutePattern.split(template).map { part in
            if part.hasPrefix(":") { return .parameter(String(part.dropFirst())) }
            if part.hasPrefix("*") { return .rest(String(part.dropFirst())) }
            return .literal(part)
        }
        make = route
        self.values = values
    }

    /// The segments of a path, without empty ones.
    static func split(_ path: String) -> [String] {
        path.split(separator: "/" as Character).map(String.init)
    }

    /// The values of `path` when the pattern takes all of it, else `nil`.
    func match(_ path: ArraySlice<String>) -> [String: String]? {
        var values: [String: String] = [:]
        var index = path.startIndex
        for segment in segments {
            switch segment {
            case .rest(let name):
                guard index < path.endIndex else { return nil }

                values[name] = path[index...].joined(separator: "/")
                return values
            case .literal(let text):
                guard index < path.endIndex, path[index] == text else { return nil }
            case .parameter(let name):
                guard index < path.endIndex else { return nil }

                values[name] = path[index]
            }
            index += 1
        }
        return index == path.endIndex ? values : nil
    }

    /// Whether the pattern ends with `*rest`.
    var takesRest: Bool {
        if case .rest = segments.last { return true }
        return false
    }

    /// How much the pattern names by itself: a literal segment goes before a parameter.
    var specificity: Int {
        segments.reduce(0) { total, segment in
            switch segment {
            case .literal: total + 2
            case .parameter: total + 1
            case .rest: total
            }
        }
    }

    /// The path of the pattern with `values` put in, or `nil` when one is missing.
    func fill(_ values: [String: String]) -> String? {
        var parts: [String] = []
        for segment in segments {
            switch segment {
            case .literal(let text):
                parts.append(RoutePattern.encode(text))
            case .parameter(let name):
                guard let value = values[name] else { return nil }

                parts.append(RoutePattern.encode(value))
            case .rest(let name):
                guard let value = values[name] else { return nil }

                parts.append(contentsOf: RoutePattern.split(value).map(RoutePattern.encode))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// URLs for a stack's paths, and paths for URLs, as the routes of a web server:
///
///     let routes = RouteTable<ShopRoute> {
///         RoutePattern("/catalog", .catalog)
///         RoutePattern("/catalog/:category", route: { ... }, values: { ... })
///         RoutePattern("/catalog/:category/:id", route: { ... }, values: { ... })
///     }
///     stack.setPath(try routes.path(for: "/catalog/shoes/42"))   // three screens
///     routes.url(for: stack.path)                                // "/catalog/shoes/42"
///
/// A URL stands for a whole path: each beginning of it that a pattern takes is a screen,
/// the shortest first — `/catalog`, `/catalog/shoes`, `/catalog/shoes/42`. A beginning no
/// pattern takes has no screen of its own, and a `*rest` pattern takes only the whole URL. The whole URL must be taken. Of the patterns
/// taking the same segments, the one naming more of them itself wins (`/catalog/new` over
/// `/catalog/:category`), then the first declared.
///
/// For deep links, universal links, restoring a stack and sharing a screen: a path read
/// from its URL is its URL's path — a screen opened another way is shown in its own path.
///
/// Ownership: keeps its patterns. Isolation: none: a table is a value, to keep in a
/// constant. Errors: `path(for:)` throws `RouteError`. Cancellation: not applicable.
public struct RouteTable<Route: Hashable & Sendable>: Sendable {
    let patterns: [RoutePattern<Route>]

    /// Ownership: keeps the patterns. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(_ patterns: [RoutePattern<Route>]) {
        self.patterns = patterns
    }

    /// Ownership: keeps the patterns. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(@RouteTableBuilder<Route> _ patterns: () -> [RoutePattern<Route>]) {
        self.init(patterns())
    }

    /// The path `url` stands for: a route for each beginning of its path a pattern takes.
    /// Only the path and the query count; a scheme and a host are the app's to check.
    ///
    /// Ownership: returns values. Isolation: runs the patterns' closures. Errors:
    /// `RouteError.unknownPath` when no pattern takes the whole path, and what a route's
    /// closure throws. Cancellation: not applicable.
    public func path(for url: URL) throws -> [Route] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return try path(segments: components?.percentEncodedPath ?? url.path, query: query)
    }

    /// The path `url` stands for, a URL's path with its query: `/catalog/shoes?sort=price`.
    ///
    /// Ownership: returns values. Isolation: runs the patterns' closures. Errors: see
    /// `path(for: URL)`. Cancellation: not applicable.
    public func path(for url: String) throws -> [Route] {
        guard let parsed = URL(string: url) else { throw RouteError.unknownPath(url) }

        return try path(for: parsed)
    }

    private func path(segments encodedPath: String, query: [String: String]) throws -> [Route] {
        let segments = RoutePattern<Route>.split(encodedPath).map {
            $0.removingPercentEncoding ?? $0
        }
        var routes: [Route] = []
        for count in 0...segments.count {
            let prefix = segments[..<count]
            guard let (pattern, values) = best(for: prefix, whole: count == segments.count) else {
                if count == segments.count {
                    throw RouteError.unknownPath("/" + segments.joined(separator: "/"))
                }
                continue
            }

            routes.append(try pattern.make(RouteParameters(values: values, query: query)))
        }
        return routes
    }

    /// The pattern taking `path` that names most of it. A `*rest` pattern takes only the
    /// whole URL: its beginnings are not screens of their own.
    private func best(for path: ArraySlice<String>, whole: Bool) -> (
        RoutePattern<Route>, [String: String]
    )? {
        var best: (pattern: RoutePattern<Route>, values: [String: String])?
        for pattern in patterns where whole || !pattern.takesRest {
            guard let values = pattern.match(path) else { continue }

            if best == nil || pattern.specificity > best!.pattern.specificity {
                best = (pattern, values)
            }
        }
        return best
    }

    /// The URL's path for `path`: the pattern of its last route, with the values of all its
    /// routes — the nearest to the top first. `nil` when a pattern stands for no route of it,
    /// or a value is missing.
    ///
    /// Ownership: returns a value. Isolation: runs the patterns' closures. Errors: none.
    /// Cancellation: not applicable.
    public func url(for path: [Route]) -> String? {
        guard let last = path.last, let (pattern, _) = standing(for: last) else { return nil }

        var values: [String: String] = [:]
        for route in path {
            guard let (_, own) = standing(for: route) else { continue }

            values.merge(own) { _, newer in newer }
        }
        return pattern.fill(values)
    }

    /// The URL's path for `route` alone.
    ///
    /// Ownership: returns a value. Isolation: runs the patterns' closures. Errors: none.
    /// Cancellation: not applicable.
    public func url(for route: Route) -> String? {
        url(for: [route])
    }

    private func standing(for route: Route) -> (RoutePattern<Route>, [String: String])? {
        for pattern in patterns {
            if let values = pattern.values(route) {
                return (pattern, values)
            }
        }
        return nil
    }
}

/// Builds the patterns of a `RouteTable`.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
@resultBuilder
public enum RouteTableBuilder<Route: Hashable & Sendable> {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ pattern: RoutePattern<Route>) -> [RoutePattern<Route>] {
        [pattern]
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildBlock(_ parts: [RoutePattern<Route>]...) -> [RoutePattern<Route>] {
        parts.flatMap { $0 }
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildOptional(_ part: [RoutePattern<Route>]?) -> [RoutePattern<Route>] {
        part ?? []
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildEither(first part: [RoutePattern<Route>]) -> [RoutePattern<Route>] {
        part
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildEither(second part: [RoutePattern<Route>]) -> [RoutePattern<Route>] {
        part
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildArray(_ parts: [[RoutePattern<Route>]]) -> [RoutePattern<Route>] {
        parts.flatMap { $0 }
    }
}
