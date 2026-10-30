import Foundation

/// How a failed turn's error card explains the chat service's error and what
/// it offers: by the error's code when this client knows it, otherwise by
/// the action the error asks for. The copy and the offered actions derive
/// from the same kind, so they never disagree. The service's own message is
/// for logs; the card shows it only as details.
struct StreamErrorPresentation: Equatable {
    enum Kind: Equatable {
        case connection, verification, auth, key, rateLimit, busy, queueFull, contextLength, tooLarge, model, document, server, storage, revise, refused, unfinished
    }

    let kind: Kind
    let title: String
    let suggestion: String
    /// The free daily quota, which a subscription lifts.
    let offersUpgrade: Bool
    /// When the error asks the client to wait before sending again, the
    /// seconds to wait from when it happened.
    let retryAfter: Int?

    /// Whether sending again may succeed. A refusal for an exhausted quota,
    /// the chat's size, a locked key, a document that failed to convert or
    /// the request itself fails the same way until that changes.
    var offersRetry: Bool {
        ![.rateLimit, .tooLarge, .contextLength, .key, .storage, .document, .revise, .refused].contains(kind)
    }

    /// Whether retrying sends the user's message again, as after a
    /// connection that failed before the service answered.
    var resends: Bool {
        [.connection, .verification, .busy, .queueFull].contains(kind)
    }

    var offersUnlock: Bool { kind == .key }

    init(_ error: HarnessErrorBody, occurredAt: Date?) {
        let classified = Self.classify(error, occurredAt: occurredAt)
        kind = classified.kind
        title = classified.title
        suggestion = classified.suggestion
        offersUpgrade = kind == .rateLimit && error.kind == Self.freeDailyQuota
        retryAfter = error.retryAfter
    }

    private init(_ kind: Kind, _ title: String, _ suggestion: String) {
        self.kind = kind
        self.title = title
        self.suggestion = suggestion
        offersUpgrade = false
        retryAfter = nil
    }

    private static let freeDailyQuota = "free_daily"
    private static let hourlyQuota = "hourly"
    private static let documentCodePrefix = "document_"
    private static let notLost = "Your message was not lost."

    private static let revise = StreamErrorPresentation(
        .revise, "This message cannot be sent as it is",
        "Change it, for example by removing an attachment or shortening it, then send it again. \(notLost)"
    )
    private static let refused = StreamErrorPresentation(
        .refused, "This request could not be completed", "Sending it again would not help. The details say why."
    )
    private static let auth = StreamErrorPresentation(
        .auth, "Unable to confirm your sign-in", "Sign in again, then resend your message. \(notLost)"
    )
    private static let key = StreamErrorPresentation(
        .key, "Your encryption key is locked", "Unlock it to keep chatting with cloud sync. \(notLost)"
    )
    private static let keyOutOfDate = StreamErrorPresentation(
        .key, "Your encryption key is out of date", "Recover your current key to keep chatting with cloud sync. \(notLost)"
    )
    private static let connection = StreamErrorPresentation(
        .connection, "Connection problem", "Check your internet connection, then resend your message. \(notLost)"
    )
    private static let verification = StreamErrorPresentation(
        .verification, "Unable to verify the chat service", "Nothing was sent. Resend your message in a moment. \(notLost)"
    )
    private static let rateLimit = StreamErrorPresentation(
        .rateLimit, "Usage limit reached", "Please wait for the limit to reset before trying again."
    )
    private static let busy = StreamErrorPresentation(
        .busy, "Too many requests right now", "Wait a moment, then resend your message. \(notLost)"
    )
    private static let queueFull = StreamErrorPresentation(
        .queueFull, "Too many messages are waiting in this chat", "Wait for a queued message to be sent, then resend yours. \(notLost)"
    )
    private static let tooLarge = StreamErrorPresentation(
        .tooLarge, "This chat is too large to save",
        "Start a new chat, or fork this one from an earlier message to continue with less history."
    )
    private static let model = StreamErrorPresentation(
        .model, "This model is unavailable right now", "Switch to another model, or try again in a moment."
    )
    private static let contextLength = StreamErrorPresentation(
        .contextLength, "This conversation is too long for the model",
        "Remove an attachment, shorten your message, or switch to a model with a larger context window."
    )
    private static let storage = StreamErrorPresentation(
        .storage, "This chat could not be saved on this device",
        "The reply arrived, but this device could not store it, so it may be missing when the chat is opened again."
    )
    private static let unfinished = StreamErrorPresentation(
        .unfinished, "This reply didn't finish", "Try again to get a complete reply."
    )
    private static let server = StreamErrorPresentation(
        .server, "The service is having trouble right now",
        "Our servers may be briefly overloaded. Please try again, or switch to a different model."
    )

    private static func classify(_ error: HarnessErrorBody, occurredAt: Date?) -> StreamErrorPresentation {
        // A document that failed to convert carries the document service's
        // fixed explanation, which describes nothing in the file.
        if error.upstreamCode?.hasPrefix(documentCodePrefix) == true {
            return error.code == HarnessErrorCode.rateLimited
                ? StreamErrorPresentation(.busy, "The document service is busy", busy.suggestion)
                : StreamErrorPresentation(.document, "A document could not be processed", error.message)
        }
        switch error.code {
        case HarnessErrorCode.unauthenticated: return auth
        case HarnessErrorCode.keyRequired: return key
        case HarnessErrorCode.keyMismatch: return keyOutOfDate
        case HarnessErrorCode.quotaExhausted: return quota(error, occurredAt: occurredAt)
        case HarnessErrorCode.rateLimited: return busy
        case HarnessErrorCode.queueFull: return queueFull
        case HarnessErrorCode.contextTooLarge: return contextLength
        case HarnessErrorCode.threadTooLarge: return tooLarge
        case HarnessErrorCode.modelUnavailable: return model
        case HarnessErrorCode.localSaveFailed: return storage
        case HarnessErrorCode.unfinishedReply: return unfinished
        case HarnessErrorCode.streamInterrupted, HarnessErrorCode.connection: return connection
        case HarnessErrorCode.attestation: return verification
        default: return byAction(error, occurredAt: occurredAt)
        }
    }

    /// A code this client has no copy for is explained by what its error
    /// asks the client to do.
    private static func byAction(_ error: HarnessErrorBody, occurredAt: Date?) -> StreamErrorPresentation {
        switch error.action {
        case .reauthenticate: return auth
        case .unlock: return key
        case .wait: return quota(error, occurredAt: occurredAt)
        case .revise: return revise
        case .stop: return refused
        default: return server
        }
    }

    private static func quota(_ error: HarnessErrorBody, occurredAt: Date?) -> StreamErrorPresentation {
        let resets = resetTime(error, occurredAt: occurredAt)
        switch error.kind {
        case hourlyQuota:
            return StreamErrorPresentation(
                .rateLimit, "Hourly usage limit reached",
                resets.map { "Your limit resets at \($0). \(notLost)" } ?? rateLimit.suggestion
            )
        case freeDailyQuota:
            return StreamErrorPresentation(
                .rateLimit, "Daily limit reached",
                "Upgrade to Premium to keep chatting\(resets.map { ", or try again after \($0)" } ?? "")."
            )
        default:
            return StreamErrorPresentation(
                .rateLimit, rateLimit.title,
                resets.map { "The limit resets at \($0). \(notLost)" } ?? rateLimit.suggestion
            )
        }
    }

    /// When the error says its limit resets, as a local time of day.
    private static func resetTime(_ error: HarnessErrorBody, occurredAt: Date?) -> String? {
        let at = error.resetsAt.flatMap(ChatAccessCache.date(of:))
            ?? error.retryAfter.map { (occurredAt ?? Date()).addingTimeInterval(TimeInterval($0)) }
        return at?.formatted(date: .omitted, time: .shortened)
    }
}
