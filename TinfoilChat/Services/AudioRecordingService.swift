//
//  AudioRecordingService.swift
//  TinfoilChat
//
//  Service for recording audio and transcribing it to text
//

import Foundation
import AVFoundation

/// Service for managing audio recording and transcription
@MainActor
class AudioRecordingService: NSObject, ObservableObject {
    static let shared = AudioRecordingService()

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false

    private var audioRecorder: AVAudioRecorder?
    private var timeoutTimer: Timer?
    private var recordingURL: URL?

    private override init() {
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

    /// Start recording audio
    func startRecording() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = getRecordingURL()
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Constants.Audio.sampleRate,
            AVNumberOfChannelsKey: Constants.Audio.numberOfChannels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.record()
        isRecording = true

        // Auto-stop after timeout
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.Audio.recordingTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopRecording()
            }
        }
    }

    /// Stop recording and return the audio file URL
    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        timeoutTimer?.invalidate()
        timeoutTimer = nil

        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false

        return recordingURL
    }

    /// Cancel recording without returning the file
    func cancelRecording() {
        stopRecording()
        cleanupRecordingFile()
    }

    // MARK: - Transcription

    /// Transcribe the recorded audio file
    func transcribe(fileURL: URL, apiKey: String, model: String) async throws -> String {
        isTranscribing = true
        defer {
            isTranscribing = false
            cleanupRecordingFile()
        }

        let audioData = try Data(contentsOf: fileURL)

        guard !audioData.isEmpty else {
            throw AudioRecordingError.emptyRecording
        }

        let url = URL(string: "\(Constants.API.baseURL)/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body = Data()

        // Add file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Add response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AudioRecordingError.transcriptionFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AudioRecordingError.transcriptionFailed("Status \(httpResponse.statusCode): \(errorMessage)")
        }

        // Response format is plain text when response_format=text
        guard let transcription = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcription.isEmpty else {
            throw AudioRecordingError.emptyTranscription
        }

        return transcription
    }

    // MARK: - Private Helpers

    private func getRecordingURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "recording_\(UUID().uuidString).m4a"
        return tempDir.appendingPathComponent(filename)
    }

    private func cleanupRecordingFile() {
        guard let url = recordingURL else { return }
        try? FileManager.default.removeItem(at: url)
        recordingURL = nil
    }
}

// MARK: - Errors

enum AudioRecordingError: LocalizedError {
    case permissionDenied
    case emptyRecording
    case emptyTranscription
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied"
        case .emptyRecording:
            return "Recording is empty"
        case .emptyTranscription:
            return "Transcription returned empty"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}
