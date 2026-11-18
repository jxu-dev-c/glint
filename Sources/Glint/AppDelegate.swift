import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let brightness = Brightness()
    private var sliders: [CGDirectDisplayID: BrightnessSlider] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Glint")
        image?.isTemplate = true
        statusItem.button?.image = image
        menu.delegate = self
        statusItem.menu = menu

        brightness.onRead = { [weak self] id, value in self?.sliders[id]?.value = value }
        brightness.update(displays: Display.all().map(\.id))

        let reapply: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.brightness.update(displays: Display.all().map(\.id))
                self.brightness.reapplySoftwareDimming()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reapply)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reapply)
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window == button.window else { return event }
            let delta = BrightnessSlider.delta(for: event)
            guard delta != 0 else { return event }
            let screenID = (event.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let targetID = screenID ?? Display.all().first(where: { !$0.isBuiltin })?.id ?? Display.all().first?.id
            guard let id = targetID else { return event }
            let updated = min(max(self.brightness.value(id) + delta, 0), 1)
            self.brightness.set(id, updated)
            self.sliders[id]?.value = updated
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        brightness.restore()
    }

    // Rebuilt every time it opens, so it always reflects the connected displays and their current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sliders.removeAll()
        let displays = Display.all()
        brightness.update(displays: displays.map(\.id))

        for display in displays {
            menu.addItem(.sectionHeader(title: display.name))
            addBrightness(for: display.id, to: menu)
            addResolutions(for: display.id, to: menu)
            if HDR.isSupported(display.id) {
                let item = menu.addItem(withTitle: "HDR", action: #selector(toggleHDR(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(display.id)
                item.state = HDR.isEnabled(display.id) ? .on : .off
            }
            menu.addItem(.separator())
        }

        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func addBrightness(for id: CGDirectDisplayID, to menu: NSMenu) {
        let slider = BrightnessSlider(value: brightness.value(id)) { [weak self] value in
            self?.brightness.set(id, value)
        }
        sliders[id] = slider
        let item = NSMenuItem()
        item.view = slider
        menu.addItem(item)
    }

    private func addResolutions(for id: CGDirectDisplayID, to menu: NSMenu) {
        let options = Resolution.options(for: id)
        guard !options.isEmpty else { return }
        let submenu = NSMenu()
        let rates = Resolution.refreshRates(for: id)
        if rates.count > 1 {
            submenu.addItem(.sectionHeader(title: "Refresh Rate"))
            for rate in rates {
                let item = submenu.addItem(withTitle: rate.title, action: #selector(selectResolution(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(id)
                item.representedObject = rate.mode
                item.state = rate.isCurrent ? .on : .off
            }
            submenu.addItem(.separator())
            submenu.addItem(.sectionHeader(title: "Resolution"))
        }
        for option in options {
            let item = submenu.addItem(withTitle: option.title, action: #selector(selectResolution(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            item.representedObject = option.mode
            item.state = option.isCurrent ? .on : .off
        }
        let current = options.first(where: \.isCurrent)?.summary ?? "—"
        let item = menu.addItem(withTitle: "Resolution: \(current)", action: nil, keyEquivalent: "")
        item.submenu = submenu
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard let object = sender.representedObject as AnyObject?, CFGetTypeID(object) == CGDisplayMode.typeID else { return }
        Resolution.apply(unsafeDowncast(object, to: CGDisplayMode.self), to: CGDirectDisplayID(sender.tag))
    }

    @objc private func toggleHDR(_ sender: NSMenuItem) {
        HDR.setEnabled(CGDirectDisplayID(sender.tag), sender.state != .on)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            alert.runModal()
        }
    }
}

/// Sun icon, slider and percentage, laid out to sit inside a menu like the system's own controls.
@MainActor
final class BrightnessSlider: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private let onChange: (Float) -> Void

    var value: Float {
        get { slider.floatValue }
        set { slider.floatValue = newValue; updateLabel() }
    }

    init(value: Float, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 26))

        let icon = NSImageView(frame: NSRect(x: 16, y: 5, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "sun.min", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor

        slider.frame = NSRect(x: 38, y: 3, width: 168, height: 20)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)

        label.frame = NSRect(x: 210, y: 5, width: 40, height: 16)
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor

        [icon, slider, label].forEach(addSubview)
        self.value = value
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() {
        updateLabel()
        onChange(slider.floatValue)
    }

    override func scrollWheel(with event: NSEvent) {
        let d = Self.delta(for: event)
        guard d != 0 else { return }
        let clamped = min(max(value + d, 0), 1)
        guard clamped != value else { return }
        value = clamped
        onChange(clamped)
    }

    static func delta(for event: NSEvent) -> Float {
        let raw = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX
        guard raw != 0 else { return 0 }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? (1.0 / 200.0) : 0.02
        return Float(raw * scale)
    }

    private func updateLabel() { label.stringValue = "\(Int((slider.floatValue * 100).rounded()))%" }
}
