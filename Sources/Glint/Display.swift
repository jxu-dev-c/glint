import AppKit

/// An online display, as the menu shows it.
struct Display {
    let id: CGDirectDisplayID
    let name: String

    var isBuiltin: Bool { CGDisplayIsBuiltin(id) != 0 }
    var storageKey: String { Self.storageKey(for: id) }

    /// Stable identifier (vendor-model-serial) for persisting per-display settings across restarts and reconnects.
    static func storageKey(for id: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(id)
        guard vendor != 0xFFFF_FFFF else { return "brightness.\(id)" }
        return "brightness.\(vendor)-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// Active displays in screen order (main display first). Mirrored displays appear once.
    @MainActor
    static func all() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return Display(id: number.uint32Value, name: screen.localizedName)
        }
    }
}
