import Foundation
import os

enum PerformancePhase: String, CaseIterable, Sendable {
    case remoteConfigLoad
    case chatIndexLoad
    case fullChatLoad
    case cloudSyncCycle
    case firstChatPageLoad
    case streamSnapshotBuild
    case selectedChatImageHydration
}

struct PerformanceIntervalToken: Hashable, Sendable {
    fileprivate let id: UUID?
    let phase: PerformancePhase
}

protocol PerformanceInstrumentationSink: AnyObject, Sendable {
    var isEnabled: Bool { get }
    func begin(_ token: PerformanceIntervalToken)
    func end(_ token: PerformanceIntervalToken)
}

final class PerformanceInstrumentation: @unchecked Sendable {
    static let shared = PerformanceInstrumentation(sink: PointsOfInterestSignpostSink())

    private let sink: any PerformanceInstrumentationSink
    private let lock = NSLock()
    private var activeTokenIds: Set<UUID> = []

    init(sink: any PerformanceInstrumentationSink) {
        self.sink = sink
    }

    @discardableResult
    func begin(_ phase: PerformancePhase) -> PerformanceIntervalToken {
        guard sink.isEnabled else {
            return PerformanceIntervalToken(id: nil, phase: phase)
        }
        let token = PerformanceIntervalToken(id: UUID(), phase: phase)
        guard let tokenId = token.id else { return token }
        lock.lock()
        activeTokenIds.insert(tokenId)
        lock.unlock()
        sink.begin(token)
        return token
    }

    func end(_ token: PerformanceIntervalToken) {
        guard let tokenId = token.id else { return }
        lock.lock()
        let wasActive = activeTokenIds.remove(tokenId) != nil
        lock.unlock()
        guard wasActive else { return }
        sink.end(token)
    }

    func measure<Result>(
        _ phase: PerformancePhase,
        operation: () throws -> Result
    ) rethrows -> Result {
        let token = begin(phase)
        defer { end(token) }
        return try operation()
    }
}

private final class PointsOfInterestSignpostSink: PerformanceInstrumentationSink, @unchecked Sendable {
    private let signposter = OSSignposter(
        logHandle: OSLog(
            subsystem: Bundle.main.bundleIdentifier ?? "com.tinfoil.chat",
            category: .pointsOfInterest
        )
    )
    private let lock = NSLock()
    private var states: [UUID: OSSignpostIntervalState] = [:]

    var isEnabled: Bool {
        signposter.isEnabled
    }

    func begin(_ token: PerformanceIntervalToken) {
        let state = beginInterval(token.phase)
        guard let tokenId = token.id else { return }
        lock.lock()
        states[tokenId] = state
        lock.unlock()
    }

    func end(_ token: PerformanceIntervalToken) {
        guard let tokenId = token.id else { return }
        lock.lock()
        let state = states.removeValue(forKey: tokenId)
        lock.unlock()
        guard let state else { return }
        endInterval(token.phase, state: state)
    }

    private func beginInterval(_ phase: PerformancePhase) -> OSSignpostIntervalState {
        let signpostID = signposter.makeSignpostID()
        switch phase {
        case .remoteConfigLoad:
            return signposter.beginInterval("remoteConfigLoad", id: signpostID)
        case .chatIndexLoad:
            return signposter.beginInterval("chatIndexLoad", id: signpostID)
        case .fullChatLoad:
            return signposter.beginInterval("fullChatLoad", id: signpostID)
        case .cloudSyncCycle:
            return signposter.beginInterval("cloudSyncCycle", id: signpostID)
        case .firstChatPageLoad:
            return signposter.beginInterval("firstChatPageLoad", id: signpostID)
        case .streamSnapshotBuild:
            return signposter.beginInterval("streamSnapshotBuild", id: signpostID)
        case .selectedChatImageHydration:
            return signposter.beginInterval("selectedChatImageHydration", id: signpostID)
        }
    }

    private func endInterval(
        _ phase: PerformancePhase,
        state: OSSignpostIntervalState
    ) {
        switch phase {
        case .remoteConfigLoad:
            signposter.endInterval("remoteConfigLoad", state)
        case .chatIndexLoad:
            signposter.endInterval("chatIndexLoad", state)
        case .fullChatLoad:
            signposter.endInterval("fullChatLoad", state)
        case .cloudSyncCycle:
            signposter.endInterval("cloudSyncCycle", state)
        case .firstChatPageLoad:
            signposter.endInterval("firstChatPageLoad", state)
        case .streamSnapshotBuild:
            signposter.endInterval("streamSnapshotBuild", state)
        case .selectedChatImageHydration:
            signposter.endInterval("selectedChatImageHydration", state)
        }
    }
}
