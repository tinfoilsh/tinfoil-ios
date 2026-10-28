import Foundation

/// A control plane answer, as the caches read it.
struct ControlPlaneAnswer: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

/// Fetches from the control plane, which is public HTTPS rather than an
/// enclave. A bearer identity is sent when given.
protocol ControlPlaneTransport: Sendable {
    func get(_ path: String, identity: String?) async throws -> ControlPlaneAnswer
}

struct URLSessionControlPlane: ControlPlaneTransport {
    private let session: URLSession
    private let origin: URL

    init(origin: String = Constants.API.baseURL) throws {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.path.isEmpty || url.path == "/",
              url.query == nil, url.fragment == nil else {
            throw HarnessError(code: HarnessErrorCode.configuration, message: "Configure an HTTPS origin for the control plane.", action: .stop)
        }
        self.origin = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.Harness.ChatAccess.mintTimeoutSeconds
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RedirectRefusal.shared, delegateQueue: nil)
    }

    func get(_ path: String, identity: String?) async throws -> ControlPlaneAnswer {
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let identity { request.setValue("Bearer \(identity)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarnessError(code: HarnessErrorCode.connection, message: "The control plane did not answer.", action: .retry)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return ControlPlaneAnswer(status: http.statusCode, headers: headers, body: data)
    }
}

/// The quota a control plane answer reports, in the form the harness
/// reports a free key's. A missing or zero maximum leaves that dimension
/// unlimited.
enum ControlPlaneQuota {
    static func rateLimit(of value: Any?, kind: RateLimitKind) -> HarnessRateLimit {
        let raw = value as? [String: Any] ?? [:]
        var limit = HarnessRateLimit(kind: .named(kind))
        if let maxRequests = raw["max_requests"] as? Int, maxRequests > 0, let remaining = raw["remaining"] as? Int {
            limit.maxRequests = maxRequests
            limit.remaining = remaining
        }
        limit.inputTokens = budget(raw["max_input_tokens"], raw["input_tokens_used"], raw["input_tokens_remaining"])
        limit.outputTokens = budget(raw["max_output_tokens"], raw["output_tokens_used"], raw["output_tokens_remaining"])
        if let resetsAt = raw["resets_at"] as? String, !resetsAt.isEmpty { limit.resetsAt = resetsAt }
        return limit
    }

    private static func budget(_ max: Any?, _ used: Any?, _ remaining: Any?) -> Components.Schemas.TokenBudget? {
        guard let max = max as? Int, max > 0, let used = used as? Int, let remaining = remaining as? Int else { return nil }
        return Components.Schemas.TokenBudget(max: max, used: used, remaining: remaining)
    }
}

/// The chat access a signed-in account's harness requests carry: a
/// subscriber's chat token, or the account's free key. The app mints it from
/// the control plane, as the account's own client, and the harness verifies
/// it.
actor ChatAccessCache {
    struct Credential: Sendable {
        let key: String
        let expiresAt: Date
        let kind: RateLimitKind
    }

    private let controlPlane: ControlPlaneTransport
    private let onRateLimit: @Sendable (HarnessRateLimit) -> Void
    private let now: @Sendable () -> Date
    private var cached: Credential?
    private var pending: Task<Credential, Error>?
    private var generation = 0
    /// A refusal is kept until it says to ask again, or for a while when it
    /// does not, so an account at its hourly cap does not ask with every
    /// request.
    private var refused: (error: HarnessError, until: Date)?
    /// The account last held a subscriber's token, which a run renews.
    private var heldHourly = false

    init(
        controlPlane: ControlPlaneTransport,
        onRateLimit: @escaping @Sendable (HarnessRateLimit) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.controlPlane = controlPlane
        self.onRateLimit = onRateLimit
        self.now = now
    }

    /// The access held, minted again once it enters its renewal window, or
    /// at once when refreshing. A transient failure to mint keeps the access
    /// held while it lasts.
    func get(identity: String, refresh: Bool = false) async throws -> String {
        if !refresh, let cached, cached.expiresAt.addingTimeInterval(-Constants.Harness.ChatAccess.renewBeforeExpirySeconds) > now() {
            return cached.key
        }
        if let refused, refused.until > now() {
            if !refresh, let held = usableAfterFailure(refused.error) { return held }
            throw refused.error
        }
        let pending = self.pending ?? Task { [generation] in try await mint(identity: identity, generation: generation) }
        self.pending = pending
        defer { if self.pending == pending { self.pending = nil } }
        do {
            return try await pending.value.key
        } catch {
            if !refresh, let held = usableAfterFailure(error) { return held }
            throw error
        }
    }

    /// When the chat token is minted again: as it enters its renewal window,
    /// or once a refusal lifts. A subscriber whose token is gone, as after
    /// a refusal lifted and a mint failed, is asked for again shortly. A
    /// free key, or no access, has no such time.
    func renewsAt() -> Date? {
        if let refused, refused.until > now() { return refused.until }
        guard let cached else {
            return heldHourly ? now().addingTimeInterval(Constants.Harness.runRenewalRetrySeconds) : nil
        }
        guard cached.kind == .hourly else { return nil }
        return cached.expiresAt.addingTimeInterval(-Constants.Harness.ChatAccess.renewBeforeExpirySeconds)
    }

    /// Forgets the access and any refusal, as when the harness refused the
    /// access or the account's subscription changed.
    func reset() {
        cached = nil
        generation += 1
        pending = nil
        refused = nil
    }

    private func usableAfterFailure(_ cause: Error) -> String? {
        let transient: Bool
        if let harnessError = cause as? HarnessError {
            transient = harnessError.status == nil
                || harnessError.status! >= Constants.Harness.ChatAccess.serverErrorStatus
                || harnessError.code == HarnessErrorCode.rateLimited
        } else {
            transient = !(cause is CancellationError)
        }
        guard transient, let cached, cached.expiresAt > now() else { return nil }
        return cached.key
    }

    private func mint(identity: String, generation: Int) async throws -> Credential {
        var answer = try await controlPlane.get(Constants.API.SessionToken.chatPath, identity: identity)
        try superseded(generation)
        var kind = RateLimitKind.hourly
        // Only a missing subscription falls back to the free key: a capped or
        // suspended subscriber must not be downgraded around its limit.
        if answer.status == Constants.Harness.ChatAccess.subscriptionRequiredStatus {
            if cached?.kind == .hourly { cached = nil }
            answer = try await controlPlane.get(Constants.Harness.ChatAccess.freeKeyPath, identity: identity)
            try superseded(generation)
            kind = .freeDaily
        }
        let value = answer.json
        guard (200..<300).contains(answer.status) else { throw refuse(answer, value) }
        guard let key = value["key"] as? String, !key.isEmpty,
              let expiresAt = (value["expires_at"] as? String).flatMap(Self.date(of:)), expiresAt > now() else {
            throw HarnessError(code: HarnessErrorCode.upstreamRefused, message: "Tinfoil returned invalid chat access. Please try again.", action: .retry)
        }
        onRateLimit(value["rate_limit"].map { ControlPlaneQuota.rateLimit(of: $0, kind: kind) } ?? HarnessRateLimit(kind: nil))
        refused = nil
        let credential = Credential(key: key, expiresAt: expiresAt, kind: kind)
        cached = credential
        heldHourly = kind == .hourly
        return credential
    }

    private func superseded(_ generation: Int) throws {
        if generation != self.generation { throw CancellationError() }
    }

    /// The refusal a control plane answer means, kept until it says to retry.
    private func refuse(_ answer: ControlPlaneAnswer, _ value: [String: Any]) -> HarnessError {
        let access = Constants.Harness.ChatAccess.self
        let retryAfter = answer.header(Constants.API.SessionToken.retryAfterHeader).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        var until: Date? = retryAfter.map { now().addingTimeInterval(TimeInterval($0)) }
        if until == nil, [access.tooManyRequestsStatus, access.forbiddenStatus, access.unavailableStatus].contains(answer.status) {
            until = now().addingTimeInterval(access.refusalFallbackSeconds)
        }
        let error: HarnessError
        if answer.status == access.tooManyRequestsStatus, value["code"] as? String == Constants.API.ErrorCode.hourlyLimitReached {
            let resetsAt = (value["resets_at"] as? String) ?? ((value["rate_limit"] as? [String: Any])?["resets_at"] as? String)
            var rateLimit = ControlPlaneQuota.rateLimit(of: value["rate_limit"], kind: .hourly)
            rateLimit.maxRequests = 0
            rateLimit.remaining = 0
            if let resetsAt { rateLimit.resetsAt = resetsAt }
            onRateLimit(rateLimit)
            error = HarnessError(HarnessErrorBody(
                code: HarnessErrorCode.quotaExhausted,
                message: (value["error"] as? String) ?? "You have reached your hourly usage limit.",
                action: .wait,
                kind: "hourly",
                retryAfter: retryAfter,
                resetsAt: resetsAt,
                rateLimit: rateLimit
            ), status: answer.status)
            if let resetsAt, let resets = Self.date(of: resetsAt) { until = resets }
        } else if answer.status == access.tooManyRequestsStatus {
            error = HarnessError(HarnessErrorBody(
                code: HarnessErrorCode.rateLimited,
                message: "Chat access is busy. Please try again shortly.",
                action: .retry,
                retryAfter: retryAfter
            ), status: answer.status)
        } else if answer.status == access.forbiddenStatus {
            error = HarnessError(code: HarnessErrorCode.upstreamRefused, message: "This account is suspended.", action: .stop, status: answer.status)
        } else if answer.status == access.unavailableStatus {
            let provisioning = value["code"] as? String == access.accountProvisioningCode
            error = HarnessError(HarnessErrorBody(
                code: HarnessErrorCode.upstreamRefused,
                message: provisioning
                    ? "Your account is still being set up. Please try again shortly."
                    : "Chat access is temporarily unavailable. Please try again shortly.",
                action: .retry,
                retryAfter: retryAfter
            ), status: answer.status)
        } else {
            error = HarnessError(HarnessErrorBody(
                code: HarnessErrorCode.upstreamRefused,
                message: "Unable to obtain chat access. Please try again.",
                action: .retry,
                status: answer.status
            ), status: answer.status)
        }
        if answer.status == access.forbiddenStatus || error.code == HarnessErrorCode.quotaExhausted { cached = nil }
        if let until, until > now() { refused = (error, until) }
        return error
    }

    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeDates = ISO8601DateFormatter()

    static func date(of text: String) -> Date? {
        fractionalDates.date(from: text) ?? wholeDates.date(from: text)
    }
}

/// A free key for a signed-out caller, issued by the control plane by
/// address and kept only in memory.
actor AnonymousAccessCache {
    private struct Credential {
        let key: String
        let expiresAt: Date
    }

    private let controlPlane: ControlPlaneTransport
    private let now: @Sendable () -> Date
    private var cached: Credential?
    private var pending: Task<Credential, Error>?

    init(controlPlane: ControlPlaneTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.controlPlane = controlPlane
        self.now = now
    }

    func get() async throws -> String {
        if let cached, cached.expiresAt > now() { return cached.key }
        let pending = self.pending ?? Task { try await issue() }
        self.pending = pending
        defer { if self.pending == pending { self.pending = nil } }
        return try await pending.value.key
    }

    /// Drops the key held, as when the harness refused it, so the next
    /// request issues another.
    func forget() {
        cached = nil
    }

    private func issue() async throws -> Credential {
        let answer = try await controlPlane.get(Constants.Harness.ChatAccess.freeKeyPath, identity: nil)
        guard (200..<300).contains(answer.status) else {
            let capped = answer.status == Constants.Harness.ChatAccess.tooManyRequestsStatus
            throw HarnessError(
                code: capped ? HarnessErrorCode.quotaExhausted : HarnessErrorCode.upstreamRefused,
                message: "Unable to obtain anonymous chat access. Please try again.",
                action: capped ? .wait : .retry,
                status: answer.status
            )
        }
        // The harness reports the key's quota; only the key and its expiry
        // are read here.
        let value = answer.json
        let access = Constants.Harness.ChatAccess.self
        guard let key = value["key"] as? String, key.hasPrefix(access.freeKeyPrefix),
              key.count > access.freeKeyPrefix.count, key.count <= access.maximumKeyLength,
              value["is_free_tier"] as? Bool == true,
              let expiresAt = (value["expires_at"] as? String).flatMap(ChatAccessCache.date(of:)), expiresAt > now() else {
            throw HarnessError(code: HarnessErrorCode.upstreamRefused, message: "The control plane returned invalid anonymous chat access.", action: .retry)
        }
        let credential = Credential(key: key, expiresAt: expiresAt)
        cached = credential
        return credential
    }
}

/// Who is asking the harness: the signed-in account through its Clerk
/// session, or a signed-out caller through a free key, with the chat access
/// the account minted.
final class HarnessCredentialProvider: HarnessCredentials {
    private let identityProvider: @Sendable (_ refresh: Bool) async throws -> String?
    private let chatAccess: ChatAccessCache
    private let anonymousAccess: AnonymousAccessCache

    init(
        identity: @escaping @Sendable (_ refresh: Bool) async throws -> String?,
        chatAccess: ChatAccessCache,
        anonymousAccess: AnonymousAccessCache
    ) {
        identityProvider = identity
        self.chatAccess = chatAccess
        self.anonymousAccess = anonymousAccess
    }

    func identity(refresh: Bool) async throws -> String? {
        try await identityProvider(refresh)
    }

    func anonymousKey(refresh: Bool) async throws -> String {
        if refresh { await anonymousAccess.forget() }
        return try await anonymousAccess.get()
    }

    func chatAccess(identity: String, refresh: Bool) async throws -> String {
        try await chatAccess.get(identity: identity, refresh: refresh)
    }

    func chatAccessRenewsAt() async -> Date? {
        await chatAccess.renewsAt()
    }

    /// Mints the account's chat access again, as when its subscription
    /// changed.
    func resetChatAccess() async {
        await chatAccess.reset()
    }
}
