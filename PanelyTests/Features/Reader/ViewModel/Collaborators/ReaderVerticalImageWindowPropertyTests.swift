import Testing
import Foundation
@testable import Panely

/// Property checks for `ReaderVerticalImageWindow.evictionIndices` over many
/// seeded random strips. The example tests in
/// `ReaderImageLoadingSupportTests` pin specific answers; these pin the rules
/// every answer must satisfy, whatever the strip:
///
/// 1. only loaded pages are evicted, each once, in ascending order;
/// 2. every loaded page outside the keep range is evicted;
/// 3. a visible page or its `visibleRangeBuffer` neighbour never is;
/// 4. what stays fits the budget — unless only protected pages are left;
/// 5. inside the keep range, the farthest pages go first;
/// 6. no more is evicted than needed to get under budget.
struct ReaderVerticalImageWindowPropertyTests {
    @Test func evictionRulesHoldForRandomStrips() {
        var rng = SplitMix64(seed: 0x5EED_CAFE)
        for caseIndex in 0..<2_000 {
            let strip = RandomStrip(using: &rng)
            let window = ReaderVerticalImageWindow(pageCount: strip.pageCount)
            let evicted = window.evictionIndices(
                forVisibleRange: strip.visible,
                loaded: strip.loaded,
                loadedImageCount: strip.pageCount,
                byteBudget: strip.budget,
                cost: { strip.costs[$0] }
            )
            let failures = Self.violations(of: evicted, for: strip, window: window)
            if !failures.isEmpty {
                Issue.record("case \(caseIndex) \(strip): \(failures.joined(separator: "; "))")
                return
            }
        }
    }

    /// An empty visible range (the viewer between layouts) evicts nothing,
    /// however far over budget.
    @Test func emptyVisibleRangeEvictsNothing() {
        let window = ReaderVerticalImageWindow(pageCount: 50)
        let evicted = window.evictionIndices(
            forVisibleRange: 10..<10,
            loaded: Set(0..<50),
            loadedImageCount: 50,
            byteBudget: 0,
            cost: { _ in 1_000 }
        )
        #expect(evicted.isEmpty)
    }

    static func violations(of evicted: [Int], for strip: RandomStrip, window: ReaderVerticalImageWindow) -> [String] {
        var failures: [String] = []
        let evictedSet = Set(evicted)
        let keep = window.keepRange(forVisibleRange: strip.visible, loadedImageCount: strip.pageCount)
        let buffer = ReaderImageLoadingPolicy.visibleRangeBuffer
        let protected = (strip.visible.lowerBound - buffer)..<(strip.visible.upperBound + buffer)
        func distance(_ i: Int) -> Int {
            i < strip.visible.lowerBound ? strip.visible.lowerBound - i : i - (strip.visible.upperBound - 1)
        }

        // 1
        if evicted != evictedSet.sorted() { failures.append("not unique ascending: \(evicted)") }
        if !evictedSet.isSubset(of: strip.loaded) { failures.append("evicted unloaded \(evictedSet.subtracting(strip.loaded).sorted())") }
        // 2
        let outside = strip.loaded.filter { !keep.contains($0) }
        if !outside.isSubset(of: evictedSet) { failures.append("kept outside keep range \(outside.subtracting(evictedSet).sorted())") }
        // 3
        let protectedEvicted = evictedSet.filter { protected.contains($0) }
        if !protectedEvicted.isEmpty { failures.append("evicted protected \(protectedEvicted.sorted())") }

        let remaining = strip.loaded.subtracting(evictedSet)
        let remainingCost = remaining.reduce(0) { $0 + strip.costs[$1] }
        let unprotectedRemaining = remaining.filter { !protected.contains($0) }
        // 4
        if remainingCost > strip.budget && !unprotectedRemaining.isEmpty {
            failures.append("over budget (\(remainingCost) > \(strip.budget)) with evictable \(unprotectedRemaining.sorted())")
        }
        // 5
        let budgetEvicted = evictedSet.filter { keep.contains($0) }
        if let nearestEvicted = budgetEvicted.map(distance).min(),
           let farthestKept = unprotectedRemaining.map(distance).max(),
           farthestKept > nearestEvicted {
            failures.append("kept a page at distance \(farthestKept) but evicted one at \(nearestEvicted)")
        }
        // 6: putting back the last (nearest) budget eviction must break the budget.
        if let last = budgetEvicted.min(by: { (distance($0), $0) < (distance($1), $1) }),
           remainingCost + strip.costs[last] <= strip.budget {
            failures.append("over-evicted: \(last) would still fit")
        }
        return failures
    }
}

/// One random scenario: a strip, a visible range in it, a loaded set
/// clustered around (and sometimes far from) the viewport, per-page costs,
/// and a budget anywhere from zero to everything.
struct RandomStrip: CustomStringConvertible {
    let pageCount: Int
    let visible: Range<Int>
    let loaded: Set<Int>
    let costs: [Int]
    let budget: Int

    init(using rng: inout SplitMix64) {
        pageCount = Int.random(in: 1...300, using: &rng)
        let start = Int.random(in: 0..<pageCount, using: &rng)
        let length = Int.random(in: 1...min(6, pageCount - start), using: &rng)
        visible = start..<(start + length)

        var loaded: Set<Int> = []
        let spread = Int.random(in: 0...40, using: &rng)
        for i in max(0, start - spread)..<min(pageCount, start + length + spread)
        where Int.random(in: 0..<4, using: &rng) != 0 {
            loaded.insert(i)
        }
        for _ in 0..<Int.random(in: 0...5, using: &rng) {
            loaded.insert(Int.random(in: 0..<pageCount, using: &rng))
        }
        self.loaded = loaded

        // Mostly varied sizes; sometimes uniform (ties) or with free pages.
        let mode = Int.random(in: 0..<3, using: &rng)
        let costs: [Int] = (0..<pageCount).map { _ in
            switch mode {
            case 0: return 100
            case 1: return Int.random(in: 0...3, using: &rng) * 50
            default: return Int.random(in: 1...10_000, using: &rng)
            }
        }
        self.costs = costs
        let total = loaded.reduce(0) { $0 + costs[$1] }
        budget = Int.random(in: 0...max(0, total), using: &rng)
    }

    var description: String {
        "pages=\(pageCount) visible=\(visible) loaded=\(loaded.sorted()) budget=\(budget)"
    }
}

/// Small seeded generator so the random cases are the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
