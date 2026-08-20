struct StartFreshConfirmationState {
    static let title = "Start Fresh?"
    static let warning = "Starting fresh creates a new encryption key. You may lose access to existing cloud data."

    private(set) var isPresented = false
    private var isAwaitingDecision = false

    mutating func request() {
        isPresented = true
        isAwaitingDecision = true
    }

    mutating func dismissPresentation() {
        isPresented = false
    }

    mutating func cancel() {
        isPresented = false
        isAwaitingDecision = false
    }

    mutating func confirm(perform action: () -> Void) {
        guard isAwaitingDecision else { return }
        isPresented = false
        isAwaitingDecision = false
        action()
    }
}
