import Foundation

nonisolated enum ReadingDirection: String, CaseIterable, Sendable {
    case leftToRight
    case rightToLeft

    var isRTL: Bool { self == .rightToLeft }
}
