import Foundation

/// Locale-aware natural ordering used by every loader/enumerator that
/// presents files to the user. Centralised so a change here ("12.jpg"
/// before "9.jpg"? case-insensitive accent strip?) ripples to all
/// listings instead of drifting per call site.
nonisolated enum NaturalSort {
    /// True iff `a` should come before `b`.
    static func compare(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    static func byFilename(_ a: URL, _ b: URL) -> Bool {
        compare(a.lastPathComponent, b.lastPathComponent)
    }
}
