import Foundation

@MainActor
final class ChatTokenRequestGate {
    /// Outcome of attempting to mint a stateless JWT inference token.
    enum Result: Equatable, Sendable {
        case token(key: String, expiresAt: Date?)
        case rateLimited(resetsAt: String?, retryAt: Date)
        case unavailable
        case cancelled
    }

    private struct Cooldown {
        let id = UUID()
        let result: Result
        let retryAt: Date
    }

    private let send: @MainActor (URLRequest) async throws -> (Data, URLResponse)
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private var requestTask: Task<Result, Never>?
    private var generation = UUID()
    private var cooldown: Cooldown?
    private var resetTask: Task<Void, Never>?
    var onCooldownExpired: (@MainActor () async -> Void)?

    init(
        send: @escaping @MainActor (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        },
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.send = send
        self.now = now
        self.sleep = sleep
    }

    var currentRateLimit: Result? {
        guard let cooldown else { return nil }
        guard cooldown.retryAt > now() else {
            clearCooldown()
            return nil
        }
        return cooldown.result
    }

    var isCoolingDown: Bool {
        currentRateLimit != nil
    }

    func fetch(jwt: String, bypassCooldown: Bool = false) async -> Result {
        guard !Task.isCancelled else { return .cancelled }
        if !bypassCooldown, let limit = currentRateLimit {
            return limit
        }
        let requestGeneration = generation
        let task: Task<Result, Never>
        if let requestTask {
            task = requestTask
        } else {
            task = Task {
                guard generation == requestGeneration, !Task.isCancelled else { return .cancelled }
                let result = await requestJWT(jwt: jwt)
                guard generation == requestGeneration, !Task.isCancelled else { return .cancelled }
                switch result {
                case .token:
                    clearCooldown()
                case .rateLimited(_, let retryAt):
                    scheduleReset(result: result, retryAt: retryAt)
                case .unavailable:
                    if let limit = currentRateLimit { return limit }
                case .cancelled:
                    break
                }
                return result
            }
            requestTask = task
        }
        let result = await task.value
        guard generation == requestGeneration else { return .cancelled }
        if requestTask == task { requestTask = nil }
        return Task.isCancelled ? .cancelled : result
    }

    func reset() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        clearCooldown()
    }

    private func clearCooldown() {
        resetTask?.cancel()
        resetTask = nil
        cooldown = nil
    }

    private func scheduleReset(result: Result, retryAt: Date) {
        clearCooldown()
        let scheduled = Cooldown(result: result, retryAt: retryAt)
        cooldown = scheduled
        let delay = max(0, retryAt.timeIntervalSince(now()))
        let sleep = self.sleep
        resetTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.cooldown?.id == scheduled.id else { return }
            self.cooldown = nil
            self.resetTask = nil
            await self.onCooldownExpired?()
        }
    }

    /// Mints a stateless JWT inference token for a subscribed user via
    /// /api/chat/token. Returns `.unavailable` on any non-rate-limit failure
    /// (no subscription, endpoint disabled, network error) so the caller falls
    /// back to the opaque /api/keys/chat path.
    private func requestJWT(jwt: String) async -> Result {
        do {
            var request = URLRequest(url: URL(string: Constants.API.baseURL + Constants.API.SessionToken.chatPath)!)
            request.httpMethod = "GET"
            request.timeoutInterval = Constants.API.SessionToken.requestTimeoutSeconds
            request.addValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await send(request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else { return .unavailable }

            if httpResponse.statusCode == 200 {
                guard let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let key = responseDict["key"] as? String,
                      !key.isEmpty else { return .unavailable }
                return .token(key: key, expiresAt: Self.isoDate(responseDict["expires_at"] as? String))
            }

            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let isHourlyLimit = httpResponse.statusCode == Constants.API.tooManyRequestsStatusCode
                || (body?["code"] as? String) == Constants.API.ErrorCode.hourlyLimitReached
            if isHourlyLimit {
                let budget = body?["rate_limit"] as? [String: Any]
                let resetsAt = body?["resets_at"] as? String ?? budget?["resets_at"] as? String
                return .rateLimited(
                    resetsAt: resetsAt,
                    retryAt: Self.retryDate(resetsAt: resetsAt, response: httpResponse, now: now())
                )
            }
            return .unavailable
        } catch {
            return Task.isCancelled || error is CancellationError ? .cancelled : .unavailable
        }
    }

    private static func retryDate(resetsAt: String?, response: HTTPURLResponse, now: Date) -> Date {
        let reference = httpDate(response.value(forHTTPHeaderField: Constants.API.SessionToken.serverDateHeader)) ?? now
        var delay = isoDate(resetsAt)?.timeIntervalSince(reference) ?? 0
        if !delay.isFinite || delay <= 0 {
            let retryAfter = response.value(forHTTPHeaderField: Constants.API.SessionToken.retryAfterHeader)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let retryAfter, !retryAfter.isEmpty, retryAfter.allSatisfy(\.isNumber) {
                delay = TimeInterval(retryAfter) ?? 0
            } else {
                delay = httpDate(retryAfter)?.timeIntervalSince(reference) ?? 0
            }
        }
        let seconds: TimeInterval
        if delay.isFinite, delay > 0 {
            seconds = min(delay, Constants.API.SessionToken.maximumCooldownSeconds)
        } else {
            seconds = Constants.API.SessionToken.rateLimitFallbackSeconds
        }
        return now.addingTimeInterval(seconds)
    }

    private static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func httpDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Constants.API.SessionToken.httpDateLocale)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = Constants.API.SessionToken.httpDateFormat
        return formatter.date(from: value)
    }
}
