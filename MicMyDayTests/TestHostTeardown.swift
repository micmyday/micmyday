import XCTest
@testable import MicMyDay

/// Stops the test host aborting as it exits.
///
/// whisper.cpp's Metal backend asserts in an `atexit` destructor if a context
/// is still loaded, which turns the end of a test run into a crash report, even
/// when every test passed. The app itself already handles this when it quits;
/// the test host had nobody doing the same, so every run that touched a local
/// model left a crash log behind.
///
/// Registered automatically: XCTest instantiates every `NSObject` subclass
/// conforming to `XCTestObservation` that the bundle declares as a principal
/// observer, and this one asks to be told when the run finishes.
@objc(TestHostTeardown)
final class TestHostTeardown: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillFinish(_ testBundle: Bundle) {
        // Freed explicitly, before the C++ destructors run, which is the whole
        // point: by the time `atexit` handlers fire it is too late to do this
        // and the assert has already tripped.
        //
        // Both engines, for the same reason the app frees both. whisper.cpp
        // and llama.cpp each carry their own copy of ggml, each with its own
        // list of Metal devices torn down at exit, and each asserting about
        // its own residency sets. Freeing one leaves the other to abort, which
        // is precisely what happened while only the transcriber was unloaded:
        // runs failed in llama's copy of ggml-metal rather than whisper's.
        let transcriber = WhisperCppEngine.shared.unloadForTermination()
        let rewriter = LlamaCppEngine.shared.unloadForTermination()

        // Said out loud rather than discarded. An unload that times out leaves
        // the run heading for the same abort, and the crash report that
        // follows names ggml rather than anything here — so the one line that
        // would explain it has to be printed before the process dies.
        if !transcriber || !rewriter {
            let stuck = [transcriber ? nil : "transcriber", rewriter ? nil : "rewriter"]
                .compactMap { $0 }
                .joined(separator: " and ")
            print("TestHostTeardown: the \(stuck) did not unload in time; this run may abort in ggml at exit.")
        }
    }
}
