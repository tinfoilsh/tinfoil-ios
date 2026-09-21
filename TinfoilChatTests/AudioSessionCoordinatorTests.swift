import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct AudioSessionCoordinatorTests {
    @Test
    func recordingStopsNarrationBeforeTakingOwnership() throws {
        var configured: [AudioSessionCoordinator.Activity?] = []
        let coordinator = AudioSessionCoordinator { configured.append($0) }
        var speechLease: UUID?
        var interrupted = false
        speechLease = try coordinator.acquire(.speech) {
            interrupted = true
            if let speechLease { coordinator.release(speechLease) }
        }
        let recording = try coordinator.acquire(.recording)
        #expect(interrupted)
        #expect(configured == [.speech, nil, .recording])
        coordinator.release(try #require(speechLease))
        #expect(configured.last == .some(.recording))
        coordinator.release(recording)
        #expect(configured.last == .some(nil))
    }

    @Test
    func aNewNarrationReplacesThePreviousSpeechOwner() throws {
        var configured: [AudioSessionCoordinator.Activity?] = []
        var interruptions = 0
        let coordinator = AudioSessionCoordinator { configured.append($0) }
        var first: UUID?
        first = try coordinator.acquire(.speech) {
            interruptions += 1
            if let first { coordinator.release(first) }
        }
        let second = try coordinator.acquire(.speech)
        #expect(interruptions == 1)
        #expect(configured == [.speech, nil, .speech])
        coordinator.release(try #require(first))
        #expect(configured == [.speech, nil, .speech])
        coordinator.release(second)
        #expect(configured == [.speech, nil, .speech, nil])
    }

    @Test
    func stoppingOneAlarmDoesNotDeactivateRecordingOrAnotherAlarm() throws {
        var configured: [AudioSessionCoordinator.Activity?] = []
        let coordinator = AudioSessionCoordinator { configured.append($0) }
        let first = try coordinator.acquire(.alarm)
        let second = try coordinator.acquire(.alarm)
        let recording = try coordinator.acquire(.recording)
        coordinator.release(first)
        #expect(configured == [.alarm, .recording])
        coordinator.release(recording)
        #expect(configured == [.alarm, .recording, .alarm])
        coordinator.release(second)
        #expect(configured.last == .some(nil))
    }

    @Test(arguments: [AudioSessionCoordinator.Activity.recording, .alarm])
    func narrationDoesNotTakeOverAnActiveInputOrAlarm(activity: AudioSessionCoordinator.Activity) throws {
        var configured: [AudioSessionCoordinator.Activity?] = []
        let coordinator = AudioSessionCoordinator { configured.append($0) }
        _ = try coordinator.acquire(activity)
        #expect(throws: SpeechError.audioBusy) { try coordinator.acquire(.speech) }
        #expect(configured == [activity])
    }

    @Test
    func failedActivationRestoresThePreviousAudioConfiguration() throws {
        var configured: [AudioSessionCoordinator.Activity?] = []
        let coordinator = AudioSessionCoordinator { activity in
            configured.append(activity)
            if activity == .recording { throw SpeechError.interrupted }
        }
        let alarm = try coordinator.acquire(.alarm)
        #expect(throws: SpeechError.interrupted) { try coordinator.acquire(.recording) }
        #expect(configured == [.alarm, .recording, .alarm])
        coordinator.release(alarm)
        #expect(configured.last == .some(nil))
    }

    @Test
    func anAcquisitionRecoversFromFailedDeactivation() throws {
        var configured: [AudioSessionCoordinator.Activity?] = []
        var failDeactivation = true
        let coordinator = AudioSessionCoordinator { activity in
            configured.append(activity)
            if activity == nil, failDeactivation {
                failDeactivation = false
                throw SpeechError.interrupted
            }
        }
        let first = try coordinator.acquire(.speech)
        coordinator.release(first)
        let second = try coordinator.acquire(.speech)
        coordinator.release(second)
        #expect(configured == [.speech, nil, .speech, nil])
    }

    @Test
    func anAcquisitionRetriesTheRemainingOwnersFailedConfiguration() throws {
        var configured: [AudioSessionCoordinator.Activity?] = []
        var failAlarmConfiguration = false
        let coordinator = AudioSessionCoordinator { activity in
            configured.append(activity)
            if activity == .alarm, failAlarmConfiguration {
                failAlarmConfiguration = false
                throw SpeechError.interrupted
            }
        }
        let alarm = try coordinator.acquire(.alarm)
        let recording = try coordinator.acquire(.recording)
        failAlarmConfiguration = true
        coordinator.release(recording)
        let nextAlarm = try coordinator.acquire(.alarm)
        #expect(configured == [.alarm, .recording, .alarm, .alarm])
        coordinator.release(alarm)
        coordinator.release(nextAlarm)
        #expect(configured.last == .some(nil))
    }
}
