import Foundation
import Testing
@testable import TinfoilChat

private actor TokenProviderProbe {
    private var normalCalls = 0
    private var refreshCalls = 0
    private var refreshContinuation: CheckedContinuation<String?, Never>?

    func token(forceRefresh: Bool) async -> String? {
        if !forceRefresh {
            normalCalls += 1
            return "cached-token"
        }
        refreshCalls += 1
        return await withCheckedContinuation { refreshContinuation = $0 }
    }

    func releaseRefresh(with token: String?) {
        refreshContinuation?.resume(returning: token)
        refreshContinuation = nil
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
        while (await probe.counts()).refresh == 0 { await Task.yield() }
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
        defer { SyncHealthStore.shared.reset() }
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
}
