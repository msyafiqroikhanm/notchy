import Foundation
import Combine
import CoreAudio
import IOKit.ps

/// Structured device change; the presentation is built by the app, never parsed from text.
enum DeviceEvent: Equatable {
    case powerConnected, powerDisconnected
    case bluetooth(name: String)
}

/// Pure transition logic: first observation only records state, later changes emit one event.
struct DeviceTransitions {
    private var pluggedIn: Bool?
    private var bluetoothOutput: String?? // outer nil = never observed

    mutating func power(pluggedIn now: Bool) -> DeviceEvent? {
        defer { pluggedIn = now }
        guard let old = pluggedIn, old != now else { return nil }
        return now ? .powerConnected : .powerDisconnected
    }

    /// `bluetoothName` is the output device name when its transport is Bluetooth, else nil.
    mutating func output(bluetoothName now: String?) -> DeviceEvent? {
        defer { bluetoothOutput = .some(now) }
        guard let old = bluetoothOutput, old != now, let name = now else { return nil }
        return .bluetooth(name: name)
    }
}

final class DeviceMonitor: ObservableObject {
    @Published private(set) var batteryProgress: Double?
    @Published private(set) var batteryLabel = ""
    @Published private(set) var isPluggedIn = false
    /// IOKit's own charging flag; nil when there is no battery or the source does not report it.
    /// AC connection alone is not proof of charging.
    @Published private(set) var isCharging: Bool?
    @Published private(set) var outputName = "Tidak diketahui"
    @Published private(set) var outputIsBluetooth = false

    var onEvent: (DeviceEvent) -> Void = { _ in }

    /// User-facing power state that only says "charging" when IOKit says so.
    static func powerTitle(pluggedIn: Bool, charging: Bool?) -> String {
        if charging == true { return "Mengisi daya" }
        return pluggedIn ? "Daya tersambung" : "Memakai baterai"
    }

    /// No percentage (and no implied zero) when the battery is unavailable.
    static func batteryText(_ progress: Double?) -> String {
        progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Baterai tidak tersedia"
    }

    private var transitions = DeviceTransitions()
    private var powerSource: CFRunLoopSource?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var nameListener: AudioObjectPropertyListenerBlock?
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    private var isShutdown = false

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init() {
        refreshPower()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(ctx).takeUnretainedValue().refreshPower()
        }, ctx)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }

        refreshOutput()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshOutput() }
        defaultListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, block)
    }

    deinit { shutdown() }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        if let src = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            CFRunLoopSourceInvalidate(src)
            powerSource = nil
        }
        if let block = defaultListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, block)
            defaultListener = nil
        }
        unwatchName()
    }

    // MARK: Power

    private func refreshPower() {
        guard !isShutdown else { return }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let pct = Swift.min(100, Swift.max(0, cur * 100 / max))
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            batteryProgress = Double(pct) / 100
            batteryLabel = "\(pct)%"
            isPluggedIn = plugged
            isCharging = d[kIOPSIsChargingKey] as? Bool
            if let event = transitions.power(pluggedIn: plugged) { onEvent(event) }
            return
        }
        batteryProgress = nil
        batteryLabel = ""
        isCharging = nil
    }

    // MARK: Audio

    private func refreshOutput() {
        guard !isShutdown else { return }
        let device = Self.defaultOutputDevice()
        let name = device.flatMap(Self.name) ?? "Tidak diketahui"
        let bt = device.map(Self.isBluetooth) ?? false
        outputName = name
        outputIsBluetooth = bt
        if device != watchedDevice { watchName(device) }
        if let event = transitions.output(bluetoothName: bt ? name : nil) { onEvent(event) }
    }

    private func watchName(_ device: AudioObjectID?) {
        unwatchName()
        guard let device = device else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshOutput() }
        if AudioObjectAddPropertyListenerBlock(device, &Self.nameAddress, .main, block) == noErr {
            nameListener = block
            watchedDevice = device
        }
    }

    private func unwatchName() {
        if let block = nameListener {
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &Self.nameAddress, .main, block)
        }
        nameListener = nil
        watchedDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &id)
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func name(_ device: AudioObjectID) -> String? {
        var addr = nameAddress
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cf) == noErr,
              let s = cf?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: Selftest

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "DeviceMonitor.selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        var t = DeviceTransitions()
        try check(t.power(pluggedIn: false) == nil, "launch power must be silent")
        try check(t.power(pluggedIn: false) == nil, "duplicate power must be silent")
        try check(t.power(pluggedIn: true) == .powerConnected, "connect event")
        try check(t.power(pluggedIn: true) == nil, "duplicate connect silent")
        try check(t.power(pluggedIn: false) == .powerDisconnected, "disconnect event")

        try check(t.output(bluetoothName: "AirPods") == nil, "launch output must be silent")
        try check(t.output(bluetoothName: "AirPods") == nil, "duplicate output silent")
        try check(t.output(bluetoothName: nil) == nil, "leaving bluetooth silent")
        try check(t.output(bluetoothName: "Buds") == .bluetooth(name: "Buds"), "bluetooth transition event")
        try check(t.output(bluetoothName: "Speaker") == .bluetooth(name: "Speaker"), "switch between bluetooth devices")

        // Charging is claimed only on IOKit's flag; AC alone or an unknown flag is "connected".
        let charging = powerTitle(pluggedIn: true, charging: true)
        for (plugged, flag) in [(true, nil), (true, false), (false, nil), (false, false)] as [(Bool, Bool?)] {
            try check(powerTitle(pluggedIn: plugged, charging: flag) != charging, "no charging claim for AC=\(plugged) flag=\(String(describing: flag))")
        }
        try check(powerTitle(pluggedIn: true, charging: nil) != powerTitle(pluggedIn: false, charging: nil), "connected differs from battery")
        try check(!batteryText(nil).contains("%") && !batteryText(nil).contains("0"), "nil battery shows no percentage")
        try check(batteryText(0.426) == "43%", "battery percentage")
    }
}
