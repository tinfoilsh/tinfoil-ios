import Foundation

enum SpeechError: Error, Equatable, LocalizedError {
    case empty
    case invalidAudio
    case timedOut
    case unavailable
    case audioBusy
    case interrupted
    case rateLimited
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .empty: return "This response has no readable text."
        case .invalidAudio: return "The speech service returned invalid audio. Please try again."
        case .timedOut: return "Read aloud timed out. Please try again."
        case .unavailable: return "Read aloud is not available yet. Please try again shortly."
        case .audioBusy: return "Stop recording or dismiss the timer alarm before reading aloud."
        case .interrupted: return "Read aloud was interrupted. Tap to try again."
        case .rateLimited: return "The speech limit has been reached. Please try again later."
        case .requestFailed: return "Could not read this response aloud. Please try again."
        }
    }

    static func sanitized(_ error: Error) -> SpeechError {
        if let error = error as? SpeechError { return error }
        if let error = error as? URLError, error.code == .timedOut { return .timedOut }
        if let error = error as? HarnessError {
            if error.urlErrorCode == .timedOut { return .timedOut }
            switch error.code {
            case HarnessErrorCode.quotaExhausted, HarnessErrorCode.rateLimited: return .rateLimited
            case HarnessErrorCode.toolUnavailable: return .unavailable
            default: return .requestFailed
            }
        }
        return .requestFailed
    }
}
