import Foundation
import Testing
@testable import TinfoilChat

/// A control plane that issues one free key.
private struct FreeKeyControlPlane: ControlPlaneTransport {
    func get(_ path: String, identity: String?) async throws -> ControlPlaneAnswer {
        let body = #"{"key":"free_test","is_free_tier":true,"expires_at":"2999-01-01T00:00:00Z"}"#
        return ControlPlaneAnswer(status: 200, headers: [:], body: Data(body.utf8))
    }
}

/// The answer of a chat service that cannot be reached.
private let unreachable: ScriptedTransport.Answer = { _ in
    throw HarnessError(HarnessErrorBody.unreachable, urlErrorCode: .networkConnectionLost)
}

/// The waits a controller takes before rejoining a run, which pass at once,
/// and what the test does as each one starts.
@MainActor
private final class Waits {
    private(set) var seconds: [TimeInterval] = []
    var onWait: (() -> Void)?

    func wait(_ seconds: TimeInterval) {
        self.seconds.append(seconds)
        onWait?()
    }
}

@Suite("Run controller")
@MainActor
struct RunControllerTests {
    private static let frames: [[String: Any]] = [
        ["type": "RUN_STARTED", "timestamp": "2026-01-01T00:00:00Z", "threadId": "t", "runId": "run_1", "instance": "i"],
        ["type": "TEXT_MESSAGE_CHUNK", "timestamp": "2026-01-01T00:00:01Z", "messageId": "msg_1", "role": "assistant", "delta": "Hel"],
    ]
    /// The run's frames through its end.
    private static let finished = frames + [
        ["type": "RUN_FINISHED", "timestamp": "2026-01-01T00:00:02Z", "threadId": "t", "runId": "run_1", "metadata": [:]],
    ]

    /// A controller for a signed-out account whose requests go to transport,
    /// and whose waits before rejoining a run go to waits.
    private static func controller(_ transport: ScriptedTransport, waits: Waits = Waits()) -> RunController {
        let controlPlane = FreeKeyControlPlane()
        let credentials = HarnessCredentialProvider(
            identity: { _ in nil },
            chatAccess: ChatAccessCache(controlPlane: controlPlane) { _ in },
            anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
        )
        let account = HarnessAccount(
            userId: nil,
            client: HarnessClient(credentials: credentials, transport: transport, languages: { ["en"] }),
            credentials: credentials,
            keyBytes: { nil },
            settings: MemoryProfileStorage(),
            cloudSync: false
        )
        return RunController(account: account, receipts: nil) { waits.wait($0) }
    }

    private static func turn() -> Turn {
        Turn(clientRequestId: UUID().uuidString.lowercased(), threadId: "t", local: true, content: "Hello")
    }

    @Test func aDeviceRunTheViewLeftRejoinsAfterTheLastFrameItApplied() async throws {
        // The turn's stream closes before its run ends, as a dropped
        // connection does; the harness then replays the run through its end.
        let transport = ScriptedTransport([Answers.events(Self.frames), Answers.events(Self.finished)])
        let controller = Self.controller(transport)
        let run = DeviceRun(threadId: "t", store: DeviceThreadStore(directory: nil), since: 0)
        // The view shows another chat than the one the run was started for.
        let left = RunOptions(device: run, version: -1)

        let finished = await controller.run(.turn, .turn(Self.turn()), options: left)

        #expect(!finished)
        let requests = await transport.requests
        #expect(requests.map(\.route) == [.turn, .follow])
        #expect(requests.last?.headers[HarnessHeader.lastEventId] == "1")
    }

    @Test func aRunThatCouldNotBeReachedIsFollowedAgainAtOnce() async throws {
        let waits = Waits()
        let transport = ScriptedTransport([unreachable, Answers.events(Self.finished)])
        let controller = Self.controller(transport, waits: waits)
        let run = DeviceRun(threadId: "t", store: DeviceThreadStore(directory: nil), since: 0)

        _ = await controller.run(.follow, RunBody(key: nil, threadId: "t", runId: "run_1"), options: RunOptions(device: run, version: -1))

        #expect(await transport.requests.map(\.route) == [.follow, .follow])
        #expect(waits.seconds.isEmpty)
    }

    @Test func eachAttemptToRejoinThatReachesNothingWaitsLongerUntilTheHarnessAnswers() async throws {
        let waits = Waits()
        let transport = ScriptedTransport([
            Answers.events(Self.frames), unreachable, unreachable, unreachable, Answers.events(Self.finished),
        ])
        let controller = Self.controller(transport, waits: waits)

        let finished = await controller.run(.turn, .turn(Self.turn()))

        #expect(finished)
        let requests = await transport.requests
        #expect(requests.map(\.route) == [.turn, .follow, .follow, .follow, .follow])
        #expect(requests.dropFirst().allSatisfy { $0.headers[HarnessHeader.lastEventId] == "1" })
        // The first attempt goes at once.
        #expect(waits.seconds == [1, 2, 4])
        #expect(controller.view.status == .idle)
        #expect(controller.view.error == nil)
    }

    @Test func aRunTheHarnessStaysOutOfReachForFailsOnceEveryAttemptToRejoinItHas() async throws {
        let waits = Waits()
        let delays = Constants.Harness.rejoinDelaysSeconds
        let transport = ScriptedTransport([Answers.events(Self.frames)] + Array(repeating: unreachable, count: delays.count))
        let controller = Self.controller(transport, waits: waits)

        let finished = await controller.run(.turn, .turn(Self.turn()))

        #expect(!finished)
        #expect(await transport.requests.count == 1 + delays.count)
        #expect(waits.seconds == delays.filter { $0 > 0 })
        #expect(controller.view.status == .error)
        #expect(controller.view.error?.code == HarnessErrorBody.unreachable.code)
    }

    @Test func aDeviceRunWaitingToBeRejoinedStillShowsAsRunning() async throws {
        let waits = Waits()
        let transport = ScriptedTransport([Answers.events(Self.frames), unreachable, Answers.events(Self.finished)])
        let controller = Self.controller(transport, waits: waits)
        let run = DeviceRun(threadId: "t", store: DeviceThreadStore(directory: nil), since: 0)
        var shownRunning: Bool?
        waits.onWait = { shownRunning = controller.deviceRuns["t"] === run }

        _ = await controller.run(.turn, .turn(Self.turn()), options: RunOptions(device: run))

        #expect(waits.seconds == [1])
        #expect(shownRunning == true)
        #expect(controller.deviceRuns["t"] == nil)
    }

    @Test func aRunStopsBeingRejoinedOnceTheViewMovesToAnotherChat() async throws {
        let waits = Waits()
        let transport = ScriptedTransport([Answers.events(Self.frames), unreachable])
        let controller = Self.controller(transport, waits: waits)
        // The user opens another chat while the run waits to be rejoined.
        waits.onWait = { controller.reset() }

        let finished = await controller.run(.turn, .turn(Self.turn()))

        #expect(!finished)
        #expect(await transport.requests.map(\.route) == [.turn, .follow])
        #expect(waits.seconds == [1])
    }

    @Test func aTurnWhoseConnectionWasLostGoesOnceMoreWithItsNonce() async throws {
        let transport = ScriptedTransport([unreachable, Answers.events(Self.finished)])
        let controller = Self.controller(transport)
        let turn = Self.turn()

        let finished = await controller.run(.turn, .turn(turn))

        #expect(finished)
        let requests = await transport.requests
        #expect(requests.map(\.route) == [.turn, .turn])
        #expect(requests.map { $0.json["clientRequestId"] as? String } == [turn.clientRequestId, turn.clientRequestId])
        #expect(controller.view.status == .idle)
        #expect(controller.view.error == nil)
    }

    @Test func aTurnWhoseConnectionIsLostAgainFails() async throws {
        let transport = ScriptedTransport([unreachable, unreachable])
        let controller = Self.controller(transport)

        let finished = await controller.run(.turn, .turn(Self.turn()))

        #expect(!finished)
        #expect(await transport.requests.count == 2)
        #expect(controller.view.status == .error)
        #expect(controller.view.error?.code == HarnessErrorBody.unreachable.code)
    }

    @Test(arguments: [false, true])
    func aTurnThatFailedOtherwiseIsNotSentAgain(answered: Bool) async throws {
        // The harness answered, then the stream broke before the run started,
        // or the request could not leave the device.
        let offline: ScriptedTransport.Answer = { _ in
            throw HarnessError(HarnessErrorBody.unreachable, urlErrorCode: .notConnectedToInternet)
        }
        let transport = ScriptedTransport([answered ? Answers.events([]) : offline])
        let controller = Self.controller(transport)

        let finished = await controller.run(.turn, .turn(Self.turn()))

        #expect(!finished)
        #expect(await transport.requests.count == 1)
        #expect(controller.view.status == .error)
    }
}
