import Foundation

enum TranscriptionError: LocalizedError {
    case invalidConfiguration(String)
    case speechPermissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case emptyResponse
    case invalidResponse
    case server(statusCode: Int, message: String)
    case localInferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): return message
        case let .localInferenceFailed(message): return message
        case .speechPermissionDenied:
            return "Speech Recognition access is required for the Apple Speech provider."
        case .recognizerUnavailable:
            return "Apple Speech Recognition is currently unavailable for the selected language."
        case .onDeviceRecognitionUnavailable:
            return "On-device recognition is unavailable for the selected language. Turn off “Transcribe on this Mac only” or choose another language."
        case .emptyResponse:
            return "No speech was recognized. Check the selected microphone in Settings → Voice, make sure it is not muted, and try again."
        case .invalidResponse:
            return "The transcription provider returned an unreadable response."
        case let .server(statusCode, message):
            return "The transcription provider returned HTTP \(statusCode): \(message)"
        }
    }
}
