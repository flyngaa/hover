import Foundation
import HoverCore

/// Reads and requests the privacy permission macOS lists under **System Audio
/// Recording Only**.
///
/// Core Audio publishes no preflight for it, and an unauthorized process tap
/// starts happily and then delivers silence — so trying to capture is not a
/// usable test. The state lives in TCC under `kTCCServiceAudioCapture`, which
/// is reachable only through that framework's unpublished entry points; every
/// lookup here is optional so a future macOS that moves them leaves Hover on
/// its remembered-outcome fallback instead of broken.
enum SystemAudioAccess {

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request =
        @convention(c) (
            CFString,
            CFDictionary?,
            @escaping (Bool) -> Void
        ) -> Void

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    /// `nil` when the lookup is unavailable — the caller decides what to assume.
    static var current: PermissionState? {
        guard let preflight else { return nil }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notRequested
        }
    }

    /// Shows the macOS prompt. The answer arrives long after this returns, and
    /// Core Audio only picks up a fresh grant on the next launch.
    static func request() {
        requestAccess?(service, nil) { _ in }
    }

    nonisolated(unsafe) private static let library: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC",
        RTLD_NOW
    )

    private static let preflight: Preflight? = entryPoint("TCCAccessPreflight")
    private static let requestAccess: Request? = entryPoint("TCCAccessRequest")

    private static func entryPoint<Signature>(_ name: String) -> Signature? {
        guard let library, let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: Signature.self)
    }
}
