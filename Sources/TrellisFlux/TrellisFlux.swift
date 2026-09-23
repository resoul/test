// TrellisFlux (P6.1, plan 6, R02): the module-graph boundary between Trellis and the
// external Flux dependency. TrellisCore stays Foundation-only and TrellisRender's
// solver/raster paths gain no reactive runtime; only this target, and consumers who
// explicitly import it, depend on Flux. A consumer links `TrellisFlux` alongside a
// platform host module (TrellisUIKit/TrellisAppKit) to get both Trellis and Flux.
//
// Scope: this file only proves the dependency is real and usable end to end (a
// consumer can `import TrellisFlux` and drive a genuine `Flux`/`CurrentValue` from
// the pinned release). State delivery onto `StateSubject` (D14), effect/action
// ownership and animation intent are P6.2-P6.7 and land in R03/R04, not here.

@_exported import Flux
import TrellisCore
import TrellisRender

/// Identifies the module graph wired by R02.
///
/// Ownership: a value type, no ownership semantics. Isolation: none (all `let`).
/// Errors: none. Cancellation: not applicable.
public enum TrellisFlux {
    /// The exact Flux release this target is pinned against in `Package.swift`.
    /// Local development against an unreleased Flux checkout uses `swift package
    /// edit Flux --path ../old/flux` (README.md); this constant always names the
    /// published, reviewed pin, not whatever revision a developer has locally.
    ///
    /// Ownership: a value type, no ownership semantics. Isolation: none (a `let`).
    /// Errors: none. Cancellation: not applicable.
    public static let fluxVersion = "1.2.1"
}
