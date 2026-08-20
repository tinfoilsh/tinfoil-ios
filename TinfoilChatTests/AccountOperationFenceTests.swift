import Testing
@testable import TinfoilChat

struct AccountOperationFenceTests {
    @Test func newlyBegunTokenIsCurrent() {
        var fence = AccountOperationFence()
        let token = fence.begin(userId: "user-a")

        #expect(fence.isCurrent(token, currentUserId: "user-a"))
    }

    @Test func newerBeginInvalidatesOlderToken() {
        var fence = AccountOperationFence()
        let olderToken = fence.begin(userId: "user-a")
        let newerToken = fence.begin(userId: "user-a")

        #expect(!fence.isCurrent(olderToken, currentUserId: "user-a"))
        #expect(fence.isCurrent(newerToken, currentUserId: "user-a"))
    }

    @Test func invalidateInvalidatesCurrentToken() {
        var fence = AccountOperationFence()
        let token = fence.begin(userId: "user-a")

        fence.invalidate()

        #expect(!fence.isCurrent(token, currentUserId: "user-a"))
    }

    @Test func matchingGenerationForWrongUserIsRejected() {
        var fence = AccountOperationFence()
        let token = fence.begin(userId: "user-a")
        let wrongUserToken = AccountOperationFence.Token(
            userId: "user-b",
            generation: token.generation
        )

        #expect(!fence.isCurrent(wrongUserToken, currentUserId: "user-a"))
        #expect(!fence.isCurrent(token, currentUserId: "user-b"))
    }

    @Test func generationsIncreaseMonotonically() {
        var fence = AccountOperationFence()
        let first = fence.begin(userId: "user-a")
        let second = fence.begin(userId: "user-a")
        fence.invalidate()
        let third = fence.begin(userId: "user-a")

        #expect(first.generation < second.generation)
        #expect(second.generation < third.generation)
    }
}

struct PasskeyAccountOperationStateTests {
    @Test func destructiveResetAcceptsTheNextValidatedOwner() {
        let state = PasskeyAccountOperationState.reset

        #expect(state.canResume(validatedOwnerUserId: "user-a"))
        #expect(state.canResume(validatedOwnerUserId: "user-b"))
    }

    @Test func passivePauseAcceptsOnlyItsOwner() {
        let state = PasskeyAccountOperationState.paused(ownerUserId: "user-a")

        #expect(state.canResume(validatedOwnerUserId: "user-a"))
        #expect(!state.canResume(validatedOwnerUserId: "user-b"))
    }

    @Test func ownerlessPassivePauseStaysClosed() {
        let state = PasskeyAccountOperationState.paused(ownerUserId: nil)

        #expect(!state.canResume(validatedOwnerUserId: "user-a"))
    }
}

@MainActor
struct AccountOperationTrackerTests {
    @Test func beginAndEndCompleteAnOperation() async {
        let tracker = AccountOperationTracker()
        let operationTask = Task {}

        let token = tracker.begin(task: operationTask)
        #expect(token != nil)
        if let token {
            tracker.end(token)
        }
        await tracker.closeAndWait()

        #expect(tracker.begin(task: Task {}) == nil)
    }

    @Test func closeRejectsNewOperations() async {
        let tracker = AccountOperationTracker()

        await tracker.closeAndWait()

        #expect(tracker.begin(task: Task {}) == nil)
    }

    @Test func closeCancelsAndWaitsForActiveOperation() async {
        let tracker = AccountOperationTracker()
        let operationTask = Task {}
        let token = tracker.begin(task: operationTask)
        #expect(token != nil)
        var closeFinished = false
        var closeTask: Task<Void, Never>!

        await withCheckedContinuation { (closeStarted: CheckedContinuation<Void, Never>) in
            closeTask = Task { @MainActor in
                closeStarted.resume()
                await tracker.closeAndWait()
                closeFinished = true
            }
        }

        #expect(operationTask.isCancelled)
        #expect(!closeFinished)

        if let token {
            tracker.end(token)
        }
        await closeTask.value

        #expect(closeFinished)
    }

    @Test func operationTokensEndOnlyTheirOwnRegistration() async {
        let tracker = AccountOperationTracker()
        let firstToken = tracker.begin(task: Task {})
        let secondToken = tracker.begin(task: Task {})

        #expect(firstToken != nil)
        #expect(secondToken != nil)
        #expect(firstToken != secondToken)

        if let firstToken {
            tracker.end(firstToken)
        }

        var closeFinished = false
        var closeTask: Task<Void, Never>!
        await withCheckedContinuation { (closeStarted: CheckedContinuation<Void, Never>) in
            closeTask = Task { @MainActor in
                closeStarted.resume()
                await tracker.closeAndWait()
                closeFinished = true
            }
        }
        #expect(!closeFinished)

        if let secondToken {
            tracker.end(secondToken)
        }
        await closeTask.value
        #expect(closeFinished)
    }

    @Test func reopenPermitsNewOperations() async {
        let tracker = AccountOperationTracker()
        await tracker.closeAndWait()

        tracker.reopen()

        let token = tracker.begin(task: Task {})
        #expect(token != nil)
        if let token {
            tracker.end(token)
        }
    }
}
