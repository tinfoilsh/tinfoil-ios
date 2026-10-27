import Foundation

extension ChatViewModel {
    // MARK: - Read aloud

    func toggleReadAloud(messageId: String) throws {
        guard let session, let chat = currentChat else { throw SpeechError.unavailable }
        let owner = SpeechOwner(chatId: chat.id, messageId: messageId)
        if speechPlayer.snapshot.owner == owner,
           speechPlayer.snapshot.status == .playing || speechPlayer.snapshot.status == .loading {
            speechPlayer.stop()
            return
        }
        guard !isRecording, !AudioRecordingService.shared.isRecording else { throw SpeechError.audioBusy }
        guard canUseReadAloud,
              let message = chat.messages.first(where: { $0.id == messageId }),
              SpeechTextProcessor.canRead(message) else { throw SpeechError.unavailable }
        let service = HarnessSpeechStream { @MainActor in
            try await session.speak(messageId)
        }
        try speechPlayer.read(owner: owner, content: SpeechTextProcessor.source(for: message), service: service)
    }

    // MARK: - Audio recording

    enum AudioRecordingStartDecision: Equatable {
        case start
        case showUpgrade
        case accountChanged
        case chatUnavailable
    }

    static func audioRecordingStartDecision(
        canUseAudioInput: Bool,
        canGenerateInCurrentChat: Bool,
        requestedAccountId: String?,
        currentAccountId: String?
    ) -> AudioRecordingStartDecision {
        guard requestedAccountId == currentAccountId else { return .accountChanged }
        guard canGenerateInCurrentChat else { return .chatUnavailable }
        return canUseAudioInput ? .start : .showUpgrade
    }

    /// Audio input is a premium feature the chat service offers.
    var canUseAudioInput: Bool {
        hasPremiumAccess && account?.session?.features.additionalProperties["transcription"] == true
    }

    func startAudioRecording() async {
        guard canGenerateInCurrentChat, !isAccountTeardownInProgress, !Task.isCancelled else { return }
        guard canUseAudioInput else {
            showRateLimitPaywall = true
            return
        }
        let requestedAccountId = authManager?.localUserId
        let requestedChatId = currentChat?.id
        let requestId = UUID()
        audioRecordingStartId = requestId
        defer { if audioRecordingStartId == requestId { audioRecordingStartId = nil } }
        audioError = nil
        var hasMicrophonePermission = true
        if !AudioRecordingService.shared.hasPermission {
            hasMicrophonePermission = await AudioRecordingService.shared.requestPermission()
        }
        guard !isAccountTeardownInProgress, !Task.isCancelled, audioRecordingStartId == requestId,
              currentChat?.id == requestedChatId else { return }
        switch Self.audioRecordingStartDecision(
            canUseAudioInput: canUseAudioInput,
            canGenerateInCurrentChat: canGenerateInCurrentChat,
            requestedAccountId: requestedAccountId,
            currentAccountId: authManager?.localUserId
        ) {
        case .start:
            break
        case .showUpgrade:
            showRateLimitPaywall = true
            return
        case .accountChanged, .chatUnavailable:
            return
        }
        guard hasMicrophonePermission else {
            showMicrophonePermissionAlert = true
            return
        }
        do {
            try AudioRecordingService.shared.startRecording()
            isRecording = true
        } catch {
            audioError = error.localizedDescription
        }
    }

    /// Stops recording and has the chat service transcribe it.
    func stopAudioRecordingAndTranscribe() async -> String? {
        guard isRecording else { return nil }
        guard canGenerateInCurrentChat, let session, let chatId = currentChat?.id else {
            cancelAudioRecording()
            return nil
        }
        let accountId = currentUserId
        let transcription = UUID()
        audioTranscriptionId = transcription
        func isCurrentTranscription() -> Bool {
            audioTranscriptionId == transcription
                && currentChat?.id == chatId
                && currentUserId == accountId
                && canGenerateInCurrentChat
                && !isAccountTeardownInProgress
                && !Task.isCancelled
        }
        isRecording = false
        guard let fileURL = AudioRecordingService.shared.stopRecording() else { return nil }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let text = try await AudioRecordingService.shared.transcribe(fileURL: fileURL) { recording in
                guard isCurrentTranscription() else { throw CancellationError() }
                return try await HarnessSpeech.transcribe(session.account, recording: recording, fileName: fileURL.lastPathComponent, mimeType: Constants.Audio.recordingMimeType)
            }
            guard isCurrentTranscription() else { return nil }
            return text
        } catch {
            guard isCurrentTranscription() else { return nil }
            audioError = error.localizedDescription
            return nil
        }
    }

    func cancelAudioRecording() {
        audioRecordingStartId = nil
        audioTranscriptionId = nil
        isRecording = false
        AudioRecordingService.shared.cancelRecording()
    }
}
