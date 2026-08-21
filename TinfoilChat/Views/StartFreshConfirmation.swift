enum StartFreshConfirmation {
    static let title = "Start Fresh?"
    static let warning = "Starting fresh creates a new encryption key. You may lose access to existing cloud data."

    static func isRequired(for mode: CloudSyncOnboardingMode) -> Bool {
        mode == .recovery
    }
}
