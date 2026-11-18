import CoreGraphics

/// Display mode listing and switching, using public CoreGraphics API.
enum Resolution {
    struct Option {
        let mode: CGDisplayMode
        let width: Int
        let height: Int
        let hiDPI: Bool
        let isCurrent: Bool

        var title: String { "\(width) × \(height)" + (hiDPI ? "  HiDPI" : "") }
    }

    /// Desktop-usable modes, one per (size, HiDPI) pair, largest first.
    /// The non-HiDPI duplicate of a size is dropped when a HiDPI variant exists, unless it's in use.
    static func options(for id: CGDirectDisplayID) -> [Option] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return [] }
        let current = CGDisplayCopyDisplayMode(id)

        struct Key: Hashable { let w: Int, h: Int, hiDPI: Bool }
        func key(_ m: CGDisplayMode) -> Key { Key(w: m.width, h: m.height, hiDPI: m.pixelWidth > m.width) }
        let currentKey = current.map(key)

        var best: [Key: CGDisplayMode] = [:]
        for mode in all where mode.isUsableForDesktopGUI() {
            let k = key(mode)
            if k == currentKey { best[k] = current; continue }
            if let existing = best[k], existing.refreshRate >= mode.refreshRate { continue }
            best[k] = mode
        }

        return best
            .filter { k, _ in k.hiDPI || k == currentKey || best[Key(w: k.w, h: k.h, hiDPI: true)] == nil }
            .map { k, m in Option(mode: m, width: k.w, height: k.h, hiDPI: k.hiDPI, isCurrent: k == currentKey) }
            .sorted { ($0.width, $0.height, $0.hiDPI ? 1 : 0) > ($1.width, $1.height, $1.hiDPI ? 1 : 0) }
    }

    static func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        if CGCompleteDisplayConfiguration(config, .permanently) != .success {
            CGCancelDisplayConfiguration(config)
        }
    }
}
