import Foundation

nonisolated enum PageLayout: String, CaseIterable, Sendable {
    case single
    case double
    case vertical

    var next: PageLayout {
        switch self {
        case .single:   return .double
        case .double:   return .vertical
        case .vertical: return .single
        }
    }

    var navigationStep: Int {
        switch self {
        case .single, .vertical: return 1
        case .double:            return 2
        }
    }

    var isContinuous: Bool {
        self == .vertical
    }
}
