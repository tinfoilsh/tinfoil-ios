import Testing
@testable import TinfoilChat

@Suite("Message input content")
struct MessageInputContentTests {
    @Test("detects visible draft content", arguments: ["hello", "  hello  ", "\nmessage"])
    func visibleContent(text: String) {
        #expect(hasNonWhitespaceContent(text))
    }

    @Test("rejects whitespace-only drafts", arguments: ["", " ", "\n\t"])
    func whitespaceOnlyContent(text: String) {
        #expect(!hasNonWhitespaceContent(text))
    }

    @Test("keeps existing text above an active audio waveform", arguments: ["", " \n", "Existing draft"], [false, true])
    func composerTextVisibility(text: String, showsAudioWaveform: Bool) {
        let hasDraftText = hasNonWhitespaceContent(text)
        let showsText = shouldShowComposerText(hasDraftText: hasDraftText, showsAudioWaveform: showsAudioWaveform)
        if showsAudioWaveform {
            #expect(showsText == hasDraftText)
        } else {
            #expect(showsText)
        }
    }

    @Test("describes remaining free requests", arguments: [
        (3, "3 free requests left today"),
        (1, "1 free request left today"),
        (0, "No free requests left today"),
    ])
    func remainingFreeRequests(remaining: Int, expectedText: String) {
        #expect(freeRequestsRemainingText(remaining) == expectedText)
    }

    @Test("hides audio input when Premium access is unavailable")
    func hidesUnavailableAudioInput() {
        #expect(!shouldShowAudioInput(
            canUseAudioInput: false,
            isRecording: false,
            isTranscribing: false,
            isStartingRecording: false
        ))
    }

    @Test("keeps audio controls visible while an operation is active")
    func preservesActiveAudioOperationControls() {
        #expect(shouldShowAudioInput(
            canUseAudioInput: false,
            isRecording: true,
            isTranscribing: false,
            isStartingRecording: false
        ))
        #expect(shouldShowAudioInput(
            canUseAudioInput: false,
            isRecording: false,
            isTranscribing: true,
            isStartingRecording: false
        ))
        #expect(shouldShowAudioInput(
            canUseAudioInput: false,
            isRecording: false,
            isTranscribing: false,
            isStartingRecording: true
        ))
    }

    @Test("rechecks access after delayed microphone permission")
    @MainActor
    func delayedMicrophonePermissionAccess() {
        #expect(ChatViewModel.audioRecordingStartDecision(
            canUseAudioInput: true,
            canGenerateInCurrentChat: true,
            requestedAccountId: "account",
            currentAccountId: "account"
        ) == .start)
        #expect(ChatViewModel.audioRecordingStartDecision(
            canUseAudioInput: false,
            canGenerateInCurrentChat: true,
            requestedAccountId: "account",
            currentAccountId: "account"
        ) == .showUpgrade)
        #expect(ChatViewModel.audioRecordingStartDecision(
            canUseAudioInput: true,
            canGenerateInCurrentChat: true,
            requestedAccountId: "account-a",
            currentAccountId: "account-b"
        ) == .accountChanged)
    }

    @Test("does not start recording or show an upgrade for a blocked chat", arguments: [false, true])
    @MainActor
    func blockedChatRejectsMicrophoneStart(canUseAudioInput: Bool) {
        #expect(ChatViewModel.audioRecordingStartDecision(
            canUseAudioInput: canUseAudioInput,
            canGenerateInCurrentChat: false,
            requestedAccountId: "account",
            currentAccountId: "account"
        ) == .chatUnavailable)
    }

    @Test("uses one voice or send action based on draft content", arguments: ["", " ", "hello", "  hello  "])
    func trailingActionFollowsDraftContent(text: String) {
        let hasContent = hasNonWhitespaceContent(text)
        #expect(MessageInputTrailingAction.resolve(
            showAudioButton: true,
            showsRecordingState: false,
            hasDraftContent: hasContent,
            showStopAction: false
        ) == (hasContent ? .send : .voice))
    }

    @Test("keeps the recording stop action available when the draft changes", arguments: [false, true])
    func recordingRetainsTheVoiceAction(hasDraftContent: Bool) {
        #expect(MessageInputTrailingAction.resolve(
            showAudioButton: true,
            showsRecordingState: true,
            hasDraftContent: hasDraftContent,
            showStopAction: false
        ) == .voice)
    }

    @Test("keeps voice input available across draft and recording states", arguments: [
        (false, false, false),
        (false, true, false),
        (true, false, true),
        (true, true, false),
    ])
    func microphoneAvailabilityFollowsComposerState(hasDraft: Bool, isRecording: Bool, expectedMicrophone: Bool) {
        let action = MessageInputTrailingAction.resolve(
            showAudioButton: true,
            showsRecordingState: isRecording,
            hasDraftContent: hasDraft,
            showStopAction: false
        )
        #expect(action.showsSeparateMicrophone(showAudioButton: true, hasDraftContent: hasDraft) == expectedMicrophone)
        #expect(action == (isRecording || !hasDraft ? .voice : .send))
    }

    @Test("separate microphone respects audio availability and draft content", arguments: [false, true])
    func separateMicrophoneAvailability(hasDraft: Bool) {
        #expect(!MessageInputTrailingAction.send.showsSeparateMicrophone(showAudioButton: false, hasDraftContent: hasDraft))
        #expect(MessageInputTrailingAction.stop.showsSeparateMicrophone(showAudioButton: true, hasDraftContent: hasDraft) == hasDraft)
    }

    @Test("retains stop for generation and send when audio is unavailable", arguments: [false, true])
    func trailingActionPreservesStopAndUnavailableAudio(hasDraftContent: Bool) {
        #expect(MessageInputTrailingAction.resolve(
            showAudioButton: true,
            showsRecordingState: false,
            hasDraftContent: hasDraftContent,
            showStopAction: true
        ) == .stop)
        #expect(MessageInputTrailingAction.resolve(
            showAudioButton: false,
            showsRecordingState: false,
            hasDraftContent: hasDraftContent,
            showStopAction: false
        ) == .send)
    }
}
