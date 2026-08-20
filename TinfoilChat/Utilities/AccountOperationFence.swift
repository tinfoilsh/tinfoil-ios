import Foundation

struct AccountOperationFence {
    struct Token: Equatable, Sendable {
        let userId: String
        let generation: UInt64
    }

    private var generation: UInt64 = 0

    mutating func begin(userId: String) -> Token {
        generation += 1
        return Token(userId: userId, generation: generation)
    }

    mutating func invalidate() {
        generation += 1
    }

    func isCurrent(_ token: Token, currentUserId: String?) -> Bool {
        token.generation == generation && token.userId == currentUserId
    }
}

@MainActor
final class AccountOperationTracker {
    struct Token: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private final class Registration {
        var cancellation: (() -> Void)?

        init(cancellation: @escaping () -> Void) {
            self.cancellation = cancellation
        }
    }

    private(set) var isOpen = true
    private var nextOperationId: UInt64 = 0
    private var registrations: [Token: Registration] = [:]
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func begin<Success, Failure>(task: Task<Success, Failure>) -> Token?
    where Failure: Error {
        guard isOpen else { return nil }
        nextOperationId += 1
        let token = Token(id: nextOperationId)
        registrations[token] = Registration(cancellation: { task.cancel() })
        return token
    }

    func end(_ token: Token) {
        precondition(registrations.removeValue(forKey: token) != nil)
        guard registrations.isEmpty else { return }

        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func closeAndWait() async {
        isOpen = false
        let registrationsToCancel = registrations.values
        registrationsToCancel.forEach { registration in
            registration.cancellation?()
            registration.cancellation = nil
        }
        guard !registrations.isEmpty else { return }

        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    func reopen() {
        isOpen = true
    }
}
