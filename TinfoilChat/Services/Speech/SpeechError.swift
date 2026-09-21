import Foundation
import OpenAI

enum SpeechError: Error, Equatable, LocalizedError {
    case empty
    case tooLong
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
        case .tooLong: return "This response is too long to read aloud."
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
        if error is SessionTokenError { return .rateLimited }
        if error is AudioSpeechStreamError { return .invalidAudio }
        if let error = error as? URLError, error.code == .timedOut { return .timedOut }
        if let error = error as? OpenAIError {
            switch error {
            case .emptyData: return .invalidAudio
            case .statusError(_, let status) where status == Constants.API.tooManyRequestsStatusCode: return .rateLimited
            default: break
            }
        }
        if let error = error as? APIErrorResponse,
           error.error.type == Constants.API.ErrorType.rateLimit
            || error.error.code == Constants.API.ErrorCode.rateLimitExceeded
            || error.error.code == Constants.API.ErrorCode.insufficientQuota {
            return .rateLimited
        }
        return .requestFailed
    }
}
