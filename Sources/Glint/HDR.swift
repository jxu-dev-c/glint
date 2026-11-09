import CoreGraphics
import Darwin

/// HDR on/off via private SkyLight calls (the same switch as System Settings › Displays › High Dynamic Range).
/// Resolved at runtime so a missing symbol hides the toggle instead of crashing.
enum HDR {
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Setter = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private nonisolated(unsafe) static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let supportsFn: Query? = symbol("SLSDisplaySupportsHDRMode")
    private static let isEnabledFn: Query? = symbol("SLSDisplayIsHDRModeEnabled")
    private static let setEnabledFn: Setter? = symbol("SLSDisplaySetHDRModeEnabled")

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let sym = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static func isSupported(_ id: CGDirectDisplayID) -> Bool {
        guard let supportsFn, isEnabledFn != nil, setEnabledFn != nil else { return false }
        return supportsFn(id)
    }

    static func isEnabled(_ id: CGDirectDisplayID) -> Bool { isEnabledFn?(id) ?? false }

    static func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) { _ = setEnabledFn?(id, on) }
}
