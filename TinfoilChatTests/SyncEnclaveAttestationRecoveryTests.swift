import Foundation
import Testing
import TinfoilAI
@testable import TinfoilChat

private enum AttestationRecoveryFixture {
    static let enclaveURL = "https://example.com"
    static let configRepo = "owner/repo"
    static let body = Data(#"{"idempotency_key":"same-write","content":"hello"}"#.utf8)
    static let mismatch = NSError(
        domain: "go",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Post \"https://example.com/v1/push\": certificate fingerprint mismatch"]
    )
}

private actor AttestationRecoveryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor AttestationRecoveryProbe {
    let verificationStarted = AttestationRecoveryGate()
    let releaseVerification = AttestationRecoveryGate()
    private var clients: [SecureClient] = []
    private var requests: [(client: Int, body: Data)] = []
    private let blockedVerification: Int?
    private let failedVerifications: Set<Int>
    private let verificationError: Error

    init(
        blockedVerification: Int? = nil,
        failedVerifications: Set<Int> = [],
        verificationError: Error = VerificationError.verificationFailed("measurement mismatch")
    ) {
        self.blockedVerification = blockedVerification
        self.failedVerifications = failedVerifications
        self.verificationError = verificationError
    }

    func verify(_ client: SecureClient) async throws {
        clients.append(client)
        let attempt = clients.count
        if attempt == blockedVerification {
            await verificationStarted.open()
            await releaseVerification.wait()
        }
        if failedVerifications.contains(attempt) {
            throw verificationError
        }
    }

    func recordRequest(_ client: SecureClient, body: Data = Data()) -> Int {
        let number = clients.firstIndex(where: { $0 === client }).map { $0 + 1 } ?? 0
        requests.append((number, body))
        return number
    }

    func verificationCount() -> Int { clients.count }
    func requestClients() -> [Int] { requests.map(\.client) }
    func requestBodies() -> [Data] { requests.map(\.body) }
}

@Suite("Sync enclave attestation recovery", .timeLimit(.minutes(1)))
struct SyncEnclaveAttestationRecoveryTests {
    private func makeClient(_ probe: AttestationRecoveryProbe) -> SyncEnclaveClient {
        SyncEnclaveClient(
            enclaveURL: AttestationRecoveryFixture.enclaveURL,
            configRepo: AttestationRecoveryFixture.configRepo,
            verifyClient: { try await probe.verify($0) }
        )
    }

    @Test func certificateRotationReplaysSamePayloadAndKeepsAuthentication() async throws {
        let probe = AttestationRecoveryProbe()
        let client = makeClient(probe)
        await client.setTokenGetter { _ in "session-token" }
        let result = try await client.withAttestedClient { transport in
            let number = await probe.recordRequest(transport, body: AttestationRecoveryFixture.body)
            if number == 1 { throw AttestationRecoveryFixture.mismatch }
            return "synced"
        }

        #expect(result == "synced")
        #expect(await probe.requestClients() == [1, 2])
        #expect(await probe.requestBodies() == [AttestationRecoveryFixture.body, AttestationRecoveryFixture.body])
        #expect(try await client.requireToken(forceRefresh: false) == "session-token")
        let cached = try await client.withAttestedClient { await probe.recordRequest($0) }
        #expect(cached == 2)
        #expect(await probe.verificationCount() == 2)
    }

    @Test func persistentMismatchStopsAfterOneReplayAndDiscardsRejectedClient() async throws {
        let probe = AttestationRecoveryProbe()
        let client = makeClient(probe)
        do {
            try await client.withAttestedClient { transport in
                _ = await probe.recordRequest(transport)
                throw AttestationRecoveryFixture.mismatch
            }
            Issue.record("Expected a certificate mismatch")
        } catch {
            #expect(EnclaveErrorRecovery.decide(error).action == .blockAllSync(reason: .attestationFailed))
        }
        #expect(await probe.requestClients() == [1, 2])
        #expect(await probe.verificationCount() == 2)

        let recovered = try await client.withAttestedClient { await probe.recordRequest($0) }
        #expect(recovered == 3)
    }

    @Test(arguments: [false, true])
    func failedReattestationNeverReplaysAndNextSyncCanRecover(networkFailure: Bool) async throws {
        let verificationError: Error = networkFailure
            ? URLError(.timedOut)
            : VerificationError.verificationFailed("measurement mismatch")
        let probe = AttestationRecoveryProbe(
            failedVerifications: [2],
            verificationError: verificationError
        )
        let client = makeClient(probe)
        do {
            try await client.withAttestedClient { transport in
                _ = await probe.recordRequest(transport)
                throw AttestationRecoveryFixture.mismatch
            }
            Issue.record("Expected verification to block the request")
        } catch {
            let expected: RecoveryAction = networkFailure
                ? .retry(reason: .network)
                : .blockAllSync(reason: .attestationFailed)
            #expect(EnclaveErrorRecovery.decide(error).action == expected)
        }
        #expect(await probe.requestClients() == [1])
        #expect(await probe.verificationCount() == 2)

        let recovered = try await client.withAttestedClient { await probe.recordRequest($0) }
        #expect(recovered == 3)
    }

    @Test func failedInitialVerificationDoesNotSendRequestOrPoisonCache() async throws {
        let probe = AttestationRecoveryProbe(failedVerifications: [1])
        let client = makeClient(probe)
        do {
            _ = try await client.withAttestedClient { await probe.recordRequest($0) }
            Issue.record("Expected verification failure")
        } catch {
            #expect(EnclaveErrorRecovery.decide(error).action == .blockAllSync(reason: .attestationFailed))
        }
        #expect(await probe.requestClients().isEmpty)
        let recovered = try await client.withAttestedClient { await probe.recordRequest($0) }
        #expect(recovered == 2)
    }

    @Test func concurrentMismatchesShareFreshVerification() async throws {
        let probe = AttestationRecoveryProbe(blockedVerification: 2)
        let client = makeClient(probe)
        let firstRequestStarted = AttestationRecoveryGate()
        let secondRequestStarted = AttestationRecoveryGate()
        let first = Task {
            try await client.withAttestedClient { transport in
                let number = await probe.recordRequest(transport)
                if number == 1 {
                    await firstRequestStarted.open()
                    await secondRequestStarted.wait()
                    throw AttestationRecoveryFixture.mismatch
                }
                return number
            }
        }
        await firstRequestStarted.wait()
        let second = Task {
            try await client.withAttestedClient { transport in
                let number = await probe.recordRequest(transport)
                if number == 1 {
                    await secondRequestStarted.open()
                    throw AttestationRecoveryFixture.mismatch
                }
                return number
            }
        }
        await probe.verificationStarted.wait()
        await probe.releaseVerification.open()
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult == 2)
        #expect(secondResult == 2)
        #expect(await probe.verificationCount() == 2)
        #expect(await probe.requestClients().sorted() == [1, 1, 2, 2])
    }

    @Test func lateMismatchDoesNotEvictFreshClient() async throws {
        let probe = AttestationRecoveryProbe()
        let client = makeClient(probe)
        let requestStarted = AttestationRecoveryGate()
        let releaseRequest = AttestationRecoveryGate()
        let late = Task {
            try await client.withAttestedClient { transport in
                let number = await probe.recordRequest(transport)
                if number == 1 {
                    await requestStarted.open()
                    await releaseRequest.wait()
                    throw AttestationRecoveryFixture.mismatch
                }
                return number
            }
        }
        await requestStarted.wait()
        let first = try await client.withAttestedClient { transport in
            let number = await probe.recordRequest(transport)
            if number == 1 { throw AttestationRecoveryFixture.mismatch }
            return number
        }
        await releaseRequest.open()
        let lateResult = try await late.value
        #expect(first == 2)
        #expect(lateResult == 2)
        #expect(await probe.verificationCount() == 2)
    }

    @Test(arguments: [false, true])
    func resetFencesOldVerificationCompletion(fails: Bool) async throws {
        let probe = AttestationRecoveryProbe(
            blockedVerification: 1,
            failedVerifications: fails ? [1] : []
        )
        let client = makeClient(probe)
        let old = Task { try await client.ready() }
        await probe.verificationStarted.wait()
        await client.reset()
        try await client.ready()
        await probe.releaseVerification.open()
        do {
            try await old.value
            Issue.record("Expected old verification to be canceled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        let current = try await client.withAttestedClient { await probe.recordRequest($0) }
        #expect(current == 2)
        #expect(await probe.verificationCount() == 2)
    }

    @Test func resetDuringRequestPreventsReplay() async throws {
        let probe = AttestationRecoveryProbe()
        let client = makeClient(probe)
        let requestStarted = AttestationRecoveryGate()
        let releaseRequest = AttestationRecoveryGate()
        let old = Task {
            try await client.withAttestedClient { transport in
                _ = await probe.recordRequest(transport)
                await requestStarted.open()
                await releaseRequest.wait()
                throw AttestationRecoveryFixture.mismatch
            }
        }
        await requestStarted.wait()
        await client.reset()
        try await client.ready()
        await releaseRequest.open()
        do {
            try await old.value
            Issue.record("Expected old request to be canceled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await probe.requestClients() == [1])
        #expect(await probe.verificationCount() == 2)
    }

    @Test func cancelingWaiterDoesNotCancelSharedVerification() async throws {
        let probe = AttestationRecoveryProbe(blockedVerification: 1)
        let client = makeClient(probe)
        let canceled = Task { try await client.ready() }
        await probe.verificationStarted.wait()
        let other = Task { try await client.ready() }
        canceled.cancel()
        await probe.releaseVerification.open()
        do {
            try await canceled.value
            Issue.record("Expected canceled waiter to fail")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        try await other.value
        #expect(await probe.verificationCount() == 1)
    }

    @Test func unrelatedErrorsDoNotRefreshOrReplay() async throws {
        let errors: [Error] = [
            URLError(.timedOut),
            URLError(.secureConnectionFailed),
            CancellationError(),
            VerificationError.notVerified,
            SyncEnclaveError(message: Constants.SyncEnclave.certificateMismatchMessage, status: 500),
            SyncEnclaveError.authenticationActionRequired
        ]
        for error in errors {
            let probe = AttestationRecoveryProbe()
            let client = makeClient(probe)
            do {
                try await client.withAttestedClient { transport in
                    _ = await probe.recordRequest(transport)
                    throw error
                }
                Issue.record("Expected the request to fail")
            } catch {
                #expect(!SyncEnclaveClient.isCertificateMismatch(error))
            }
            #expect(await probe.requestClients() == [1])
            #expect(await probe.verificationCount() == 1)
        }
    }

    @Test func mismatchRecognitionIsNarrow() {
        #expect(SyncEnclaveClient.isCertificateMismatch(AttestationRecoveryFixture.mismatch))
        #expect(!SyncEnclaveClient.isCertificateMismatch(NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorSecureConnectionFailed,
            userInfo: [NSLocalizedDescriptionKey: "certificate fingerprint mismatch"]
        )))
        #expect(!SyncEnclaveClient.isCertificateMismatch(NSError(
            domain: "go", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "certificate fingerprint mismatch"]
        )))
        for message in [
            "certificate fingerprint mismatch",
            "Get \"https://example.com/v1/health\": certificate fingerprint mismatch"
        ] {
            #expect(SyncEnclaveClient.isCertificateMismatch(NSError(
                domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: message]
            )))
        }
        for message in [
            "certificate expired",
            "certificate fingerprint mismatch while decoding response",
            "no certificate fingerprint mismatch"
        ] {
            #expect(!SyncEnclaveClient.isCertificateMismatch(NSError(
                domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: message]
            )))
        }
    }
}
