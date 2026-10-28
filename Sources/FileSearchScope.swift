import Foundation

/// The filesystem scope used by the Files and Find right-sidebar tools.
enum FileSearchScope: Equatable, Sendable {
    case unsupported
    case local

    var debugName: String {
        switch self {
        case .unsupported: return "unsupported"
        case .local: return "local"
        }
    }
}
