/// What to report about one `LayoutSpec.apply`: where the report goes, which host it names
/// and what the engine traces.
///
/// Ownership: value type; keeps the handler and the traced elements for the call.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public struct LayoutSpecReporting {
    /// The name lines give the host — the view that applies the spec.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var host: String
    /// What the engine records for the report: nothing when empty.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var traceAreas: Set<LayoutTraceArea>
    /// The elements traced, with the containers of their layouts; `nil` traces every one.
    ///
    /// Ownership: borrows the elements. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public var tracedElements: [any LayoutElement]?
    /// Receives the report after the pass.
    ///
    /// Ownership: kept for the call. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var handler: @MainActor (LayoutSpecReport) -> Void

    /// Ownership: keeps the arguments. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(
        host: String,
        traceAreas: Set<LayoutTraceArea> = [],
        tracedElements: [any LayoutElement]? = nil,
        handler: @escaping @MainActor (LayoutSpecReport) -> Void
    ) {
        self.host = host
        self.traceAreas = traceAreas
        self.tracedElements = tracedElements
        self.handler = handler
    }

    /// The name of `object` for the `host` field: its type and its address, which tells two
    /// views of one type apart in an interleaved log.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func hostName(for object: AnyObject) -> String {
        let address = UInt(bitPattern: ObjectIdentifier(object).hashValue)
        return "\(type(of: object))@\(String(address, radix: 16))"
    }
}

/// What one `LayoutSpec.apply` found — the report `NodeHost` gives for a tree of nodes, for a
/// spec of views. Elements are named by their place in the spec and their type, `#3:UILabel`;
/// the container of an element's own layout adds `/container`.
///
/// Ownership: value type; borrows the elements it names. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public struct LayoutSpecReport {
    /// One thing the engine did.
    ///
    /// Ownership: value type; borrows the element. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public struct Trace {
        /// The element the event stands for: the element itself, or for a container of its
        /// layout, that element; `nil` for a container the spec itself describes.
        ///
        /// Ownership: borrowed. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public let element: (any LayoutElement)?
        /// Whether the event is about a container rather than an element.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public let isContainer: Bool
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public let event: LayoutTraceEvent
        let label: String
    }

    /// `LayoutSpecReporting.host`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let host: String
    /// The pass: it grows with every reported `apply` in the process.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let generation: UInt64
    /// Places in the spec that hold an element.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let elements: Int
    /// Time the engine took.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let duration: Duration
    /// Elements laid out in more than one place. An element has one frame, so such a pass
    /// is rejected: every element keeps the frame of the pass before.
    ///
    /// Ownership: borrowed. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let duplicates: [any LayoutElement]
    /// Whether the spec was too deep for the stack of the calling thread; the pass is then
    /// rejected. A spec of views is solved where it is applied, so it has no other thread to
    /// move to.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let isTooDeep: Bool
    /// Elements whose `Breakpoint` or `from:` values had no width to choose by, at least
    /// while being measured, and took the narrow side: their container sized itself to its
    /// content. A container the spec itself describes is not an element: it is only in
    /// `lines`, as `container`.
    ///
    /// Ownership: borrowed. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let variantsWithoutWidth: [any LayoutElement]
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let trace: [Trace]

    let duplicateLabels: [String]
    let widthlessLabels: [String]

    /// Whether the pass was rejected — for elements laid out twice or a spec too deep.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isRejected: Bool { isTooDeep || !duplicates.isEmpty }

    /// Whether the pass found something to fix in the spec.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var hasProblems: Bool { isRejected || !widthlessLabels.isEmpty }

    /// One line for the pass, then one per traced event, in the format of the node layer's
    /// report: every line names the host and the pass, every field is always there (`none`
    /// when empty).
    ///
    ///     [layout] pass host=ProfileView@6000 gen=4 elements=3 ms=0.2 rejected=yes stack=enough duplicates=#0:UILabel widthless=none
    ///     [layout] place host=ProfileView@6000 gen=4 #1:UIImageView x=16 y=16 size=48x48
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var lines: [String] {
        var lines = [
            "[layout] pass host=\(host) gen=\(generation) elements=\(elements) "
                + "ms=\(LayoutReportFormat.milliseconds(duration)) "
                + "rejected=\(isRejected ? "yes" : "no") "
                + "stack=\(isTooDeep ? "exhausted" : "enough") "
                + "duplicates=\(LayoutReportFormat.list(duplicateLabels)) "
                + "widthless=\(LayoutReportFormat.list(widthlessLabels))"
        ]
        for entry in trace {
            lines.append(
                LayoutReportFormat.line(
                    entry.event,
                    host: host,
                    generation: generation,
                    subject: entry.label
                )
            )
        }
        return lines
    }

    @MainActor static var passes: UInt64 = 0

    init(
        host: String,
        prepared: PreparedLayout,
        result: LayoutResult?,
        duration: Duration,
        duplicates: [any LayoutElement]
    ) {
        LayoutSpecReport.passes += 1
        func owner(_ id: LayoutID) -> Int? {
            prepared.isElement(id) ? Int(id.raw) : prepared.owners[id]
        }
        func label(_ index: Int?, container: Bool) -> String {
            guard let index else { return "container" }

            let element = prepared.elements[index].element
            return "#\(index):\(type(of: element))\(container ? "/container" : "")"
        }

        var widthless: [Int] = []
        var specContainers = false
        for id in result?.variantsWithoutWidth ?? [] {
            if let index = owner(id) {
                if !widthless.contains(index) { widthless.append(index) }
            } else {
                specContainers = true
            }
        }
        widthless.sort()
        let duplicateIndices = duplicates.compactMap { element in
            prepared.elements.firstIndex { $0.element === element }
        }

        self.host = host
        generation = LayoutSpecReport.passes
        elements = prepared.elementCount
        self.duration = duration
        self.duplicates = duplicates
        isTooDeep = result == nil
        variantsWithoutWidth = widthless.map { prepared.elements[$0].element }
        duplicateLabels = duplicateIndices.map { label($0, container: false) }
        widthlessLabels =
            widthless.map { label($0, container: false) } + (specContainers ? ["container"] : [])
        trace = (result?.trace ?? []).map { event in
            let index = owner(event.id)
            let isContainer = !prepared.isElement(event.id)
            return Trace(
                element: index.map { prepared.elements[$0].element },
                isContainer: isContainer,
                event: event,
                label: label(index, container: isContainer)
            )
        }
    }
}

/// The fields of `[layout]` lines shared by the reports of specs and of node trees.
///
/// Ownership: namespace. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LayoutReportFormat {
    /// A traced event as a line: `[layout] measure|place host=… gen=… <subject> …`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: none.
    public static func line(
        _ event: LayoutTraceEvent,
        host: String,
        generation: UInt64,
        subject: String
    ) -> String {
        switch event {
        case let .measured(_, width, height, size, cached):
            "[layout] measure host=\(host) gen=\(generation) \(subject) "
                + "width=\(space(width)) height=\(space(height)) "
                + "size=\(number(size.width))x\(number(size.height)) "
                + "cached=\(cached ? "yes" : "no")"
        case let .placed(_, frame):
            "[layout] place host=\(host) gen=\(generation) \(subject) "
                + "x=\(number(frame.origin.x)) y=\(number(frame.origin.y)) "
                + "size=\(number(frame.size.width))x\(number(frame.size.height))"
        }
    }

    /// A duration in milliseconds, up to three decimals.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: none.
    public static func milliseconds(_ duration: Duration) -> String {
        number(
            Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) / 1e15
        )
    }

    /// Items joined by commas, or `none`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: none.
    public static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: ",")
    }

    static func space(_ space: AvailableSpace) -> String {
        switch space {
        case let .definite(value): number(value)
        case .minContent: "min-content"
        case .maxContent: "max-content"
        }
    }

    /// Up to three decimals, without trailing zeros.
    static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
