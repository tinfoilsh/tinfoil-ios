import AVFoundation
import Foundation

@MainActor
final class AudioSessionCoordinator {
    enum Activity: Equatable, Sendable {
        case speech
        case recording
        case alarm
    }

    static let shared = AudioSessionCoordinator()

    private struct Owner {
        let activity: Activity
        let interrupt: @MainActor () -> Void
    }

    private var owners: [UUID: Owner] = [:]
    private var configuredActivity: Activity?
    private let configure: @MainActor (Activity?) throws -> Void

    init(configure: (@MainActor (Activity?) throws -> Void)? = nil) {
        self.configure = configure ?? Self.configureSession
    }

    func acquire(_ activity: Activity, onInterruption: @escaping @MainActor () -> Void = {}) throws -> UUID {
        if activity == .speech, owners.values.contains(where: { $0.activity != .speech }) {
            throw SpeechError.audioBusy
        }
        // Stop narration before configuring another activity's session. Its
        // release cannot subsequently deactivate the new owner's session.
        let narrationOwners = owners.filter { $0.value.activity == .speech }
        for (id, owner) in narrationOwners {
            owner.interrupt()
            owners.removeValue(forKey: id)
        }
        let id = UUID()
        let needsActivation = owners.isEmpty
        owners[id] = Owner(activity: activity, interrupt: onInterruption)
        do {
            try updateConfiguration(force: needsActivation)
            return id
        } catch {
            owners.removeValue(forKey: id)
            try? updateConfiguration(force: true)
            throw error
        }
    }

    func release(_ id: UUID) {
        guard owners.removeValue(forKey: id) != nil else { return }
        try? updateConfiguration()
    }

    private func updateConfiguration(force: Bool = false) throws {
        let activities = owners.values.map(\.activity)
        let activity: Activity? = activities.contains(.recording) ? .recording
            : activities.contains(.alarm) ? .alarm
            : activities.contains(.speech) ? .speech : nil
        guard force || activity != configuredActivity else { return }
        configuredActivity = nil
        try configure(activity)
        configuredActivity = activity
    }

    private static func configureSession(_ activity: Activity?) throws {
        let session = AVAudioSession.sharedInstance()
        switch activity {
        case .speech:
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .recording:
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        case .alarm:
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        case nil:
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            return
        }
        try session.setActive(true)
    }
}
