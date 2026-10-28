// Command execution policy shared by palette selection and focus restoration.
extension ContentView {
    static func commandPaletteShouldDismissBeforeRun(forCommandId commandId: String) -> Bool {
        switch commandId {
        default:
            return false
        }
    }
}
