import Foundation

/// Selects where a saved resume command is allowed to execute.
enum SurfaceResumeLaunchFlavor: Equatable, Hashable, Sendable {
    case local

    var executionLocationRawValue: String {
        switch self {
        case .local:
            return "local"
        }
    }
}

extension SurfaceResumeLaunchFlavor: Codable {
    init(from decoder: Decoder) throws {
        self = .local
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("local")
    }
}
