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
        _ = WhisperCppEngine.shared.unloadForTermination()
    }
}
