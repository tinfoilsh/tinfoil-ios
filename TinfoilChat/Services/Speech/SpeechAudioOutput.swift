import AVFoundation
import Foundation

@MainActor
protocol SpeechAudioPlaying: AnyObject, Sendable {
    func prepare(onInterruption: @escaping @MainActor (SpeechError?) -> Void) throws
    func schedule(_ samples: [Float], completion: @escaping @MainActor @Sendable () -> Void) throws
    func play()
    func pause()
    func stop()
}

@MainActor
final class SpeechAudioOutput: SpeechAudioPlaying {
    private let coordinator: AudioSessionCoordinator
    private var lease: UUID?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []

    init(coordinator: AudioSessionCoordinator? = nil) {
        self.coordinator = coordinator ?? .shared
    }

    func prepare(onInterruption: @escaping @MainActor (SpeechError?) -> Void) throws {
        stop()
        lease = try coordinator.acquire(.speech) { onInterruption(nil) }
        do {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(Constants.Speech.sampleRate),
                channels: Constants.Speech.channels
            ) else { throw SpeechError.unavailable }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            self.engine = engine
            self.player = player
            self.format = format
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()

            observe(AVAudioSession.interruptionNotification) { notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                return type == AVAudioSession.InterruptionType.began.rawValue
            } onInterruption: { onInterruption(.interrupted) }
            observe(AVAudioSession.routeChangeNotification) { notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                return reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            } onInterruption: { onInterruption(.interrupted) }
            observe(AVAudioSession.mediaServicesWereResetNotification, onInterruption: { onInterruption(.interrupted) })
            observe(.AVAudioEngineConfigurationChange, object: engine, onInterruption: { onInterruption(.interrupted) })
        } catch {
            stop()
            throw error
        }
    }

    func schedule(_ samples: [Float], completion: @escaping @MainActor @Sendable () -> Void) throws {
        guard let player, let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee else {
            throw SpeechError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in completion() }
        }
    }

    func play() {
        if player?.isPlaying == false { player?.play() }
    }

    func pause() {
        if player?.isPlaying == true { player?.pause() }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
        if let lease { coordinator.release(lease) }
        lease = nil
    }

    private func observe(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        shouldInterrupt: @escaping @Sendable (Notification) -> Bool = { _ in true },
        onInterruption: @escaping @MainActor () -> Void
    ) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { notification in
            guard shouldInterrupt(notification) else { return }
            Task { @MainActor in onInterruption() }
        })
    }
}
