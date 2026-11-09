//
//  AudioRecordingService.swift
//  TinfoilChat
//
//  Service for recording audio to be transcribed
//

import Foundation
import AVFoundation
import UIKit

/// Service for managing audio recording
@MainActor
class AudioRecordingService: NSObject, ObservableObject {
    static let shared = AudioRecordingService()

    /// A recording handed over: its file, and its number in the dictation.
    typealias HandOver = (_ recording: URL, _ index: Int) -> Void

    @Published private(set) var isRecording = false

    private var audioRecorder: AVAudioRecorder?
    private var audioSessionLease: UUID?
    private var segmentTimer: Timer?
    private var recordingURL: URL?
    private var didDisableIdleTimer: Bool = false
    /// The recording under way: its number, when it began, how long the
    /// recordings before it ran, and since when it has been quiet.
    private var segmentIndex = 0
    private var segmentStartedAt = Date()
    private var earlierSegmentsDuration: TimeInterval = .zero
    private var quietSince: Date?
    private var segmentSeconds: TimeInterval = .zero
    private var handOver: HandOver?

    override init() {
        super.init()
    }

    // MARK: - Permission

    /// Request microphone permission
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Check if microphone permission is granted
    var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: - Recording

    /// Starts recording. What is recorded is handed over in recordings of
    /// about segmentSeconds, each ended at the first pause after that long,
    /// while recording goes on, and the last one when it stops.
    func startRecording(segmentSeconds: TimeInterval, handOver: @escaping HandOver) throws {
        guard !isRecording else { return }
        // A recording with no length would be cut at every reading.
        guard segmentSeconds > 0 else { throw AudioRecordingError.recordingFailed }

        let lease = try AudioSessionCoordinator.shared.acquire(.recording)
        audioSessionLease = lease
        defer {
            if !isRecording {
                AudioSessionCoordinator.shared.release(lease)
                audioSessionLease = nil
            }
        }

        audioRecorder = try beginSegment()
        self.segmentSeconds = segmentSeconds
        self.handOver = handOver
        segmentIndex = 0
        earlierSegmentsDuration = .zero
        quietSince = nil
        isRecording = true
        disableIdleTimer()

        let timer = Timer(timeInterval: Constants.Audio.Dictation.levelSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.endSegmentAtPause()
            }
        }
        segmentTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops recording and hands over the recording under way.
    func stopRecording() {
        guard isRecording else { return }
        let index = segmentIndex
        let handOver = self.handOver
        if let url = finish() {
            handOver?(url, index)
        }
    }

    func meteringSample() -> AudioMeterSample? {
        guard isRecording, let audioRecorder else { return nil }
        guard audioRecorder.isRecording else {
            stopRecording()
            return nil
        }
        audioRecorder.updateMeters()
        return AudioMeterSample(
            decibels: audioRecorder.averagePower(forChannel: Constants.Audio.Waveform.meteringChannel),
            elapsedTime: earlierSegmentsDuration + audioRecorder.currentTime
        )
    }

    /// Cancel recording, discarding the recording under way.
    func cancelRecording() {
        guard isRecording else { return }
        if let url = finish() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private Helpers

    private func beginSegment() throws -> AVAudioRecorder {
        let url = getRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Constants.Audio.sampleRate,
            AVNumberOfChannelsKey: Constants.Audio.numberOfChannels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecordingError.recordingFailed
        }
        recordingURL = url
        segmentStartedAt = Date()
        return recorder
    }

    /// Ends the recording under way at the first pause after it has run its
    /// length, or at its longest without one, hands it over, and records on
    /// in a new one. Cut in a pause, the moment between them is silent.
    private func endSegmentAtPause() {
        guard isRecording, let recorder = audioRecorder else { return }
        guard recorder.isRecording else {
            stopRecording()
            return
        }
        recorder.updateMeters()
        let now = Date()
        if recorder.averagePower(forChannel: Constants.Audio.Waveform.meteringChannel) >= Constants.Audio.Dictation.pauseDecibels {
            quietSince = nil
        } else if quietSince == nil {
            quietSince = now
        }
        let elapsed = now.timeIntervalSince(segmentStartedAt)
        let paused = quietSince.map { now.timeIntervalSince($0) >= Constants.Audio.Dictation.pauseSeconds } ?? false
        guard (elapsed >= segmentSeconds && paused)
            || elapsed >= segmentSeconds * Constants.Audio.Dictation.longestSegmentFactor else { return }

        let index = segmentIndex
        guard let url = recordingURL else { return }
        earlierSegmentsDuration += recorder.currentTime
        recorder.stop()
        do {
            audioRecorder = try beginSegment()
            segmentIndex += 1
            quietSince = nil
            handOver?(url, index)
        } catch {
            // No recording could follow, so dictation ends with this one.
            audioRecorder = nil
            recordingURL = url
            stopRecording()
        }
    }

    /// Stops the recorder and releases the microphone, and returns the
    /// recording under way.
    private func finish() -> URL? {
        segmentTimer?.invalidate()
        segmentTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        handOver = nil
        isRecording = false
        if let audioSessionLease { AudioSessionCoordinator.shared.release(audioSessionLease) }
        audioSessionLease = nil
        restoreIdleTimer()
        let url = recordingURL
        recordingURL = nil
        return url
    }

    private func getRecordingURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "recording_\(UUID().uuidString).\(Constants.Audio.recordingFileExtension)"
        return tempDir.appendingPathComponent(filename)
    }

    private func disableIdleTimer() {
        guard !didDisableIdleTimer else { return }
        didDisableIdleTimer = true
        Task { @MainActor in
            if !UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    private func restoreIdleTimer() {
        guard didDisableIdleTimer else { return }
        didDisableIdleTimer = false
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Errors

enum AudioRecordingError: LocalizedError {
    case permissionDenied
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied"
        case .recordingFailed:
            return "Could not start audio recording. Please try again."
        }
    }
}
