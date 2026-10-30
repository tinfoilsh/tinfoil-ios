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

@Suite("Run controller")
@MainActor
struct RunControllerTests {
    private static let frames: [[String: Any]] = [
        ["type": "RUN_STARTED", "timestamp": "2026-01-01T00:00:00Z", "threadId": "t", "runId": "run_1", "instance": "i"],
        ["type": "TEXT_MESSAGE_CHUNK", "timestamp": "2026-01-01T00:00:01Z", "messageId": "msg_1", "role": "assistant", "delta": "Hel"],
    ]

    /// A controller for a signed-out account whose requests go to transport.
    private static func controller(_ transport: ScriptedTransport) -> RunController {
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
        return RunController(account: account, receipts: nil)
    }

    @Test func aDeviceRunTheViewLeftRejoinsAfterTheLastFrameItApplied() async throws {
        // Each stream closes before its run ends, as a dropped connection does.
        let transport = ScriptedTransport([Answers.events(Self.frames), Answers.events(Self.frames)])
        let controller = Self.controller(transport)
        let run = DeviceRun(threadId: "t", store: DeviceThreadStore(directory: nil), since: 0)
        let turn = Turn(clientRequestId: UUID().uuidString.lowercased(), threadId: "t", local: true, content: "Hello")
        // The view shows another chat than the one the run was started for.
        let left = RunOptions(device: run, version: -1)

        let finished = await controller.run(.turn, .turn(turn), options: left)

        #expect(!finished)
        let requests = await transport.requests
        #expect(requests.map(\.route) == [.turn, .follow])
        #expect(requests.last?.headers[HarnessHeader.lastEventId] == "1")
    }

    @Test func aRunThatCouldNotBeReachedIsFollowedOnceMore() async throws {
        let transport = ScriptedTransport([
            { _ in throw HarnessError(HarnessErrorBody.unreachable, urlErrorCode: .networkConnectionLost) },
            Answers.events(Self.frames),
        ])
        let controller = Self.controller(transport)
        let run = DeviceRun(threadId: "t", store: DeviceThreadStore(directory: nil), since: 0)

        _ = await controller.run(.follow, RunBody(key: nil, threadId: "t", runId: "run_1"), options: RunOptions(device: run, version: -1))

        #expect(await transport.requests.map(\.route) == [.follow, .follow])
    }
}
