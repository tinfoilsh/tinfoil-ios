import Foundation
import OSLog
import TinfoilAI

/// Who is asking the harness, and the chat access they hold.
protocol HarnessCredentials: Sendable {
    /// The caller's identity: a Clerk session token, or nil when signed out.
    /// Refreshing asks the identity provider again rather than its cache.
    func identity(refresh: Bool) async throws -> String?
    /// A free_ key for a signed-out caller. Refreshing drops the key the
    /// harness refused and issues another.
    func anonymousKey(refresh: Bool) async throws -> String
    /// The chat access a signed-in account minted from the control plane, or
    /// its refusal, as a HarnessError. Refreshing mints again.
    func chatAccess(identity: String, refresh: Bool) async throws -> String
    /// When the held chat access enters its renewal window, if one is held.
    func chatAccessRenewsAt() async -> Date?
}

/// The one client of the harness: it verifies the enclave, says who is
/// asking, mints and renews their chat access, sends requests, reads
/// refusals and streams runs.
actor HarnessClient {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

    private let credentials: HarnessCredentials
    private let transport: HarnessTransport
    private let languages: @Sendable () -> [String]
    /// The instance holding each chat's latest run, by chat, which requests
    /// about the chat's runs are routed to.
    private var instances: [String: String] = [:]
    /// The run streams this client reads, and the renewal of the chat access
    /// their model calls use.
    private var openRuns = 0
    private var runRenewal: Task<Void, Never>?
    private var disposed = false

    private struct ErrorEnvelope: Decodable {
        let error: HarnessErrorBody
    }

    init(
        credentials: HarnessCredentials,
        transport: HarnessTransport,
        languages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.languages = languages
    }

    deinit {
        runRenewal?.cancel()
    }

    func dispose() {
        disposed = true
        runRenewal?.cancel()
        runRenewal = nil
    }

    /// The latest verification of the enclave, or nil before the first.
    func verification() async -> Verification? {
        await transport.verification()
    }

    /// Routes requests about a chat's run to the instance a hint names, for
    /// a run this client did not see start.
    func locate(threadId: String, instance: String) {
        instances[threadId] = instance
    }

    /// Sends a request and reads its JSON answer. A request about a chat's
    /// run names the chat, so it goes to the instance holding the run.
    func post<T: Decodable>(
        _ route: HarnessRoute,
        _ body: some Encodable,
        threadId: String? = nil
    ) async throws -> T {
        let response = try await request(route, json: body, instance: instanceFor(route, threadId))
        return try await decode(response)
    }

    /// Sends a file with its fields as a multipart form and reads the JSON
    /// answer.
    func upload<T: Decodable>(
        _ route: HarnessRoute,
        file: Data,
        fileName: String,
        mimeType: String,
        fields: [String: String] = [:]
    ) async throws -> T {
        let form = MultipartForm(fields: fields, file: file, fileName: fileName, mimeType: mimeType)
        let response = try await request(route, body: form.body, contentType: form.contentType)
        return try await decode(response)
    }

    /// Sends a request and reads its whole answer as bytes, such as an
    /// attachment.
    func download(_ route: HarnessRoute, _ body: some Encodable) async throws -> Data {
        try await request(route, json: body).collect()
    }

    /// Sends a request whose answer the caller reads as it arrives, such as
    /// read-aloud audio.
    func stream(_ route: HarnessRoute, _ body: some Encodable) async throws -> HarnessResponse {
        try await request(route, json: body)
    }

    /// A run's events. Following a run replays it from its first frame, or
    /// from after the last one this client applied when it names it.
    func events(
        _ route: HarnessRoute,
        _ body: some Encodable,
        threadId: String? = nil,
        lastEventId: Int? = nil
    ) async throws -> AsyncThrowingStream<Frame, Error> {
        precondition(route.startsStream, "\(route.rawValue) starts no run stream")
        let response = try await request(
            route,
            json: body,
            instance: instanceFor(route, threadId),
            lastEventId: lastEventId
        )
        guard response.header("content-type")?.lowercased().hasPrefix("text/event-stream") == true else {
            throw HarnessError.invalidStream("The chat service did not return an event stream.")
        }
        runOpened()
        let frames = HarnessEventStream.frames(from: response.body)
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { self.runClosed() }
                do {
                    for try await frame in frames {
                        if case .runStarted(let started) = frame.event {
                            self.locate(threadId: started.threadId, instance: started.instance)
                        }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Requests

    private func request(
        _ route: HarnessRoute,
        json body: some Encodable,
        instance: String? = nil,
        lastEventId: Int? = nil
    ) async throws -> HarnessResponse {
        try await request(
            route,
            body: try JSONEncoder().encode(body),
            contentType: "application/json",
            instance: instance,
            lastEventId: lastEventId
        )
    }

    /// Sends one request as the caller, minting their chat access first, and
    /// once more with a refreshed identity when the harness asks for one.
    private func request(
        _ route: HarnessRoute,
        body: Data,
        contentType: String,
        instance: String? = nil,
        lastEventId: Int? = nil
    ) async throws -> HarnessResponse {
        try Task.checkCancellation()
        var token = try await credentials.identity(refresh: false)
        let anonymous = token == nil
        if anonymous { token = try await credentials.anonymousKey(refresh: false) }
        // A signed-in request carries the account's chat access. A request
        // that needs none still goes when the control plane refused it, as at
        // an hourly cap; one that needs it fails with that refusal.
        var credential: String?
        var refusal: Error?
        func mint(refresh: Bool) async throws {
            credential = nil
            refusal = nil
            guard let token else { return }
            do {
                credential = try await credentials.chatAccess(identity: token, refresh: refresh)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                refusal = error
            }
        }
        if !anonymous { try await mint(refresh: false) }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var headers = ["Content-Type": contentType]
            let languages = languages()
            if !languages.isEmpty { headers["Accept-Language"] = languages.joined(separator: ",") }
            if let token { headers["Authorization"] = "Bearer \(token)" }
            if let credential { headers[HarnessHeader.inferenceKey] = credential }
            if let instance { headers[HarnessHeader.instance] = instance }
            if let lastEventId { headers[HarnessHeader.lastEventId] = String(lastEventId) }
            let response = try await transport.send(HarnessRequest(route: route, headers: headers, body: body))
            if response.isSuccess { return response }
            // A refusal without the harness's error envelope, or one that
            // names no action, is not one the protocol allows.
            let answer = try await response.collect()
            let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: answer))?.error
                ?? HarnessErrorBody.invalidResponse
            let needsCredential = detail.code == HarnessErrorCode.credentialRequired
            if detail.action == .reauthenticate, attempt == 0 {
                if anonymous {
                    token = try await credentials.anonymousKey(refresh: true)
                } else {
                    token = try await credentials.identity(refresh: true)
                    // Access the harness refused is minted again; a refusal
                    // the control plane gave is kept until it says to retry.
                    if token != nil { try await mint(refresh: credential != nil && needsCredential) }
                }
                if token == nil { throw HarnessError.unauthenticated }
                continue
            }
            if needsCredential, let refusal { throw refusal }
            throw HarnessError(detail, status: response.status)
        }
        throw HarnessError.unauthenticated
    }

    /// An answer that is not the JSON the protocol describes is not one the
    /// protocol allows.
    private func decode<T: Decodable>(_ response: HarnessResponse) async throws -> T {
        let data = try await response.collect()
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch is DecodingError {
            throw HarnessError(HarnessErrorBody.invalidResponse, status: response.status)
        }
    }

    /// The instance a request about a chat's run goes to, once the chat's run
    /// named it.
    private func instanceFor(_ route: HarnessRoute, _ threadId: String?) -> String? {
        guard route.aboutRun, let threadId else { return nil }
        return instances[threadId]
    }

    // MARK: - Chat access renewal

    /// A run's model calls can outlast the chat access it started with.
    /// While a run stream is open, the access is minted again as it enters
    /// its renewal window and presented to the harness, which gives a run
    /// whose access expired the newest one the account presented.
    private func runOpened() {
        openRuns += 1
        if openRuns == 1 { scheduleRunRenewal() }
    }

    private func runClosed() {
        openRuns -= 1
        if openRuns == 0 { scheduleRunRenewal() }
    }

    private func scheduleRunRenewal() {
        runRenewal?.cancel()
        runRenewal = nil
        guard openRuns > 0, !disposed else { return }
        runRenewal = Task {
            let at = await credentials.chatAccessRenewsAt()
            guard let at else { return }
            let delay = at.timeIntervalSinceNow
            do {
                try await Task.sleep(for: .seconds(delay > 0 ? delay : Constants.Harness.runRenewalRetrySeconds))
            } catch {
                return
            }
            await renewForRuns()
        }
    }

    private struct Empty: Encodable {}

    private func renewForRuns() async {
        runRenewal = nil
        defer { scheduleRunRenewal() }
        // Another request may have renewed and presented it since.
        guard let at = await credentials.chatAccessRenewsAt(), at <= Date() else { return }
        do {
            _ = try await request(.session, json: Empty())
        } catch {
            if !disposed {
                Self.logger.error("Failed to renew chat access for a running reply: \(error, privacy: .public)")
            }
        }
    }
}

/// A multipart form with one file, as an upload sends it.
struct MultipartForm {
    let body: Data
    let contentType: String

    init(fields: [String: String], file: Data, fileName: String, mimeType: String, fileField: String = "file") {
        let boundary = "tinfoil-" + UUID().uuidString
        var body = Data()
        func line(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n\(value)\r\n")
        }
        line("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(fileField))\"; filename=\"\(Self.quoted(fileName))\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(file)
        line("\r\n--\(boundary)--\r\n")
        self.body = body
        contentType = "multipart/form-data; boundary=\(boundary)"
    }

    /// A name or file name as a form field quotes it.
    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
