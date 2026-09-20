import XCTest
@testable import MicMyDay

/// Exploration, not regression: runs the built-in cleanup prompt against
/// dictations containing spoken self-corrections, on the on-device model and
/// on the downloadable GGUF rewrite models, and prints what comes back, so
/// the prompt wording is shaped by measured behaviour rather than guesses.
/// Both probes skip themselves unless explicitly enabled.
final class RewriteCorrectionProbeTests: XCTestCase {
    private static let dictations = [
        "the meeting is on Monday no wait I mean Tuesday at ten",
        "send it to Chris actually scratch that send it to the whole team",
        "we need three no make that five copies of the report",
        "I'll take the train I mean the bus to the office tomorrow",
        "the deadline is Friday um no sorry it is Thursday end of day",
        // Legitimate uses of correction-like words that must survive.
        "no wait for my signal before you deploy",
        "she said no I mean it when I asked her twice",
    ]

    /// The shipping cleanup prompt, and the same prompt with a candidate
    /// spoken-correction sentence added, so a proposed wording is always
    /// measured against what ships. The last measurement (2026-09) found
    /// every such sentence at best useless: models strong enough to apply
    /// corrections already do so under "false starts", and the small local
    /// models were made worse, not better, with an explicit sentence turning
    /// legitimate uses like "no wait for my signal before you deploy" into
    /// mangled commands. That is why the shipping prompt has no such
    /// sentence and this probe exists to re-check before one is ever added.
    private func promptVariants() throws -> [(label: String, prompt: String)] {
        let base = RewriteProfile.defaultPrompt(for: "cleanup")
        let candidateSentence = "When the speaker clearly corrects themselves aloud, keep only their final version and drop the retracted words; if it could be part of the sentence rather than a correction, keep the words as spoken. "
        guard let anchor = base.range(of: "Fix punctuation") else {
            XCTFail("The cleanup prompt changed shape; update the probe's insertion anchor.")
            return []
        }
        var candidate = base
        candidate.insert(contentsOf: candidateSentence, at: anchor.lowerBound)
        return [("base", base), ("new", candidate)]
    }

    func testProbeSpokenCorrections() async throws {
        guard ProcessInfo.processInfo.environment["MICMYDAY_PROBE_REWRITE"] == "1" else {
            throw XCTSkip("Probe not requested.")
        }
        guard AppleOnDeviceRewriter.availability.isAvailable else {
            throw XCTSkip("On-device model unavailable: \(AppleOnDeviceRewriter.availability)")
        }
        // The model is nondeterministic, so each dictation runs three times;
        // a wording only counts as working when it holds across repeats.
        for (label, prompt) in try promptVariants() {
            for dictation in Self.dictations {
                for attempt in 1...3 {
                    do {
                        let out = try await AppleOnDeviceRewriter.rewrite(dictation, systemPrompt: prompt)
                        print("PROBE[apple-\(label)#\(attempt)] \"\(dictation)\" -> \"\(out)\"")
                    } catch {
                        print("PROBE[apple-\(label)#\(attempt)] \"\(dictation)\" -> ERROR \(error)")
                    }
                }
            }
        }
    }

    /// Points at a directory holding GGUF files named as in the catalog, so
    /// the probe exercises exactly what a user would download.
    func testProbeSpokenCorrectionsOnLocalModels() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MICMYDAY_PROBE_REWRITE_GGUF_DIR"] else {
            throw XCTSkip("No GGUF directory provided.")
        }
        for model in RewriteModelCatalog.downloadable {
            guard let download = model.download else { continue }
            let path = (dir as NSString).appendingPathComponent(download.file)
            guard FileManager.default.fileExists(atPath: path) else {
                print("PROBE[\(model.id)] model file missing, skipped")
                continue
            }
            for (label, prompt) in try promptVariants() {
                for dictation in Self.dictations {
                    for attempt in 1...3 {
                        do {
                            let out = try await LlamaCppEngine.shared.rewrite(
                                transcript: dictation,
                                systemPrompt: prompt,
                                modelPath: path,
                                format: download.format
                            )
                            print("PROBE[\(model.id)-\(label)#\(attempt)] \"\(dictation)\" -> \"\(out)\"")
                        } catch {
                            print("PROBE[\(model.id)-\(label)#\(attempt)] \"\(dictation)\" -> ERROR \(error)")
                        }
                    }
                }
            }
            LlamaCppEngine.shared.unloadIfCached(modelPath: path)
        }
    }
}
