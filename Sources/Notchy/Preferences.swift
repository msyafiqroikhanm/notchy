import Foundation
import ServiceManagement

/// UserDefaults-backed settings. Every property persists on change; invalid values are rejected at the
/// setter methods (applyLocation) or prevented by bounded UI controls, never silently corrected.
final class Preferences: ObservableObject {
    static let ringSources = ["battery", "water"]
    static let jakartaLatitude = -6.2088
    static let jakartaLongitude = 106.8456
    static let jakartaTimeZone = "Asia/Jakarta"

    private let defaults: UserDefaults

    @Published var mascot: Bool { didSet { defaults.set(mascot, forKey: "mascot") } }
    @Published var minimal: Bool { didSet { defaults.set(minimal, forKey: "minimal") } }
    @Published var ringSource: String { didSet { defaults.set(ringSource, forKey: "ringSource") } }
    @Published var lyricsEnabled: Bool { didSet { defaults.set(lyricsEnabled, forKey: "lyricsEnabled") } }
    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: "clipboardEnabled") } }

    @Published var waterGoal: Int { didSet { defaults.set(waterGoal, forKey: "waterGoal") } }
    @Published var waterServing: Int { didSet { defaults.set(waterServing, forKey: "waterServing") } }
    @Published var waterInterval: Int { didSet { defaults.set(waterInterval, forKey: "waterInterval") } }
    @Published var waterStartHour: Int { didSet { defaults.set(waterStartHour, forKey: "waterStartHour") } }
    @Published var waterEndHour: Int { didSet { defaults.set(waterEndHour, forKey: "waterEndHour") } }
    @Published var waterReminders: Bool { didSet { defaults.set(waterReminders, forKey: "waterReminders") } }

    @Published var prayerEnabled: Bool { didSet { defaults.set(prayerEnabled, forKey: "prayerEnabled") } }
    @Published private(set) var latitude: Double {
        didSet { defaults.set(latitude, forKey: "latitude"); if oldValue != latitude { locationConfirmed = false } }
    }
    @Published private(set) var longitude: Double {
        didSet { defaults.set(longitude, forKey: "longitude"); if oldValue != longitude { locationConfirmed = false } }
    }
    @Published private(set) var timeZoneID: String {
        didSet { defaults.set(timeZoneID, forKey: "timeZoneID"); if oldValue != timeZoneID { locationConfirmed = false } }
    }
    @Published var locationConfirmed: Bool { didSet { defaults.set(locationConfirmed, forKey: "locationConfirmed") } }
    @Published var prayerReminders: Bool { didSet { defaults.set(prayerReminders, forKey: "prayerReminders") } }
    @Published var prayerPauseMusic: Bool { didSet { defaults.set(prayerPauseMusic, forKey: "prayerPauseMusic") } }

    /// Actual SMAppService status, not the requested one. Call refreshLogin() after external changes.
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "mascot": true, "minimal": false, "ringSource": "battery",
            "lyricsEnabled": false, "clipboardEnabled": false,
            "waterGoal": 1500, "waterServing": 250, "waterInterval": 60,
            "waterStartHour": 8, "waterEndHour": 21, "waterReminders": false,
            "prayerEnabled": true, "latitude": Self.jakartaLatitude, "longitude": Self.jakartaLongitude,
            "timeZoneID": Self.jakartaTimeZone, "locationConfirmed": false,
            "prayerReminders": false, "prayerPauseMusic": false,
        ])
        mascot = defaults.bool(forKey: "mascot")
        minimal = defaults.bool(forKey: "minimal")
        let ring = defaults.string(forKey: "ringSource") ?? "battery"
        ringSource = Self.ringSources.contains(ring) ? ring : "battery"
        lyricsEnabled = defaults.bool(forKey: "lyricsEnabled")
        clipboardEnabled = defaults.bool(forKey: "clipboardEnabled")

        let goal = defaults.integer(forKey: "waterGoal")
        waterGoal = goal > 0 ? goal : 1500
        let serving = defaults.integer(forKey: "waterServing")
        waterServing = serving > 0 ? serving : 250
        let interval = defaults.integer(forKey: "waterInterval")
        waterInterval = interval > 0 ? interval : 60
        var start = defaults.integer(forKey: "waterStartHour")
        var end = defaults.integer(forKey: "waterEndHour")
        if !(0...23).contains(start) || !(1...24).contains(end) || start >= end { start = 8; end = 21 }
        waterStartHour = start
        waterEndHour = end
        waterReminders = defaults.bool(forKey: "waterReminders")

        prayerEnabled = defaults.bool(forKey: "prayerEnabled")
        let lat = defaults.double(forKey: "latitude")
        let lon = defaults.double(forKey: "longitude")
        let tz = defaults.string(forKey: "timeZoneID") ?? Self.jakartaTimeZone
        let valid = Self.locationError(latitude: lat, longitude: lon, timeZoneID: tz) == nil
        latitude = valid ? lat : Self.jakartaLatitude
        longitude = valid ? lon : Self.jakartaLongitude
        timeZoneID = valid ? tz : Self.jakartaTimeZone
        locationConfirmed = valid && defaults.bool(forKey: "locationConfirmed")
        prayerReminders = defaults.bool(forKey: "prayerReminders")
        prayerPauseMusic = defaults.bool(forKey: "prayerPauseMusic")
        refreshLogin()
    }

    static func locationError(latitude: Double, longitude: Double, timeZoneID: String) -> String? {
        if !latitude.isFinite || !(-90...90).contains(latitude) { return "Lintang harus antara −90 dan 90." }
        if !longitude.isFinite || !(-180...180).contains(longitude) { return "Bujur harus antara −180 dan 180." }
        if TimeZone(identifier: timeZoneID) == nil { return "Zona waktu “\(timeZoneID)” tidak dikenal. Contoh: Asia/Jakarta." }
        return nil
    }

    /// Returns an error message and leaves stored values untouched when invalid. Changing any value resets locationConfirmed.
    @discardableResult
    func applyLocation(latitude: Double, longitude: Double, timeZoneID: String) -> String? {
        if let error = Self.locationError(latitude: latitude, longitude: longitude, timeZoneID: timeZoneID) { return error }
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneID = timeZoneID
        return nil
    }

    var isJakartaPreset: Bool {
        latitude == Self.jakartaLatitude && longitude == Self.jakartaLongitude && timeZoneID == Self.jakartaTimeZone
    }

    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLogin(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Perlu persetujuan di Pengaturan Sistem › Item Login." : nil
        } catch {
            loginError = "Gagal mengubah login otomatis: \(error.localizedDescription)"
        }
        refreshLogin()
    }
}
