import Foundation

// The harness's wire types, as harness-protocol/openapi.yaml describes them
// and Protocol/Schemas.swift generates them, under the names this client uses.
typealias HarnessEvent = Components.Schemas.HarnessEvent
typealias HarnessMessage = Components.Schemas.MessageView
typealias TimelineBlock = Components.Schemas.Block
typealias ThreadSummary = Components.Schemas.ThreadSummary
typealias QueueItem = Components.Schemas.QueueItem
typealias HarnessRateLimit = Components.Schemas.RateLimit
/// How a content key came to be registered.
typealias KeyOrigin = Components.Schemas.KeyOrigin
/// A passkey bundle as it is registered: the key wrapped under the
/// passkey's PRF output.
typealias KeyBundleInput = Components.Schemas.KeyBundleInput
typealias ErrorAction = Components.Schemas.ErrorAction
typealias ToolActivity = Components.Schemas.ToolActivity
typealias CommittedReply = Components.Schemas.CommittedReply
typealias HarnessSession = Components.Schemas.Session
typealias ThreadWindow = Components.Schemas.ThreadWindow

/// The harness's routes. Every one is a POST.
enum HarnessRoute: String, CaseIterable, Sendable {
    case session = "/v1/session"
    case changes = "/v1/changes"
    case profileGet = "/v1/profile/get"
    case profileUpdate = "/v1/profile/update"
    case profileUpgrade = "/v1/profile/upgrade"
    case profileMerge = "/v1/profile/merge"
    case keysCurrent = "/v1/keys/current"
    case keysRegister = "/v1/keys/register"
    case keysAddBundle = "/v1/keys/add-bundle"
    case keysRemoveBundle = "/v1/keys/remove-bundle"
    case keysMigrateAll = "/v1/keys/migrate-all"
    case turn = "/v1/threads/turn"
    case follow = "/v1/threads/follow"
    case cancel = "/v1/threads/cancel"
    case queueSend = "/v1/threads/queue/send"
    case queueRemove = "/v1/threads/queue/remove"
    case list = "/v1/threads/list"
    case search = "/v1/threads/search"
    case get = "/v1/threads/get"
    case update = "/v1/threads/update"
    case delete = "/v1/threads/delete"
    case deleteAll = "/v1/threads/delete-all"
    case fork = "/v1/threads/fork"
    case messageDelete = "/v1/threads/messages/delete"
    case messageUpdate = "/v1/threads/messages/update"
    case share = "/v1/threads/share"
    case shareStatus = "/v1/threads/share/status"
    case shareRevoke = "/v1/threads/share/revoke"
    case shareOpen = "/v1/shares/open"
    case transcript = "/v1/threads/transcript"
    case threadImport = "/v1/threads/import"
    case upgrade = "/v1/threads/upgrade"
    case attachmentUpload = "/v1/attachments/upload"
    case attachmentGet = "/v1/attachments/get"
    case attachmentGetPublic = "/v1/attachments/get-public"
    case projectsList = "/v1/projects/list"
    case projectsGet = "/v1/projects/get"
    case projectsCreate = "/v1/projects/create"
    case projectsUpdate = "/v1/projects/update"
    case projectsDelete = "/v1/projects/delete"
    case projectsDeleteAll = "/v1/projects/delete-all"
    case projectDocumentUpload = "/v1/projects/documents/upload"
    case projectDocumentDelete = "/v1/projects/documents/delete"
    case favicon = "/v1/metadata/favicon"
    case linkMetadata = "/v1/metadata/link"
    case speech = "/v1/speech"
    case transcriptions = "/v1/transcriptions"
    case export = "/v1/export"
    case `import` = "/v1/import"
    case importStatus = "/v1/import/status"

    /// A run's stream: a turn starts one, and following one replays it.
    var startsStream: Bool { self == .turn || self == .follow }

    /// The routes about a chat's run, which go to the instance holding it.
    var aboutRun: Bool {
        switch self {
        case .follow, .cancel, .queueSend, .queueRemove: return true
        default: return false
        }
    }
}

/// The events of a run's stream. A frame of another type is one a later
/// harness added, which this client ignores.
enum HarnessEventType: String, CaseIterable, Sendable {
    case runStarted = "RUN_STARTED"
    case messagesSnapshot = "MESSAGES_SNAPSHOT"
    case stateSnapshot = "STATE_SNAPSHOT"
    case stateDelta = "STATE_DELTA"
    case textMessageChunk = "TEXT_MESSAGE_CHUNK"
    case reasoningMessageChunk = "REASONING_MESSAGE_CHUNK"
    case reasoningSummary = "REASONING_SUMMARY"
    case toolCallStart = "TOOL_CALL_START"
    case toolCallArgs = "TOOL_CALL_ARGS"
    case toolCallEnd = "TOOL_CALL_END"
    case toolCallResult = "TOOL_CALL_RESULT"
    case activitySnapshot = "ACTIVITY_SNAPSHOT"
    case activityDelta = "ACTIVITY_DELTA"
    case runFinished = "RUN_FINISHED"
    case runError = "RUN_ERROR"
}

/// The headers a request says more in than who is asking.
enum HarnessHeader {
    /// Carries a signed-in account's chat access, which the harness checks
    /// before it reads a request's body.
    static let inferenceKey = "X-Tinfoil-Inference-Key"
    /// Names the harness instance holding a run, so a request about the run
    /// can be routed to it.
    static let instance = "X-Tinfoil-Harness-Instance"
    /// Names the last event of a run a client applied, which following the
    /// run resumes after.
    static let lastEventId = "Last-Event-ID"
}

/// Every widget the harness declares is named with this prefix.
let harnessWidgetPrefix = "render_"

/// The error codes this client acts on by name. Every other code is handled
/// by its action.
enum HarnessErrorCode {
    /// The harness had applied a turn sent again.
    static let alreadyApplied = "ALREADY_APPLIED"
    /// The run is not live on the instance that answered.
    static let runNotFound = "RUN_NOT_FOUND"
    static let runInFlight = "RUN_IN_FLIGHT"
    static let quotaExhausted = "QUOTA_EXHAUSTED"
    static let rateLimited = "RATE_LIMITED"
    static let keyRequired = "KEY_REQUIRED"
    static let keyMismatch = "KEY_MISMATCH"
    static let unauthenticated = "UNAUTHENTICATED"
    static let badRequest = "BAD_REQUEST"
    static let threadNotFound = "THREAD_NOT_FOUND"
    static let threadExists = "THREAD_EXISTS"
    /// The chat changed while a run that edits it in place ran.
    static let revisionConflict = "REVISION_CONFLICT"
    static let toolUnavailable = "TOOL_UNAVAILABLE"
    /// The safeguards flagged the chat, which takes no more turns.
    static let chatFlagged = "CHAT_FLAGGED"
    static let queueFull = "QUEUE_FULL"
    /// The turn does not fit the model's context window.
    static let contextTooLarge = "CONTEXT_TOO_LARGE"
    /// The chat is too large to store.
    static let threadTooLarge = "THREAD_TOO_LARGE"
    static let modelUnavailable = "MODEL_UNAVAILABLE"
    /// The chats could not be indexed for search.
    static let searchIndexFailed = "SEARCH_INDEX_FAILED"
    static let upstreamRefused = "UPSTREAM_REFUSED"
    /// The request needs the chat access the client mints, which it lacked
    /// or which expired.
    static let credentialRequired = "CREDENTIAL_REQUIRED"

    // The codes of errors this client meets on its own, which the harness
    // never sends.
    static let configuration = "CONFIGURATION"
    static let connection = "CONNECTION"
    static let invalidStream = "INVALID_STREAM"
    /// A refusal or a run's error without the members the protocol requires
    /// of it.
    static let invalidResponse = "INVALID_RESPONSE"
    /// A stream that closed before its run ended. The run may go on.
    static let streamInterrupted = "STREAM_INTERRUPTED"
    /// A reply this device could not store.
    static let localSaveFailed = "LOCAL_SAVE_FAILED"
    /// The chat ends on a reply that did not finish or on a message no reply
    /// answers.
    static let unfinishedReply = "UNFINISHED_REPLY"
}

extension ErrorAction {
    /// The action an error asks for. One this client does not know, as a
    /// later harness may ask for, fails the request: the client shows the
    /// error and offers nothing more.
    static func of(_ action: String) -> ErrorAction {
        ErrorAction(rawValue: action) ?? .stop
    }
}
