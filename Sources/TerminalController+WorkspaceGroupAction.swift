import CmuxCore
import Foundation
import CmuxWorkspaces

extension TerminalController {
    private func mobileWorkspaceGroupAction(params: [String: Any]) -> MobileWorkspaceGroupAction? {
        guard let rawAction = v2RawString(params, "action")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_"),
            !rawAction.isEmpty else {
            return nil
        }
        return MobileWorkspaceGroupAction(rawValue: rawAction)
    }

    private func mobileWorkspaceGroupActionTitle(
        params: [String: Any],
        action: MobileWorkspaceGroupAction
    ) -> String? {
        guard action == .rename else { return nil }
        guard let trimmed = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Parses the shared caller-owned identity accepted by mobile and control
    /// workspace-group creation. The control-socket path supplies localized
    /// errors; this mobile path is only reached after authenticated RPC gating.
    private func mobileWorkspaceGroupExternalID(
        params: [String: Any]
    ) -> (value: String?, error: V2CallResult?) {
        do {
            let resolution = try WorkspaceGroupIdentityResolution(
                externalID: mobileWorkspaceGroupIdentityInput(params["external_id"]),
                idempotencyKey: mobileWorkspaceGroupIdentityInput(params["idempotency_key"])
            )
            return (resolution.value, nil)
        } catch let error as WorkspaceGroupIdentityResolution.ValidationError {
            let message: String
            switch error {
            case .nonString:
                message = String(
                    localized: "workspaceGroup.error.idempotencyKeyMustBeString",
                    defaultValue: "external_id and idempotency_key must be strings"
                )
            case .empty:
                message = String(
                    localized: "workspaceGroup.error.idempotencyKeyMustNotBeEmpty",
                    defaultValue: "The group identity must not be empty"
                )
            case .mismatchedAliases:
                message = String(
                    localized: "workspaceGroup.error.idempotencyKeysMustMatch",
                    defaultValue: "external_id and idempotency_key must match"
                )
            }
            return (nil, .err(
                code: "invalid_params",
                message: message,
                data: nil
            ))
        } catch {
            assertionFailure("Unexpected workspace-group identity validation error: \(error)")
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "workspaceGroup.error.idempotencyKeyMustBeString",
                    defaultValue: "external_id and idempotency_key must be strings"
                ),
                data: nil
            ))
        }
    }

    private func mobileWorkspaceGroupIdentityInput(
        _ value: Any?
    ) -> WorkspaceGroupIdentityResolution.Input {
        guard let value, !(value is NSNull) else { return .absent }
        guard let raw = value as? String else { return .invalid }
        return .string(raw)
    }
}

private enum MobileWorkspaceGroupAction: String {
    case pin
    case unpin
    case rename
    case ungroup
    case delete
}
