import Foundation
import Speech

enum AppleSpeechAvailability: Equatable, Sendable {
    case available
    case unsupportedLanguage
    case onDeviceUnavailable
    case serviceUnavailable

    func message(for language: String) -> String? {
        switch self {
        case .available: return nil
        case .unsupportedLanguage: return "Apple Speech does not support \(language)."
        case .onDeviceUnavailable: return "\(language) is not available for on-device recognition. Transcription will fail while “Transcribe on this Mac only” is enabled."
        case .serviceUnavailable: return "Apple Speech is currently unavailable for \(language)."
        }
    }

    static func evaluate(
        languageSupported: Bool,
        serviceAvailable: Bool,
        supportsOnDevice: Bool,
        installedOnDevice: Bool?,
        preferOnDevice: Bool
    ) -> Self {
        guard languageSupported else { return .unsupportedLanguage }
        if preferOnDevice, !supportsOnDevice || installedOnDevice == false {
            return .onDeviceUnavailable
        }
        return serviceAvailable ? .available : .serviceUnavailable
    }

    /// Normalize separators and implicit scripts without treating a different
    /// regional model (for example en-GB versus en-US) as the installed one.
    static func isInstalled(_ locale: Locale, in installedLocales: [Locale]) -> Bool {
        installedLocales.contains { $0.language.maximalIdentifier == locale.language.maximalIdentifier }
    }
}

final class AppleSpeechTranscriber {
    static func recognitionLocale(for language: String, currentLocale: Locale = .current) -> Locale {
        language.isEmpty ? currentLocale : Locale(identifier: language)
    }

    /// Supported languages are different from installed languages. Keep a
    /// downloadable language selectable; availability() explains missing assets.
    @MainActor
    static func supportedLanguages(preferOnDevice: Bool) async -> [SpokenLanguage] {
        let locales: [Locale]
        if preferOnDevice {
            if #available(macOS 26, *) {
                locales = await DictationTranscriber.supportedLocales
            } else {
                locales = SFSpeechRecognizer.supportedLocales().filter { locale in
                    guard let recognizer = SFSpeechRecognizer(locale: locale),
                          recognizer.locale.language.languageCode == locale.language.languageCode else {
                        return false
                    }
                    return recognizer.supportsOnDeviceRecognition
                }
            }
        } else {
            // Includes locales Apple can recognise through its servers.
            locales = Array(SFSpeechRecognizer.supportedLocales())
        }
        return languageOptions(supportedLocales: locales)
    }

    static func languageOptions(supportedLocales: [Locale]) -> [SpokenLanguage] {
        let supported = Set(supportedLocales.map { $0.language.maximalIdentifier })
        return SpokenLanguageCatalog.all.filter { language in
            language.id.isEmpty
                || supported.contains(Locale(identifier: language.regionalTag).language.maximalIdentifier)
        }
    }

    /// Read-only preflight: no permission prompt, download or recognition task.
    @MainActor
    static func availability(language: String, preferOnDevice: Bool) async -> AppleSpeechAvailability {
        let locale = recognitionLocale(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.locale.language.languageCode == locale.language.languageCode else {
            // Apple's initializer may fall back to another language. That is
            // not evidence that the user's selected language is supported.
            return .unsupportedLanguage
        }

        var installedOnDevice: Bool?
        if preferOnDevice, recognizer.supportsOnDeviceRecognition {
            if #available(macOS 26, *) {
                // DictationTranscriber uses the same local models as
                // SFSpeechRecognizer; supportedLocales is NOT an installed list.
                // https://developer.apple.com/documentation/speech/dictationtranscriber
                let installed = await DictationTranscriber.installedLocales
                installedOnDevice = AppleSpeechAvailability.isInstalled(recognizer.locale, in: installed)
            }
        }
        return AppleSpeechAvailability.evaluate(
            languageSupported: true,
            serviceAvailable: recognizer.isAvailable,
            supportsOnDevice: recognizer.supportsOnDeviceRecognition,
            installedOnDevice: installedOnDevice,
            preferOnDevice: preferOnDevice
        )
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func transcribe(
        fileURL: URL,
        language: String,
        preferOnDevice: Bool,
        prompt: String
    ) async throws -> String {
        guard await Self.requestAuthorization() == .authorized else {
            throw TranscriptionError.speechPermissionDenied
        }

        let locale = Self.recognitionLocale(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        if preferOnDevice, !recognizer.supportsOnDeviceRecognition {
            throw TranscriptionError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = preferOnDevice
        if !prompt.isEmpty {
            request.contextualStrings = prompt
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = RecognitionCompletionGate()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    gate.finish(.success(text), continuation: continuation)
                } else if let error {
                    gate.finish(.failure(error), continuation: continuation)
                }
            }
        }
    }
}

private final class RecognitionCompletionGate {
    private let lock = NSLock()
    private var completed = false

    func finish(
        _ result: Result<String, Error>,
        continuation: CheckedContinuation<String, Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}
