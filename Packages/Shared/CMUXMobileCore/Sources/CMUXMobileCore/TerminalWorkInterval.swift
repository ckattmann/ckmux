import Foundation

/// Completion token for a measured terminal phase; recording is disabled in this build.
public struct TerminalWorkInterval: Sendable {
    init(log: DiagnosticLog, detail: TerminalWorkDiagnostic, startedAt: UInt64) {}

    public func end(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {}
}
