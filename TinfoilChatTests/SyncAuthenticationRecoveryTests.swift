import Foundation
import Testing
@testable import TinfoilChat

private actor TokenProviderProbe {
    private static let observationTimeout = Duration.seconds(1)

    private var normalCalls = 0
    private var refreshCalls = 0
    private var refreshContinuations: [CheckedContinuation<String?, Never>] = []
    private var refreshObservation: CheckedContinuation<Bool, Never>?
    private var refreshObservationID = 0
    private var refreshReleased = false
    private var releasedRefreshToken: String?

    func token(forceRefresh: Bool) async -> String? {
        if !forceRefresh {
            normalCalls += 1
            return "cached-token"
        }
        refreshCalls += 1
        refreshObservationID += 1
        refreshObservation?.resume(returning: true)
        refreshObservation = nil
        if refreshReleased { return releasedRefreshToken }
        return await withCheckedContinuation { refreshContinuations.append($0) }
    }

    func releaseRefresh(with token: String?) {
        refreshReleased = true
        releasedRefreshToken = token
        refreshContinuations.forEach { $0.resume(returning: token) }
        refreshContinuations.removeAll()
    }

    func waitForRefresh() async -> Bool {
        if refreshCalls > 0 { return true }
        return await withCheckedContinuation { continuation in
            refreshObservationID += 1
            let observationID = refreshObservationID
            refreshObservation = continuation
            Task {
                try? await Task.sleep(for: Self.observationTimeout)
                self.finishRefreshObservationIfNeeded(observationID: observationID)
            }
        }
    }

    private func finishRefreshObservationIfNeeded(observationID: Int) {
        guard observationID == refreshObservationID else { return }
        refreshObservation?.resume(returning: false)
        refreshObservation = nil
    }

    func counts() -> (normal: Int, refresh: Int) {
        (normalCalls, refreshCalls)
    }
}

struct SyncAuthenticationRecoveryTests {
    @Test func forcedRefreshIsSingleFlight() async throws {
        let probe = TokenProviderProbe()
        let client = SyncEnclaveClient(enclaveURL: "https://example.com", configRepo: "owner/repo")
        await client.setTokenGetter { forceRefresh in
            await probe.token(forceRefresh: forceRefresh)
        }

        async let first = client.requireToken(forceRefresh: true)
        async let second = client.requireToken(forceRefresh: true)
        #expect(await probe.waitForRefresh(), "Token refresh was not requested")
        await probe.releaseRefresh(with: "fresh-token")

        let firstToken = try await first
        let secondToken = try await second
        let counts = await probe.counts()
        #expect(firstToken == "fresh-token")
        #expect(secondToken == "fresh-token")
        #expect(counts.refresh == 1)
    }

    @Test @MainActor
    func failedForcedRefreshRequiresAuthenticationAction() async {
        let client = SyncEnclaveClient(enclaveURL: "https://example.com", configRepo: "owner/repo")
        await client.setTokenGetter { forceRefresh in forceRefresh ? nil : "stale-token" }

        do {
            _ = try await client.requireToken(forceRefresh: true)
            Issue.record("Expected forced refresh failure")
        } catch let error as SyncEnclaveError {
            #expect(error == .authenticationActionRequired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func resetCancelsTokenRefreshFromPreviousAccount() async {
        let probe = TokenProviderProbe()
        let client = SyncEnclaveClient(enclaveURL: "https://example.com", configRepo: "owner/repo")
        await client.setTokenGetter { forceRefresh in
            await probe.token(forceRefresh: forceRefresh)
        }

        let refresh = Task { try await client.requireToken(forceRefresh: true) }
        #expect(await probe.waitForRefresh(), "Token refresh was not requested")
        await client.reset()
        await probe.releaseRefresh(with: "previous-account-token")

        do {
            _ = try await refresh.value
            Issue.record("Expected previous-account refresh cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}
