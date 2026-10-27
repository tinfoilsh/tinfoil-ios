import Foundation
import Testing
import TinfoilAI
@testable import TinfoilChat

/// A transport that answers from a script and keeps what it was sent.
actor ScriptedTransport: HarnessTransport {
    typealias Answer = @Sendable (HarnessRequest) -> HarnessResponse

    private(set) var requests: [HarnessRequest] = []
    private var answers: [Answer]
    private var holding = false
    private var held = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    /// Scripts the next answer.
    func push(_ answer: @escaping Answer) {
        answers.append(answer)
    }

    /// Holds the requests that follow in flight until released, so a test
    /// can look at what shows while one is.
    func hold() {
        holding = true
    }

    /// Waits for a held request to arrive.
    func arrived() async {
        if held { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        holding = false
        releases.forEach { $0.resume() }
        releases = []
    }

    func send(_ request: HarnessRequest) async throws -> HarnessResponse {
        requests.append(request)
        if holding {
            held = true
            arrivals.forEach { $0.resume() }
            arrivals = []
            await withCheckedContinuation { releases.append($0) }
            held = false
        }
        guard !answers.isEmpty else {
            Issue.record("unscripted request to \(request.route.rawValue)")
            throw HarnessError(code: HarnessErrorCode.connection, message: "unscripted", action: .stop)
        }
        return answers.removeFirst()(request)
    }

    func verification() async -> Verification? { nil }
}

actor ScriptedCredentials: HarnessCredentials {
    enum Call: Equatable { case identity(refresh: Bool), anonymousKey(refresh: Bool), chatAccess(identity: String, refresh: Bool) }

    private(set) var calls: [Call] = []
    var identities: [String?]
    var anonymousKeys: [String]
    var access: [Result<String, HarnessError>]
    var renewsAt: Date?

    init(identities: [String?] = [], anonymousKeys: [String] = [], access: [Result<String, HarnessError>] = []) {
        self.identities = identities
        self.anonymousKeys = anonymousKeys
        self.access = access
    }

    func identity(refresh: Bool) async throws -> String? {
        calls.append(.identity(refresh: refresh))
        return identities.isEmpty ? nil : identities.removeFirst()
    }

    func anonymousKey(refresh: Bool) async throws -> String {
        calls.append(.anonymousKey(refresh: refresh))
        guard !anonymousKeys.isEmpty else {
            Issue.record("unscripted free key request")
            throw HarnessError(code: HarnessErrorCode.connection, message: "unscripted", action: .stop)
        }
        return anonymousKeys.removeFirst()
    }

    func chatAccess(identity: String, refresh: Bool) async throws -> String {
        calls.append(.chatAccess(identity: identity, refresh: refresh))
        guard !access.isEmpty else {
            Issue.record("unscripted chat access request")
            throw HarnessError(code: HarnessErrorCode.connection, message: "unscripted", action: .stop)
        }
        return try access.removeFirst().get()
    }

    func chatAccessRenewsAt() async -> Date? { renewsAt }
}


/// The settings a test account keeps, in memory.
final class MemoryProfileStorage: ProfileStorage, @unchecked Sendable {
    var local: ProfileFields = [:]
    var changes: Set<String> = []
    var localProfileUpgraded = false
    var pendingProfileMerge: String?
    var cloudCache: [String: ProfileFields] = [:]

    func loadLocalProfile() -> ProfileFields { local }

    func saveLocalProfile(_ patch: ProfileFields, replace: Bool) throws -> ProfileFields {
        var profile = replace ? [:] : local
        profile.merge(patch) { $1 }
        profile = profile.filter { !($0.value is NSNull) }
        local = profile
        if !replace { changes.formUnion(patch.keys) }
        return profile
    }

    func localProfileChanges() -> [String] { changes.sorted() }
    func clearLocalProfileChanges() { changes = [] }
    func cloudProfileCache(userId: String?) -> ProfileFields { userId.flatMap { cloudCache[$0] } ?? [:] }
    func saveCloudProfileCache(_ profile: ProfileFields, userId: String?) { if let userId { cloudCache[userId] = profile } }
    func clearCloudProfileCache(userId: String?) { if let userId { cloudCache[userId] = nil } }
}

/// The JSON answers a scripted transport gives.
enum Answers {
    static func json(_ status: Int, _ body: String) -> ScriptedTransport.Answer {
        { _ in .collected(status: status, headers: ["content-type": "application/json"], body: Data(body.utf8)) }
    }

    static func json(_ object: [String: Any]) -> ScriptedTransport.Answer {
        let body = try! JSONSerialization.data(withJSONObject: object)
        return { _ in .collected(status: 200, headers: ["content-type": "application/json"], body: body) }
    }

    static func events(_ frames: [[String: Any]]) -> ScriptedTransport.Answer {
        var text = ""
        for (index, frame) in frames.enumerated() {
            let data = try! JSONSerialization.data(withJSONObject: frame)
            text += "id: \(index)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        return { _ in .collected(status: 200, headers: ["content-type": "text/event-stream"], body: Data(text.utf8)) }
    }

    static func refusal(_ status: Int, code: String, action: String) -> ScriptedTransport.Answer {
        json(status, #"{"error":{"code":"\#(code)","message":"refused","action":"\#(action)"}}"#)
    }
}

extension HarnessRequest {
    /// The request's body as JSON.
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}
