import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Rewrites a transcript using the language model built into macOS.
///
/// The appeal is what it does not need: no model to download, no gigabytes on
/// disk, no API key, no account, no network, and nothing sent anywhere. The
/// text never leaves the machine, which for a dictation app is the whole point
/// of a local option.
///
/// It only exists on macOS 26 and later, on Apple silicon, with Apple
/// Intelligence turned on and the model actually downloaded. All four have to
/// be true, and none of them can be assumed, so `availability` reports which
/// one is missing and the option is hidden entirely when it cannot be used.
/// The framework is weak-linked: this app still runs on macOS 14, where the
/// framework is simply absent.
enum AppleOnDeviceRewriter {
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "OnDeviceRewrite")

    /// Why the on-device model cannot be used, when it cannot.
    enum Availability: Equatable {
        case available
        /// This version of macOS has no on-device model at all.
        case unsupportedSystem
        /// The Mac supports it but Apple Intelligence is switched off.
        case notEnabled
        /// Enabled, but the model itself has not finished downloading.
        case modelNotReady
        /// Available in principle, unavailable here: hardware, region, or a
        /// reason the system declines to give.
        case unavailable(String)

        var isAvailable: Bool { self == .available }

        /// Shown where the user chose the on-device provider but cannot use it.
        var explanation: String? {
            switch self {
            case .available:
                return nil
            case .unsupportedSystem:
                return "Rewriting on this Mac needs macOS 26 or later."
            case .notEnabled:
                // Deliberately mentions the language pairing. macOS reports
                // this same state when Apple Intelligence is switched on but
                // the system and Siri languages differ, and a user sent to
                // System Settings to "turn it on" finds it already on with no
                // hint as to what is wrong.
                return "Apple Intelligence is not running. Turn it on in System Settings, and check that Siri's language matches your Mac's: it will not start while they differ."
            case .modelNotReady:
                return "macOS is still downloading its language model. This will work once that finishes."
            case let .unavailable(reason):
                return reason
            }
        }
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .unsupportedSystem }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .notEnabled
            case .modelNotReady:
                return .modelNotReady
            case .deviceNotEligible:
                return .unavailable("This Mac cannot run Apple's on-device model. Choose a provider instead.")
            @unknown default:
                return .unavailable("macOS cannot use its on-device model right now. Choose a provider instead.")
            }
        @unknown default:
            return .unavailable("macOS cannot use its on-device model right now. Choose a provider instead.")
        }
        #else
        return .unsupportedSystem
        #endif
    }

    /// Whether macOS's model handles `code`, an ISO 639-1 language code.
    ///
    /// Returns nil when the question cannot be answered rather than guessing:
    /// an empty code means the language is whatever was spoken and is not known
    /// until afterwards, and a system with no model has no list to consult. Only
    /// a definite `false` is worth warning about, because a warning that fires
    /// on "Automatic" would fire for most people and mean nothing.
    ///
    /// Apple's model covers fewer languages than the transcription engines do,
    /// so this is a normal state for a setup with nothing wrong with it.
    static func supportsLanguage(_ code: String) -> Bool? {
        let code = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty else { return nil }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), availability.isAvailable else { return nil }
        return SystemLanguageModel.default.supportedLanguages.contains {
            $0.languageCode?.identifier.lowercased() == code
        }
        #else
        return nil
        #endif
    }

    /// The most likely failure in normal use is the guardrail refusing
    /// something in the transcript. Saying so is more useful than the
    /// framework's own wording, and the caller keeps the original text anyway.
    private static func refusal(_ error: Error) -> TranscriptionError {
        // Every call site rethrows CancellationError before reaching here;
        // this stays only as a loud trace if a future path forgets, because
        // wrapping a cancellation as a refusal costs the user their words.
        if error is CancellationError {
            logger.error("a CancellationError reached refusal(); it should have been rethrown")
        }
        logger.error("on-device rewrite failed: \(error.localizedDescription, privacy: .public)")
        return .invalidConfiguration("macOS declined to rewrite this transcript. The original text was kept.")
    }

    /// Rewrites `transcript` according to `systemPrompt`.
    ///
    /// Availability is checked immediately before use rather than trusted from
    /// a cached value: Apple Intelligence can be switched off, and the model can
    /// be evicted, between the moment the setting was chosen and the moment a
    /// dictation ends.
    static func rewrite(_ transcript: String, systemPrompt: String) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            throw TranscriptionError.invalidConfiguration(Availability.unsupportedSystem.explanation ?? "")
        }
        let state = availability
        guard state.isAvailable else {
            throw TranscriptionError.invalidConfiguration(state.explanation ?? "The on-device model is unavailable.")
        }

        let session = LanguageModelSession(
            instructions: systemPrompt + "\n\n" + EnhancementOutput.instruction
        )
        do {
            let response = try await session.respond(to: transcript)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.emptyResponse }
            return text
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let generation as LanguageModelSession.GenerationError {
            // macOS's own model covers fewer languages than the transcription
            // engines do, so this is reachable from a setup with nothing wrong
            // with it. It is not a refusal, and "declined" would send the user
            // looking for something objectionable in their own words.
            if case .unsupportedLanguageOrLocale = generation {
                logger.error("on-device rewrite: unsupported language")
                throw TranscriptionError.invalidConfiguration(
                    "Apple's on-device model does not handle this language. Choose a provider to rewrite it."
                )
            }
            throw refusal(generation)
        } catch {
            if error is CancellationError { throw error }
            throw refusal(error)
        }
        #else
        throw TranscriptionError.invalidConfiguration(Availability.unsupportedSystem.explanation ?? "")
        #endif
    }
}
