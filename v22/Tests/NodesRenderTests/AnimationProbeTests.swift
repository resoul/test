#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    @testable import NodesRender
    import QuartzCore
    import Testing

    // Temporary: finds out which animations Core Animation keeps on layers outside a window.
    // Prints one line per case and records nothing.

    @MainActor
    private func probe(
        _ name: String,
        key: String,
        disableActions: Bool = true,
        reinsert: Bool = false,
        change: (CALayer) -> Void,
        animation: () -> CAAnimation
    ) -> String {
        let container = CALayer()
        let layer = CALayer()
        container.addSublayer(layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 20, y: 0, width: 10, height: 10)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(disableActions)
        change(layer)
        if reinsert {
            layer.removeFromSuperlayer()
        }
        layer.add(animation(), forKey: key)
        if reinsert {
            container.insertSublayer(layer, at: 0)
        }
        let before = layer.animationKeys() ?? []
        CATransaction.commit()
        let after = layer.animationKeys() ?? []
        let begin = layer.animation(forKey: key)?.beginTime ?? -1
        return "\(name): before=\(before) after=\(after) begin=\(begin) now=\(CACurrentMediaTime())"
    }

    @MainActor
    private func basic(_ key: String, _ from: Any, _ to: Any, timing: Bool = true) -> CAAnimation {
        let animation = CABasicAnimation(keyPath: key)
        if timing {
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 0.25
        return animation
    }

    @Test @MainActor
    func animationProbe() {
        let moved = CGRect(x: 60, y: 0, width: 10, height: 10)
        var lines = [
            probe("position", key: "position", change: { $0.frame = moved }) {
                basic("position", CGPoint(x: 25, y: 5), CGPoint(x: 65, y: 5))
            },
            probe("position-no-timing", key: "position", change: { $0.frame = moved }) {
                basic("position", CGPoint(x: 25, y: 5), CGPoint(x: 65, y: 5), timing: false)
            },
            probe("position-actions-on", key: "position", disableActions: false, change: { $0.frame = moved }) {
                basic("position", CGPoint(x: 25, y: 5), CGPoint(x: 65, y: 5))
            },
            probe("position-no-model-change", key: "position", change: { _ in }) {
                basic("position", CGPoint(x: 25, y: 5), CGPoint(x: 65, y: 5))
            },
            probe("position-spring", key: "position", change: { $0.frame = moved }) {
                let spring = CASpringAnimation(keyPath: "position")
                spring.fromValue = CGPoint(x: 25, y: 5)
                spring.toValue = CGPoint(x: 65, y: 5)
                spring.duration = 0.63
                return spring
            },
            probe("position-long", key: "position", change: { $0.frame = moved }) {
                let animation = basic("position", CGPoint(x: 25, y: 5), CGPoint(x: 65, y: 5))
                animation.duration = 0.63
                return animation
            },
            probe("opacity", key: "opacity", change: { $0.opacity = 0 }) {
                basic("opacity", Float(1), Float(0))
            },
            probe("opacity-reinsert", key: "opacity", reinsert: true, change: { $0.opacity = 0 }) {
                basic("opacity", Float(1), Float(0))
            },
            probe(
                "background",
                key: "backgroundColor",
                change: { $0.backgroundColor = CGColor(red: 0, green: 0, blue: 1, alpha: 1) }
            ) {
                basic(
                    "backgroundColor",
                    CGColor(red: 0, green: 0, blue: 1, alpha: 0),
                    CGColor(red: 0, green: 0, blue: 1, alpha: 1)
                )
            },
        ]
        lines.append("from value type: \(type(of: (basic("position", CGPoint.zero, CGPoint.zero) as! CABasicAnimation).fromValue!))")
        print("PROBE\n" + lines.joined(separator: "\n"))
    }
#endif

#if canImport(QuartzCore)
    @MainActor
    private final class ProbeDot: Node {
        var width: Double {
            didSet { setNeedsLayout() }
        }

        init(width: Double) {
            self.width = width
        }

        override var layoutContent: LeafContent? {
            .size(LayoutSize(width: width, height: 10))
        }
    }

    @MainActor
    private final class ProbeRow: Node {
        let spacer = ProbeDot(width: 20)
        let dot = ProbeDot(width: 10)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { spacer; dot }
                .alignItems(.start)
        }
    }

    @Test @MainActor
    func rendererProbe() {
        let row = ProbeRow()
        let host = NodeHost(root: row, size: LayoutSize(width: 200, height: 50))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        renderer.trace = []
        let container = CALayer()
        renderer.render(row, in: container)
        host.didRender()

        row.spacer.width = 60
        host.layoutIfNeeded()
        renderer.render(row, in: container, animation: .default)
        let dot = renderer.layer(for: row.dot)
        renderer.trace?.append("after commit dot \(dot.map { Unmanaged.passUnretained($0).toOpaque() }.debugDescription) \(dot?.animationKeys() ?? [])")

        row.spacer.width = 100
        host.layoutIfNeeded()
        CATransaction.begin()
        renderer.render(row, in: container, animation: .default)
        renderer.trace?.append("inside outer transaction \(dot?.animationKeys() ?? [])")
        CATransaction.commit()
        renderer.trace?.append("after outer commit \(dot?.animationKeys() ?? [])")
        print("RENDERER PROBE\n" + (renderer.trace ?? []).joined(separator: "\n"))
        host.detach()
    }
#endif
