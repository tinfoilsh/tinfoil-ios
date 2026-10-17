import Foundation
import Testing
import TinfoilAI
@testable import TinfoilChat

private enum AttestationRecoveryFixture {
    static let enclaveURL = "https://example.com"
    static let configRepo = "owner/repo"
    static let healthURL = "https://example.com/v1/health"

    /// Verification failures as the SDK reports them, paired with the
    /// recovery sync takes. Attestation fetch failures that a retry can heal
    /// are retried; everything else blocks sync as a failed attestation.
    static let verificationFailures: [(TinfoilError, RecoveryAction)] = [
        (.fetchError("offline", urlError: URLError(.notConnectedToInternet)), .retry(reason: .network)),
        (.fetchError("timed out", urlError: URLError(.timedOut)), .retry(reason: .network)),
        (.fetchError("unavailable", status: 503), .retry(reason: .network)),
        (.fetchError("not found", status: 404), .blockAllSync(reason: .attestationFailed)),
        (.fetchError("response too large"), .blockAllSync(reason: .attestationFailed)),
        (
            .fetchError("untrusted", urlError: URLError(.serverCertificateUntrusted)),
            .blockAllSync(reason: .attestationFailed)
        ),
        (.attestationError("measurement mismatch"), .blockAllSync(reason: .attestationFailed)),
    ]

    /// Request failures as `EnclaveHandle.data(for:)` surfaces them
    static let requestFailures: [(any Error, RecoveryAction)] = [
        // The enclave's key still failed the pin after the SDK re-verified.
        (TinfoilError.attestationError("key does not match the attestation"), .blockAllSync(reason: .attestationFailed)),
        // Verifying on first use, before the request, failed to fetch.
        (
            TinfoilError.fetchError("offline", urlError: URLError(.notConnectedToInternet)),
            .retry(reason: .network)
        ),
        (URLError(.networkConnectionLost), .retry(reason: .network)),
        // A certificate the system rejects is persistent, not a network blip.
        (URLError(.serverCertificateUntrusted), .abort(reason: .unknown)),
    ]
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

/// Stands in for the SDK's `EnclaveHandle`: verification and requests block
/// or fail as a test arranges.
private actor FakeEnclave: EnclaveTransport {
    typealias Gate = (started: AttestationRecoveryGate, release: AttestationRecoveryGate)

    private let verificationGate: Gate?
    private let verificationError: Error?
    private let requestGate: Gate?
    private let requestError: Error?
    private(set) var verificationCount = 0
    private(set) var requestCount = 0

    init(
        verificationGate: Gate? = nil,
        verificationError: Error? = nil,
        requestGate: Gate? = nil,
        requestError: Error? = nil
    ) {
        self.verificationGate = verificationGate
        self.verificationError = verificationError
        self.requestGate = requestGate
        self.requestError = requestError
    }

    func prepare() async throws {
        verificationCount += 1
        if let verificationGate {
            await verificationGate.started.open()
            await verificationGate.release.wait()
        }
        if let verificationError {
            throw verificationError
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if let requestGate {
            await requestGate.started.open()
            await requestGate.release.wait()
        }
        if let requestError {
            throw requestError
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            throw URLError(.badURL)
        }
        return (Data(), response)
    }
}

/// Records every transport the client creates, numbered from 1
private final class FakeEnclaves: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeEnclave] = []
    private let configure: @Sendable (_ number: Int) -> FakeEnclave

    init(_ configure: @escaping @Sendable (_ number: Int) -> FakeEnclave = { _ in FakeEnclave() }) {
        self.configure = configure
    }

    func make() -> FakeEnclave {
        lock.lock()
        defer { lock.unlock() }
        let enclave = configure(made.count + 1)
        made.append(enclave)
        return enclave
    }

    var all: [FakeEnclave] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }
}

/// An empty JSON object, for requests whose response body is not inspected
private struct EmptyResponse: Decodable {}

/// Runs `operation`, expecting it to fail with an error that sync recovers
/// from with `expected`
private func expectRecoveryAction(
    _ expected: RecoveryAction,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected the operation to fail", sourceLocation: sourceLocation)
    } catch {
        #expect(EnclaveErrorRecovery.decide(error).action == expected, sourceLocation: sourceLocation)
    }
}

/// Awaits `task`, expecting it to have been canceled
private func expectCancellation<Success>(
    _ task: Task<Success, Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        _ = try await task.value
        Issue.record("Expected CancellationError", sourceLocation: sourceLocation)
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Sync enclave attestation recovery", .timeLimit(.minutes(1)))
struct SyncEnclaveAttestationRecoveryTests {
    private func makeClient(_ enclaves: FakeEnclaves) -> SyncEnclaveClient {
        SyncEnclaveClient(
            enclaveURL: AttestationRecoveryFixture.enclaveURL,
            configRepo: AttestationRecoveryFixture.configRepo,
            makeTransport: { _, _ in enclaves.make() },
            protocolVersion: { 1 }
        )
    }

    @Test(arguments: AttestationRecoveryFixture.verificationFailures)
    func verificationFailureRecovery(failure: TinfoilError, expected: RecoveryAction) async throws {
        let enclaves = FakeEnclaves { _ in FakeEnclave(verificationError: failure) }
        let client = makeClient(enclaves)
        await expectRecoveryAction(expected) {
            try await client.ready()
        }
    }

    @Test(arguments: AttestationRecoveryFixture.requestFailures)
    func requestFailureRecovery(failure: any Error, expected: RecoveryAction) async throws {
        let enclaves = FakeEnclaves { _ in FakeEnclave(requestError: failure) }
        let client = makeClient(enclaves)
        await expectRecoveryAction(expected) {
            _ = try await client.withTransport {
                try await $0.get(url: AttestationRecoveryFixture.healthURL)
            }
        }
    }

    @Test func cancellationIsNotWrapped() async throws {
        let enclaves = FakeEnclaves { _ in FakeEnclave(requestError: CancellationError()) }
        let client = makeClient(enclaves)
        do {
            _ = try await client.withTransport {
                try await $0.get(url: AttestationRecoveryFixture.healthURL)
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func failedVerificationIsNotCached() async throws {
        let enclaves = FakeEnclaves { _ in
            FakeEnclave(verificationError: TinfoilError.attestationError("measurement mismatch"))
        }
        let client = makeClient(enclaves)
        for _ in 0..<2 {
            await expectRecoveryAction(.blockAllSync(reason: .attestationFailed)) {
                try await client.ready()
            }
        }
        let made = enclaves.all
        #expect(made.count == 1)
        if let enclave = made.first {
            #expect(await enclave.verificationCount == 2)
        }
    }

    @Test func transportIsReusedUntilReset() async throws {
        let enclaves = FakeEnclaves()
        let client = makeClient(enclaves)
        for _ in 0..<2 {
            _ = try await client.withTransport {
                try await $0.get(url: AttestationRecoveryFixture.healthURL)
            }
        }
        #expect(enclaves.all.count == 1)

        await client.reset()
        _ = try await client.withTransport {
            try await $0.get(url: AttestationRecoveryFixture.healthURL)
        }
        let made = enclaves.all
        #expect(made.count == 2)
        if made.count == 2 {
            #expect(await made[0].requestCount == 2)
            #expect(await made[1].requestCount == 1)
        }
    }

    @Test(arguments: [false, true])
    func resetFencesOldVerificationCompletion(fails: Bool) async throws {
        let started = AttestationRecoveryGate()
        let release = AttestationRecoveryGate()
        let enclaves = FakeEnclaves { number in
            guard number == 1 else { return FakeEnclave() }
            return FakeEnclave(
                verificationGate: (started, release),
                verificationError: fails ? TinfoilError.attestationError("measurement mismatch") : nil
            )
        }
        let client = makeClient(enclaves)
        let old = Task { try await client.ready() }
        await started.wait()
        await client.reset()
        try await client.ready()
        await release.open()
        await expectCancellation(old)

        _ = try await client.withTransport {
            try await $0.get(url: AttestationRecoveryFixture.healthURL)
        }
        let made = enclaves.all
        #expect(made.count == 2)
        if made.count == 2 {
            #expect(await made[0].requestCount == 0)
            #expect(await made[1].requestCount == 1)
        }
    }

    /// The token is taken only after the enclave verifies, so a session that
    /// ends or changes during verification never has its token sent.
    @Test(arguments: [false, true])
    func sessionChangeDuringVerificationSendsNothing(reset: Bool) async throws {
        let started = AttestationRecoveryGate()
        let release = AttestationRecoveryGate()
        let enclaves = FakeEnclaves { number in
            number == 1 ? FakeEnclave(verificationGate: (started, release)) : FakeEnclave()
        }
        let client = makeClient(enclaves)
        await client.setTokenGetter { _ in "old-session-token" }
        let request = Task { () -> EmptyResponse in
            try await client.get(path: "/v1/health")
        }
        await started.wait()
        if reset {
            await client.reset()
        } else {
            await client.setTokenGetter { _ in "new-session-token" }
        }
        await release.open()
        await expectCancellation(request)

        for enclave in enclaves.all {
            #expect(await enclave.requestCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func sessionChangeDuringAuthenticatedRequestCancelsIt(reset: Bool) async throws {
        let started = AttestationRecoveryGate()
        let release = AttestationRecoveryGate()
        let enclaves = FakeEnclaves { _ in FakeEnclave(requestGate: (started, release)) }
        let client = makeClient(enclaves)
        await client.setTokenGetter { _ in "old-session-token" }
        let request = Task { () -> EmptyResponse in
            try await client.get(path: "/v1/health")
        }
        await started.wait()
        if reset {
            await client.reset()
        } else {
            await client.setTokenGetter { _ in "new-session-token" }
        }
        await release.open()
        await expectCancellation(request)

        let made = enclaves.all
        #expect(made.count == 1)
        if let enclave = made.first {
            #expect(await enclave.requestCount == 1)
        }
    }

    @Test(arguments: [false, true])
    func publicRequestsSurviveSessionChanges(reset: Bool) async throws {
        let started = AttestationRecoveryGate()
        let release = AttestationRecoveryGate()
        let enclaves = FakeEnclaves { _ in FakeEnclave(requestGate: (started, release)) }
        let client = makeClient(enclaves)
        let request = Task { () -> EmptyResponse in
            try await client.post(path: "/v1/shares/open", skipAuth: true)
        }
        await started.wait()
        if reset {
            await client.reset()
        } else {
            await client.setTokenGetter { _ in "new-session-token" }
        }
        await release.open()
        _ = try await request.value
    }
}
