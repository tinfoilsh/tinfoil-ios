enum AccountActionReadiness {
    static func canPerform(isTearingDown: Bool, isAuthenticated: Bool, userId: String?, readyUserId: String?) -> Bool {
        guard !isTearingDown else { return false }
        guard isAuthenticated else { return true }
        guard let userId else { return false }
        return readyUserId == userId
    }
}
