/// An `Arrangement` with one or more modifier deltas layered on top (C22).
///
/// Ownership: borrows whatever the wrapped arrangement borrows. Isolation: MainActor. Errors:
/// none. Cancellation: not applicable.
public struct ModifiedArrangement: Arrangement {
    package let descriptor: ArrangementDescriptor

    fileprivate init(descriptor: ArrangementDescriptor) {
        self.descriptor = descriptor
    }
}

extension Arrangement {
    /// Sets this item's flex-grow factor for a future resolver to apply (C23) — last write
    /// wins when chained more than once.
    ///
    /// Ownership: returns a value; this arrangement's own borrows are unaffected. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public func grow(_ value: Double) -> ModifiedArrangement {
        modified(ArrangementModifiers(grow: value))
    }

    /// Sets this item's preferred width and/or height for a future resolver to apply (C23).
    /// Passing `nil` for a dimension leaves that dimension's prior modifier (if any) alone —
    /// it does not clear it.
    ///
    /// Ownership: returns a value; this arrangement's own borrows are unaffected. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public func size(width: SizeValue? = nil, height: SizeValue? = nil) -> ModifiedArrangement {
        modified(ArrangementModifiers(width: width, height: height))
    }

    /// Sets this item's cross-axis self-alignment override for a future resolver to apply
    /// (C23).
    ///
    /// Ownership: returns a value; this arrangement's own borrows are unaffected. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public func align(_ value: AlignSelf) -> ModifiedArrangement {
        modified(ArrangementModifiers(alignSelf: value))
    }

    /// Sets this item's margin for a future resolver to apply (C23).
    ///
    /// Ownership: returns a value; this arrangement's own borrows are unaffected. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public func margin(_ insets: DirectionalEdgeInsets) -> ModifiedArrangement {
        modified(ArrangementModifiers(margin: insets))
    }

    /// Sets this item's absolute-position offsets for a future resolver to apply (C23) —
    /// meaningful for an `Overlay` item; a relatively positioned item ignores it (C21).
    ///
    /// Ownership: returns a value; this arrangement's own borrows are unaffected. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public func offset(_ offsets: DirectionalEdgeOffsets) -> ModifiedArrangement {
        modified(ArrangementModifiers(offset: offsets))
    }

    private func modified(_ delta: ArrangementModifiers) -> ModifiedArrangement {
        var descriptor = lower(self)
        descriptor.modifiers.merge(overriding: delta)
        return ModifiedArrangement(descriptor: descriptor)
    }
}
