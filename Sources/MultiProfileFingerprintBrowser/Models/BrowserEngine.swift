import Foundation

/// Identifies the underlying browser engine for a profile.
///
/// Currently only `.camoufox` (Firefox-based) is implemented.
/// `.chromiumCDP` is reserved for future use — see
/// `docs/chromium-cdp-engine-evaluation.md` for the evaluation.
enum BrowserEngine: String, Codable, CaseIterable {
    /// Camoufox (Firefox fork). Default engine. Uses Marionette for automation.
    case camoufox
    /// Chromium-based browser via Chrome DevTools Protocol.
    /// Reserved — not yet implemented.
    case chromiumCDP

    var displayName: String {
        switch self {
        case .camoufox:
            return "Camoufox (Firefox)"
        case .chromiumCDP:
            return "Chromium (CDP)"
        }
    }

    /// Whether this engine is currently available for use.
    var isAvailable: Bool {
        switch self {
        case .camoufox:
            return true
        case .chromiumCDP:
            return false  // Phase E
        }
    }
}
