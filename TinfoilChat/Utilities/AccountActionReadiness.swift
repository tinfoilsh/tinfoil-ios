enum AccountActionReadiness {
    static func canPerform(isAuthenticated: Bool, userId: String?, readyUserId: String?) -> Bool {
        guard isAuthenticated else { return true }
        guard let userId else { return false }
        return readyUserId == userId
    }
}
