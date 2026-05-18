import Foundation

nonisolated enum FitMode: String, CaseIterable, Sendable {
    case fitScreen
    case fitWidth
    case fitHeight

    var next: FitMode {
        switch self {
        case .fitScreen: return .fitWidth
        case .fitWidth:  return .fitHeight
        case .fitHeight: return .fitScreen
        }
    }
}
