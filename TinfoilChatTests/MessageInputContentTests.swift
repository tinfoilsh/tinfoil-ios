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
            requestedAccountId: "account",
            currentAccountId: "account"
        ) == .start)
        #expect(ChatViewModel.audioRecordingStartDecision(
            canUseAudioInput: false,
            requestedAccountId: "account",
            currentAccountId: "account"
        ) == .showUpgrade)
        #expect(ChatViewModel.audioRecordingStartDecision(
            canUseAudioInput: true,
            requestedAccountId: "account-a",
            currentAccountId: "account-b"
        ) == .accountChanged)
    }
}
