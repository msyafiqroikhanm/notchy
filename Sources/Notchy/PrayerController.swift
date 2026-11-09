import AppKit
import Combine

enum Prayer: String, CaseIterable {
    case fajr, dhuhr, asr, maghrib, isha

    var name: String {
        switch self {
        case .fajr: return "Subuh"
        case .dhuhr: return "Zuhur"
        case .asr: return "Asar"
        case .maghrib: return "Magrib"
        case .isha: return "Isya"
        }
    }
}

/// One local calendar day. nil = the solar event does not occur at this latitude/date; never invented.
struct PrayerDay {
    var fajr, sunrise, dhuhr, asr, maghrib, isha: Date?

    func time(_ p: Prayer) -> Date? {
        switch p {
        case .fajr: return fajr
        case .dhuhr: return dhuhr
        case .asr: return asr
        case .maghrib: return maghrib
        case .isha: return isha
        }
    }

    /// Every defined event, sunrise included, for timer scheduling.
    var moments: [Date] { [fajr, sunrise, dhuhr, asr, maghrib, isha].compactMap { $0 } }
}

/// Pure solar calculation: Kemenag Fajr -20°, Isha -18°, Asr shadow factor 1, sunset -0.833°, Dhuhr at solar noon.
/// Sun position follows the PrayTimes low-precision model, re-evaluated at each event time (iterated).
enum PrayerCalc {
    static let fajrAngle = 20.0, ishaAngle = 18.0, asrFactor = 1.0, horizonAngle = 0.833

    private struct Sun { let declination: Double; let equation: Double }   // radians, hours

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }
    private static func fix(_ a: Double, _ b: Double) -> Double { a - b * floor(a / b) }

    private static func sun(_ jd: Double) -> Sun {
        let d = jd - 2451545.0
        let g = rad(fix(357.529 + 0.98560028 * d, 360))
        let q = fix(280.459 + 0.98564736 * d, 360)
        let l = rad(fix(q + 1.915 * sin(g) + 0.020 * sin(2 * g), 360))
        let e = rad(23.439 - 0.00000036 * d)
        let ra = fix(deg(atan2(cos(e) * sin(l), cos(l))) / 15, 24)
        // Wrap to ±12 h so the equinox, where q and ra straddle 0/24, does not jump a day.
        return Sun(declination: asin(sin(e) * sin(l)), equation: fix(q / 15 - ra + 12, 24) - 12)
    }

    private static func julian(_ year: Int, _ month: Int, _ day: Int) -> Double {
        var y = Double(year), m = Double(month)
        if m <= 2 { y -= 1; m += 12 }
        let a = floor(y / 100)
        return floor(365.25 * (y + 4716)) + floor(30.6001 * (m + 1)) + Double(day) + (2 - a + floor(a / 4)) - 1524.5
    }

    /// Hour (local mean solar) at which the sun is at `altitude` radians; nil if it never reaches it.
    private static func altitudeTime(_ s: Sun, _ altitude: Double, _ lat: Double, rising: Bool) -> Double? {
        let c = (sin(altitude) - sin(s.declination) * sin(lat)) / (cos(s.declination) * cos(lat))
        guard abs(c) <= 1 else { return nil }
        let h = deg(acos(c)) / 15
        return 12 - s.equation + (rising ? -h : h)
    }

    private static func solve(_ jd: Double, _ base: Double, _ f: (Sun) -> Double?) -> Double? {
        var t = base
        for _ in 0..<6 {
            guard let n = f(sun(jd + t / 24)) else { return nil }
            t = n
        }
        return t
    }

    /// Times for the calendar day containing `date` in `calendar`'s time zone.
    static func times(on date: Date, latitude: Double, longitude: Double, calendar: Calendar) -> PrayerDay {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let jd0 = julian(c.year!, c.month!, c.day!)
        let midnightUT = (jd0 - 2440587.5) * 86400
        let jd = jd0 - longitude / 360
        let lat = rad(latitude)
        func at(_ base: Double, _ f: (Sun) -> Double?) -> Date? {
            solve(jd, base, f).map { Date(timeIntervalSince1970: midnightUT + ($0 - longitude / 15) * 3600) }
        }
        let horizon = rad(-horizonAngle)
        return PrayerDay(
            fajr: at(5) { altitudeTime($0, rad(-fajrAngle), lat, rising: true) },
            sunrise: at(6) { altitudeTime($0, horizon, lat, rising: true) },
            dhuhr: at(12) { 12 - $0.equation },
            asr: at(13) { s in
                altitudeTime(s, atan(1 / (asrFactor + tan(abs(lat - s.declination)))), lat, rising: false)
            },
            maghrib: at(18) { altitudeTime($0, horizon, lat, rising: false) },
            isha: at(18) { altitudeTime($0, rad(-ishaAngle), lat, rising: false) })
    }
}

/// One delivered reminder: the prayer, its calculated time, and whether this is the 10-minute pre-alert.
struct PrayerReminder: Equatable {
    let prayer: Prayer
    let time: Date
    let isPrealert: Bool
}

/// Sholat: calculated times plus pre/at reminders. Delivery is gated on enabled + confirmed location + reminders.
final class PrayerController: ObservableObject {
    static let preLead: TimeInterval = 600
    static let preGrace: TimeInterval = 60     // a missed pre-alert is skipped, never replayed late
    static let atGrace: TimeInterval = 300     // a prayer reminder up to 5 min late still delivers

    let preferences: Preferences
    var onReminder: (PrayerReminder) -> Void = { _ in }
    var onPauseMusic: () -> Void = {}
    /// Injected clock; selftests control it.
    var now: () -> Date

    private let defaults: UserDefaults
    private static let markerKey = "prayerDelivered"
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var changes: [AnyCancellable] = []
    private var armed = false
    private var started = false
    private var formatter: (String, DateFormatter)?

    init(preferences: Preferences, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.defaults = defaults
        self.now = now
        changes = [preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // Values land after willSet; re-evaluate on the next turn.
            DispatchQueue.main.async { self?.refresh() }
        }]
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh(waking: true) }
        let clock = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh(waking: true) }
        let day = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        observers = [wake, clock, day]
        DispatchQueue.main.async { [weak self] in self?.refresh(waking: true) }
    }

    deinit { shutdown() }

    func shutdown() {
        timer?.invalidate(); timer = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        observers = []
        changes = []
    }

    // MARK: calculation

    var locationError: String? {
        Preferences.locationError(latitude: preferences.latitude, longitude: preferences.longitude,
                                  timeZoneID: preferences.timeZoneID)
    }

    var timeZone: TimeZone { TimeZone(identifier: preferences.timeZoneID) ?? .current }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    var remindersActive: Bool {
        preferences.prayerEnabled && preferences.prayerReminders && preferences.locationConfirmed && locationError == nil
    }

    /// Local day `offset` days from the one containing `t`; nil when location is invalid.
    func day(offset: Int = 0, from t: Date) -> PrayerDay? {
        guard locationError == nil else { return nil }
        let cal = calendar
        guard let d = cal.date(byAdding: .day, value: offset, to: t) else { return nil }
        return PrayerCalc.times(on: d, latitude: preferences.latitude, longitude: preferences.longitude, calendar: cal)
    }

    func events(around t: Date, days: ClosedRange<Int> = -1...1) -> [(prayer: Prayer, date: Date)] {
        days.compactMap { day(offset: $0, from: t) }
            .flatMap { d in Prayer.allCases.compactMap { p in d.time(p).map { (prayer: p, date: $0) } } }
            .sorted { $0.date < $1.date }
    }

    /// First prayer strictly after `t`; rolls into tomorrow (and the day after for sparse high-latitude days).
    func next(after t: Date) -> (prayer: Prayer, date: Date)? {
        events(around: t, days: 0...2).first { $0.date > t }
    }

    func hm(_ d: Date) -> String {
        let id = preferences.timeZoneID
        if formatter?.0 != id {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "HH:mm"
            formatter = (id, f)
        }
        return formatter!.1.string(from: d)
    }

    // MARK: reminders

    private func markers() -> [String: Double] {
        defaults.dictionary(forKey: Self.markerKey) as? [String: Double] ?? [:]
    }

    private struct Due { let fire: Date; let reminder: PrayerReminder }

    /// Marks every reminder whose time has passed, delivers only the newest one that is still timely.
    /// With `deliver` false (gate just opened) nothing is announced, so enabling never replays the past.
    func check(deliver: Bool = true, allowPre: Bool = true) {
        guard remindersActive else { return }
        let t = now()
        var done = markers()
        var due: [Due] = []
        for (p, d) in events(around: t) {
            let slots: [(String, Date, TimeInterval)] = [
                ("pre", d.addingTimeInterval(-Self.preLead), Self.preGrace),
                ("at", d, Self.atGrace),
            ]
            for (kind, fire, grace) in slots where fire <= t {
                let id = "\(p.rawValue)|\(Int(d.timeIntervalSince1970))|\(kind)"
                guard done[id] == nil else { continue }
                done[id] = fire.timeIntervalSince1970
                if deliver && (kind == "at" || allowPre) && t.timeIntervalSince(fire) <= grace {
                    due.append(Due(fire: fire, reminder: PrayerReminder(prayer: p, time: d, isPrealert: kind == "pre")))
                }
            }
        }
        let cutoff = t.addingTimeInterval(-172_800).timeIntervalSince1970
        defaults.set(done.filter { $0.value >= cutoff }, forKey: Self.markerKey)
        if let last = due.max(by: { $0.fire < $1.fire }) {
            onReminder(last.reminder)
            if !last.reminder.isPrealert && preferences.prayerPauseMusic { onPauseMusic() }
        }
    }

    // MARK: scheduling

    /// Wake, clock/day change, preference change or timer: reconcile, redraw, re-arm.
    func refresh(waking: Bool = false) {
        let active = remindersActive
        // Gate opened while running: past events count as already seen.
        check(deliver: !(active && !armed && started), allowPre: !waking)
        armed = active
        started = true
        objectWillChange.send()
        schedule()
    }

    /// One timer to the nearest upcoming prayer/sunrise/reminder moment or local midnight; no polling.
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard preferences.prayerEnabled, locationError == nil else { return }
        let t = now()
        let cal = calendar
        var moments = (0...1).compactMap { day(offset: $0, from: t) }.flatMap { $0.moments }
        if remindersActive { moments += moments.map { $0.addingTimeInterval(-Self.preLead) } }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: t) { moments.append(cal.startOfDay(for: tomorrow)) }
        guard let next = moments.filter({ $0 > t }).min() else { return }
        // +1 s so the clock is never read just before the moment.
        let tm = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in self?.refresh() }
        tm.tolerance = 1
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    // MARK: selftest

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "PrayerSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jakarta
        func at(_ day: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
        }
        func minutes(_ d: Date?) -> Double? {
            d.map { Double(cal.component(.hour, from: $0) * 60 + cal.component(.minute, from: $0)) + Double(cal.component(.second, from: $0)) / 60 }
        }
        func near(_ d: Date?, _ h: Int, _ m: Int, _ label: String) throws {
            guard let got = minutes(d) else { throw NSError(domain: "PrayerSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(label) nil"]) }
            try check(abs(got - Double(h * 60 + m)) <= 2, "\(label) \(got / 60) vs \(h):\(m)")
        }

        // Jakarta 2026-10-15 against the published Kemenag-angle reference.
        let day = PrayerCalc.times(on: at(15, 12), latitude: Preferences.jakartaLatitude,
                                   longitude: Preferences.jakartaLongitude, calendar: cal)
        try near(day.fajr, 4, 13, "fajr")
        try near(day.sunrise, 5, 31, "sunrise")
        try near(day.dhuhr, 11, 38, "dhuhr")
        try near(day.asr, 14, 45, "asr")
        try near(day.maghrib, 17, 46, "maghrib")
        try near(day.isha, 18, 56, "isha")

        // Invalid input is rejected; undefined solar events stay nil at high latitude.
        try check(Preferences.locationError(latitude: 91, longitude: 0, timeZoneID: "Asia/Jakarta") != nil, "lat 91")
        try check(Preferences.locationError(latitude: 0, longitude: 181, timeZoneID: "Asia/Jakarta") != nil, "lon 181")
        try check(Preferences.locationError(latitude: 0, longitude: 0, timeZoneID: "Nope/Zone") != nil, "bad zone")
        try check(Preferences.locationError(latitude: -6.2, longitude: 106.8, timeZoneID: "Asia/Jakarta") == nil, "valid")
        var oslo = Calendar(identifier: .gregorian)
        oslo.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let june = oslo.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let arctic = PrayerCalc.times(on: june, latitude: 69.6496, longitude: 18.9560, calendar: oslo)
        try check(arctic.fajr == nil && arctic.sunrise == nil && arctic.maghrib == nil && arctic.isha == nil,
                  "midnight sun leaves undefined events nil")
        try check(arctic.dhuhr != nil, "dhuhr always defined")

        // Reminders: injected clock, temp defaults, one delivery per event.
        let suite = "notchy.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        try check(!prefs.prayerReminders && !prefs.prayerPauseMusic && !prefs.locationConfirmed, "defaults off")
        var clock = at(15, 9)
        let p = PrayerController(preferences: prefs, defaults: defaults, now: { clock })
        defer { p.shutdown() }
        var texts: [PrayerReminder] = []
        var paused = 0
        p.onReminder = { texts.append($0) }
        p.onPauseMusic = { paused += 1 }
        let maghrib = day.maghrib!
        let isha = day.isha!

        clock = maghrib.addingTimeInterval(-600); p.check()
        try check(texts.isEmpty, "gated: reminders off and location unconfirmed")
        prefs.prayerReminders = true
        p.check()
        try check(texts.isEmpty, "gated: location unconfirmed")
        prefs.locationConfirmed = true
        prefs.prayerPauseMusic = true
        clock = maghrib.addingTimeInterval(-601); p.check(deliver: false)   // gate opens: past is silent
        try check(texts.isEmpty, "gate open is silent")
        clock = maghrib.addingTimeInterval(-600); p.check()
        try check(texts.count == 1 && texts[0] == PrayerReminder(prayer: .maghrib, time: maghrib, isPrealert: true), "pre fires \(texts)")
        p.check()
        try check(texts.count == 1 && paused == 0, "pre once, never pauses")
        clock = maghrib; p.check()
        try check(texts.count == 2 && texts[1] == PrayerReminder(prayer: .maghrib, time: maghrib, isPrealert: false) && paused == 1, "at fires and pauses")
        p.check()
        try check(texts.count == 2 && paused == 1, "at once")
        // Relaunch: persisted markers prevent a repeat.
        let again = PrayerController(preferences: prefs, defaults: defaults, now: { clock.addingTimeInterval(30) })
        defer { again.shutdown() }
        var repeated = 0
        again.onReminder = { _ in repeated += 1 }
        again.check()
        try check(repeated == 0, "relaunch does not repeat")
        // Wake: stale pre-alert skipped, prayer 4 min late delivered once.
        clock = isha.addingTimeInterval(240); p.check()
        try check(texts.count == 3 && texts[2] == PrayerReminder(prayer: .isha, time: isha, isPrealert: false) && paused == 2, "wake delivers late prayer once \(texts)")
        p.check()
        try check(texts.count == 3, "wake once")
        // Across midnight: next prayer rolls to tomorrow; a long sleep stays silent; tomorrow's pre fires once.
        clock = isha.addingTimeInterval(3600)
        let nxt = p.next(after: clock)
        try check(nxt?.prayer == .fajr && cal.component(.day, from: nxt!.date) == 16, "next is tomorrow fajr")
        clock = at(16, 0, 30); p.check()
        try check(texts.count == 3, "stale after midnight sleep silent")
        let fajr16 = nxt!.date
        clock = fajr16.addingTimeInterval(-600); p.check(); p.check()
        try check(texts.count == 4 && texts[3] == PrayerReminder(prayer: .fajr, time: fajr16, isPrealert: true), "tomorrow pre once")
        // A missed pre-alert is skipped, a prayer 6 min late is too.
        clock = fajr16.addingTimeInterval(-300); p.check()
        try check(texts.count == 4, "late pre skipped")
        clock = fajr16.addingTimeInterval(360); p.check()
        try check(texts.count == 4, "6 min late skipped")
        let asr16 = p.day(from: at(16, 12))!.asr!
        clock = asr16.addingTimeInterval(-590)
        p.check(allowPre: false)
        try check(texts.count == 4, "wake skips even a ten-second-late pre-alert")
        clock = asr16
        p.check()
        try check(texts.count == 5, "wake-skipped pre does not suppress prayer-time reminder")
        // Disabled gate is silent.
        prefs.prayerEnabled = false
        clock = day.dhuhr!.addingTimeInterval(86_400); p.check()
        try check(texts.count == 5, "disabled silent")
    }
}
