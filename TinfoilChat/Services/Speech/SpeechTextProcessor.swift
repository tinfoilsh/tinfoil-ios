import Foundation

/// What of a message is read aloud. The chat service reads the message
/// itself, as its markdown is spoken; this only decides whether there is
/// anything to read.
enum SpeechTextProcessor {
    static func source(for message: Message) -> String {
        if !message.content.isEmpty { return message.content }
        return (message.segments ?? []).compactMap { segment in
            if case .text(let text) = segment { return text }
            return nil
        }.joined(separator: "\n")
    }

    static func canRead(_ message: Message) -> Bool {
        message.role == .assistant && !message.isStreaming && !message.isThinking
            && message.streamError == nil && message.isError != true
            && !source(for: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
