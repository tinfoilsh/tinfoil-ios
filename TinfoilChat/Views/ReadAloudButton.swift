import SwiftUI

struct ReadAloudButton: View {
    @ObservedObject var player: SpeechPlayer
    let owner: SpeechOwner
    let isDarkMode: Bool
    let action: () throws -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var error: SpeechError?

    private var status: SpeechPlayer.Status {
        player.snapshot.owner == owner ? player.snapshot.status : .idle
    }

    private var isPlaying: Bool { status == .playing }

    private var label: String {
        switch status {
        case .idle: return "Read aloud"
        case .loading: return "Cancel read aloud"
        case .playing: return "Stop read aloud"
        case .failed: return "Retry read aloud"
        }
    }

    var body: some View {
        Button {
            do { try action() }
            catch { self.error = SpeechError.sanitized(error) }
        } label: {
            Group {
                if status == .loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "speaker.wave.2")
                        .font(.system(size: Constants.Speech.actionIconSize))
                        .symbolEffect(.pulse, options: .repeating, isActive: isPlaying && !reduceMotion)
                }
            }
            .foregroundStyle(isPlaying ? Color.red : (isDarkMode ? Color.white : Color.black).opacity(0.5))
            .frame(width: Constants.Speech.actionSize, height: Constants.Speech.actionSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(status == .loading ? "Preparing audio" : isPlaying ? "Playing" : "")
        .accessibleHitTarget()
        .onChange(of: status, initial: true) { _, _ in
            if let failure = player.pendingFailure(for: owner) { error = failure }
        }
        .alert("Read Aloud", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {
                player.acknowledgeFailure(for: owner)
                error = nil
            }
        } message: {
            Text(error?.localizedDescription ?? "")
        }
    }
}
