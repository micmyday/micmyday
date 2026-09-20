import CoreGraphics
import IOKit

/// Request the TCC Input Monitoring entry through IOKit, as recommended by
/// Apple DTS: https://developer.apple.com/forums/thread/828052
/// CGPreflightListenEventAccess remains the effective-access check: existing
/// Accessibility permission can already allow the modifier event tap.
struct InputMonitoringPermission {
    private let preflight: () -> Bool
    private let requestAccess: () -> Bool

    init(
        preflight: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        requestAccess: @escaping () -> Bool = { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    ) {
        self.preflight = preflight
        self.requestAccess = requestAccess
    }

    var isGranted: Bool { preflight() }

    @discardableResult
    func request() -> Bool {
        guard !isGranted else { return true }
        _ = requestAccess()
        // Requesting/listing an app isn't the same as the user enabling it.
        return isGranted
    }
}
