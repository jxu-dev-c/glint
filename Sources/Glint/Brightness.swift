import CoreGraphics
import Foundation
import IOKit

// MARK: - Private API

// DisplayServices: brightness for the built-in panel and Apple displays (Studio Display, Pro Display XDR).
private enum DisplayServices {
    typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    static let canChange: CanChange? = symbol("DisplayServicesCanChangeBrightness")
    static let get: Get? = symbol("DisplayServicesGetBrightness")
    static let set: Set? = symbol("DisplayServicesSetBrightness")

    static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}

// IOAVService: I²C to external displays on Apple Silicon (exported by IOKit, not in its headers).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn

// MARK: - DDC/CI

/// One external display's DDC channel. All I²C traffic runs on a private serial queue.
private final class DDCChannel: @unchecked Sendable {
    private let service: CFTypeRef
    private let queue = DispatchQueue(label: "glint.ddc")
    private var pending: UInt16?
    private var flushScheduled = false
    private var maxValue: UInt16 = 100

    private static let brightnessVCP: UInt8 = 0x10

    init(service: CFTypeRef) { self.service = service }

    /// Reads current brightness (0...1) in the background; nil if the monitor doesn't answer.
    func read(completion: @escaping @Sendable (Float?) -> Void) {
        queue.async {
            var reply = [UInt8](repeating: 0, count: 11)
            guard self.transfer(send: [Self.brightnessVCP], reply: &reply),
                  reply[0] == 0x6E,
                  reply[2] == 0x02,
                  reply[3] == 0x00,
                  reply[4] == Self.brightnessVCP else { return completion(nil) }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            guard max > 0 else { return completion(nil) }
            self.maxValue = max
            completion(Float(min(current, max)) / Float(max))
        }
    }

    /// Sets brightness (0...1). Rapid calls are coalesced so the monitor sees at most one write per 50 ms.
    func write(_ value: Float) {
        queue.async {
            self.pending = UInt16((value * Float(self.maxValue)).rounded())
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                self.flushScheduled = false
                guard let v = self.pending else { return }
                self.pending = nil
                var none: [UInt8] = []
                _ = self.transfer(send: [Self.brightnessVCP, UInt8(v >> 8), UInt8(v & 0xFF)], reply: &none)
            }
        }
    }

    /// One DDC/CI exchange with retries. A 1-byte `send` is a "get VCP", a 3-byte one a "set VCP".
    private func transfer(send: [UInt8], reply: inout [UInt8]) -> Bool {
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        packet[packet.count - 1] = packet.dropLast().reduce(0x6E ^ 0x51, ^)

        for _ in 0..<4 {
            var ok = false
            for _ in 0..<2 {
                usleep(10_000)
                if IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
            }
            if ok, !reply.isEmpty {
                usleep(50_000)
                ok = IOAVServiceReadI2C(service, 0x37, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess
                    && reply.dropLast().reduce(0x50, ^) == reply[reply.count - 1]
            }
            if ok { return true }
            usleep(20_000)
        }
        return false
    }

    /// Pairs each external display with its DDC channel. On Apple Silicon each framebuffer
    /// (with the panel's EDID-derived attributes) is followed in the registry by its DCPAVServiceProxy.
    static func discover(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCChannel] {
        var found: [(attrs: [String: Any], service: CFTypeRef)] = []
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var lastAttrs: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMobileFramebufferShim") != 0 || IOObjectConformsTo(entry, "AppleCLCD2") != 0 {
                let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                lastAttrs = attrs?["ProductAttributes"] as? [String: Any]
            } else if IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0,
                      let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                          .takeRetainedValue() as? String,
                      location == "External",
                      let attrs = lastAttrs,
                      let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                found.append((attrs, service))
                lastAttrs = nil
            }
        }

        var result: [CGDirectDisplayID: DDCChannel] = [:]
        for id in displays where CGDisplayIsBuiltin(id) == 0 {
            func score(_ a: [String: Any]) -> Int {
                guard (a["LegacyManufacturerID"] as? UInt32) == CGDisplayVendorNumber(id),
                      (a["ProductID"] as? UInt32) == CGDisplayModelNumber(id) else { return 0 }
                return (a["SerialNumber"] as? UInt32) == CGDisplaySerialNumber(id) ? 2 : 1
            }
            guard let best = found.indices.max(by: { score(found[$0].attrs) < score(found[$1].attrs) }),
                  score(found[best].attrs) > 0 else { continue }
            result[id] = DDCChannel(service: found.remove(at: best).service)
        }
        return result
    }
}

// MARK: - Controller

/// Brightness for every display: DisplayServices where macOS supports it (built-in and Apple displays),
/// DDC/CI for other monitors, and gamma-table dimming when a monitor doesn't answer DDC
/// (for example over the HDMI port of an Apple Silicon Mac).
@MainActor
final class Brightness {
    private let defaults: UserDefaults
    private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    private var cached: [CGDirectDisplayID: Float] = [:]
    private var knownDisplays: Set<CGDirectDisplayID> = []

    /// Called when a DDC read finishes (or falls back to software) after the menu has been built.
    var onRead: ((CGDirectDisplayID, Float) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Re-pairs DDC channels when displays are connected or removed, and reads new ones.
    func update(displays: [CGDirectDisplayID]) {
        guard Set(displays) != knownDisplays else { return }
        knownDisplays = Set(displays)
        for id in displays where !isNative(id) && cached[id] == nil {
            cached[id] = loadSaved(id)
        }
        channels = DDCChannel.discover(for: displays.filter { !isNative($0) })
        for id in displays where channels[id] == nil && !isNative(id) {
            if let v = cached[id], v < 1 { applyGamma(id, v) }
        }
        for (id, channel) in channels {
            channel.read { value in
                Task { @MainActor [weak self] in
                    guard let self, self.channels[id] === channel else { return }
                    if let value {
                        if let saved = self.cached[id] ?? self.loadSaved(id) {
                            self.cached[id] = saved
                            if abs(saved - value) > 0.01 { channel.write(saved) }
                        } else {
                            self.cached[id] = value
                            self.save(id, value)
                        }
                    } else {
                        self.channels[id] = nil  // no DDC reply: dim in software instead
                        let v = self.cached[id] ?? self.loadSaved(id) ?? 1
                        self.cached[id] = v
                        if v < 1 { self.applyGamma(id, v) }
                    }
                    self.onRead?(id, self.cached[id] ?? 1)
                }
            }
        }
    }

    /// Current brightness 0...1. DDC monitors show 0.5 until their first read finishes.
    func value(_ id: CGDirectDisplayID) -> Float {
        if isNative(id), let get = DisplayServices.get {
            var v: Float = 0
            if get(id, &v) == 0 { return v }
        }
        if let v = cached[id] ?? loadSaved(id) { return v }
        return channels[id] != nil ? 0.5 : 1
    }

    func set(_ id: CGDirectDisplayID, _ value: Float) {
        let v = min(max(value, 0), 1)
        if isNative(id) {
            _ = DisplayServices.set?(id, v)
            return
        }
        cached[id] = v
        save(id, v)
        if let channel = channels[id] {
            channel.write(v)
        } else {
            applyGamma(id, v)
        }
    }

    /// macOS resets gamma tables on display changes and wake; put software dimming back.
    func reapplySoftwareDimming() {
        for (id, v) in cached where knownDisplays.contains(id) && channels[id] == nil && !isNative(id) { applyGamma(id, v) }
    }

    /// Undo software dimming (on quit).
    func restore() { CGDisplayRestoreColorSyncSettings() }

    private func loadSaved(_ id: CGDirectDisplayID) -> Float? {
        guard let number = defaults.object(forKey: Display.storageKey(for: id)) as? NSNumber else { return nil }
        return min(max(number.floatValue, 0), 1)
    }

    private func save(_ id: CGDirectDisplayID, _ value: Float) {
        defaults.set(value, forKey: Display.storageKey(for: id))
    }

    private func applyGamma(_ id: CGDirectDisplayID, _ v: Float) {
        let level = 0.15 + 0.85 * v  // never fully black
        CGSetDisplayTransferByFormula(id, 0, level, 1, 0, level, 1, 0, level, 1)
    }

    private func isNative(_ id: CGDirectDisplayID) -> Bool { DisplayServices.canChange?(id) ?? false }
}
