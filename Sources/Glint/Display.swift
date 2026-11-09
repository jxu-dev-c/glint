import AppKit

/// An online display, as the menu shows it.
struct Display {
    let id: CGDirectDisplayID
    let name: String

    var isBuiltin: Bool { CGDisplayIsBuiltin(id) != 0 }

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
