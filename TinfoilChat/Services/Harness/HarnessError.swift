import Foundation

/// Why a request or run failed: as the harness reports it, or as this client
/// met it on its own. A client may handle a code it knows in its own way,
/// and handles every other code by its action.
struct HarnessErrorBody: Equatable, Sendable {
    var code: String
    var message: String
    var action: ErrorAction
    /// For QUOTA_EXHAUSTED, the kind of quota: free_daily or hourly.
    var kind: String?
    /// Seconds to wait before retrying.
    var retryAfter: Int?
    var resetsAt: String?
    /// The status a downstream service answered with.
    var status: Int?
    /// For KEY_MISMATCH, the id of the key the stored data uses.
    var keyId: String?
    /// For a document that failed to convert, the converter's code.
    var upstreamCode: String?
    var rateLimit: HarnessRateLimit?

    init(
        code: String,
        message: String,
        action: ErrorAction,
        kind: String? = nil,
        retryAfter: Int? = nil,
        resetsAt: String? = nil,
        status: Int? = nil,
        keyId: String? = nil,
        upstreamCode: String? = nil,
        rateLimit: HarnessRateLimit? = nil
    ) {
        self.code = code
        self.message = message
        self.action = action
        self.kind = kind
        self.retryAfter = retryAfter
        self.resetsAt = resetsAt
        self.status = status
        self.keyId = keyId
        self.upstreamCode = upstreamCode
        self.rateLimit = rateLimit
    }

    /// Why a request failed when the harness's answer to it is not one the
    /// protocol allows.
    static let invalidResponse = HarnessErrorBody(
        code: HarnessErrorCode.invalidResponse,
        message: "The chat service sent a response this client cannot read.",
        action: .stop
    )

    /// A reply the open chat ends on that did not finish, or that a turn left
    /// unanswered. Retrying asks the harness for it again.
    static let unfinishedReply = HarnessErrorBody(
        code: HarnessErrorCode.unfinishedReply,
        message: "",
        action: .retry
    )

    /// Why a request failed when the chat service could not be reached, or
    /// stopped answering: whether the request took effect is unknown.
    static let unreachable = HarnessErrorBody(
        code: HarnessErrorCode.connection,
        message: "The chat service could not be reached. Check your connection and try again.",
        action: .retry
    )

    /// Why a request failed when its answer did not come from the harness:
    /// an answer the enclave did not seal, a refusal or not, says nothing
    /// this client may show or act on, and whether the request took effect
    /// is unknown, as when the connection drops.
    static let unsealedAnswer = unreachable

    /// Why a request failed when the enclave could not be verified: it was
    /// not sent.
    static let unverified = HarnessErrorBody(
        code: HarnessErrorCode.attestation,
        message: "The chat service could not be verified, so nothing was sent.",
        action: .retry
    )
}

extension HarnessErrorBody: Decodable {
    private enum CodingKeys: String, CodingKey {
        case code, message, action, kind, retryAfter, resetsAt, status, keyId, upstreamCode, rateLimit
    }

    /// Reads an error as the harness sends it. One without the code, message
    /// and action the protocol requires is not one the client can read; a
    /// code or action this client does not know is kept, and handled by its
    /// action.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        action = ErrorAction.of(try container.decode(String.self, forKey: .action))
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        retryAfter = try container.decodeIfPresent(Int.self, forKey: .retryAfter)
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId)
        upstreamCode = try container.decodeIfPresent(String.self, forKey: .upstreamCode)
        rateLimit = try container.decodeIfPresent(HarnessRateLimit.self, forKey: .rateLimit)
    }
}

/// A request or run the harness refused, or one this client could not
/// complete, with the HTTP status of a refusal.
struct HarnessError: Error, Equatable {
    let detail: HarnessErrorBody
    let status: Int?

    init(_ detail: HarnessErrorBody, status: Int? = nil) {
        self.detail = detail
        self.status = status
    }

    init(code: String, message: String, action: ErrorAction, status: Int? = nil) {
        self.init(HarnessErrorBody(code: code, message: message, action: action), status: status)
    }

    var code: String { detail.code }
    var action: ErrorAction { detail.action }

    static let invalidResponse = HarnessError(HarnessErrorBody.invalidResponse)

    static func invalidStream(_ message: String) -> HarnessError {
        HarnessError(code: HarnessErrorCode.invalidStream, message: message, action: .stop)
    }

    static let streamInterrupted = HarnessError(
        code: HarnessErrorCode.streamInterrupted,
        message: "The connection closed. Reconnect to continue this run.",
        action: .retry
    )

    static let unauthenticated = HarnessError(
        code: HarnessErrorCode.unauthenticated,
        message: "Sign in again to continue.",
        action: .reauthenticate,
        status: 401
    )
}

extension HarnessError: LocalizedError {
    var errorDescription: String? { detail.message }
}
