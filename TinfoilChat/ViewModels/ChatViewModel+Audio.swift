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
        let harnessMessageId = self.messageId(ofRow: messageId)
        let service = HarnessSpeechStream { @MainActor in
            try await session.speak(harnessMessageId)
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
        guard let chatId = currentChat?.id,
              let segmentSeconds = account?.session?.composer.dictationSegmentSeconds else { return }
        let dictationId = UUID().uuidString
        let startedAt = Date()
        let persist = !isTemporaryMode
        do {
            try AudioRecordingService.shared.startRecording(segmentSeconds: TimeInterval(segmentSeconds)) { [weak self] recording, index in
                self?.dictation.recorded(recording, chatId: chatId, dictationId: dictationId, index: index, startedAt: startedAt, persist: persist)
            }
            recordingDictationId = dictationId
            isRecording = true
            dictationChanged()
        } catch {
            audioError = error.localizedDescription
        }
    }

    /// Stops recording. What was recorded is still transcribed, and its text
    /// joins the composer as it arrives.
    func stopAudioRecording() {
        guard isRecording else { return }
        guard canGenerateInCurrentChat else {
            cancelAudioRecording()
            return
        }
        recordingDictationId = nil
        isRecording = false
        AudioRecordingService.shared.stopRecording()
        dictationChanged()
    }

    /// Stops recording and forgets what it recorded.
    func cancelAudioRecording() {
        audioRecordingStartId = nil
        isRecording = false
        AudioRecordingService.shared.cancelRecording()
        if let recordingDictationId {
            dictation.discard(dictationId: recordingDictationId)
        }
        recordingDictationId = nil
        dictationChanged()
    }

    /// The open chat's dictated text that waited for its composer, which
    /// now takes it. Text dictated in another chat waits for that chat.
    func takeDictatedText() -> [String] {
        guard let chatId = currentChat?.id else { return [] }
        return dictation.take(chatId: chatId)
    }

    func retryDictation() {
        dictation.retry()
    }

    func discardFailedDictation() {
        dictation.discardFailed()
    }

    /// The composer waits for a stopped recording's first attempt, not for
    /// the recordings transcribed while recording goes on.
    func dictationChanged() {
        let state = dictation.state
        let transcribing = state.transcribing && !isRecording
        if isTranscribing != transcribing { isTranscribing = transcribing }
        if dictationRetrying != state.retrying { dictationRetrying = state.retrying }
        if dictationFailed != state.failed { dictationFailed = state.failed }
        if dictationReadyChatIds != state.readyChatIds { dictationReadyChatIds = state.readyChatIds }
    }
}
