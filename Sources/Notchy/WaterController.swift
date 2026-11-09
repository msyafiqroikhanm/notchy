import AppKit
import Combine

/// Air: today's intake from LocalStore, goal/serving from Preferences, optional interval reminders.
final class WaterController: ObservableObject {
    let store: LocalStore
    let preferences: Preferences
    var onReminder: (String) -> Void = { _ in }
    /// Injected clock and calendar; selftests control both.
    var now: () -> Date = Date.init
    var calendar: Calendar = .autoupdatingCurrent

    @Published var actionError: String?

    private var anchor: Date
    private var timer: Timer?
    private var midnight: Timer?
    private var observers: [NSObjectProtocol] = []
    private var changes: [AnyCancellable] = []

    init(store: LocalStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        anchor = Date()
        // Forward, don't nest: views observe only this controller.
        changes = [
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            preferences.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
                // Preference values land after willSet; re-arm on the next turn.
                DispatchQueue.main.async { self?.schedule() }
            },
        ]
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        let clock = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        let day = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        observers = [wake, clock, day]
        // Launch counts as the interval start: no prompt at startup.
        anchor = now()
        scheduleMidnight()
        schedule()
    }

    deinit { shutdown() }

    func shutdown() {
        timer?.invalidate(); timer = nil
        midnight?.invalidate(); midnight = nil
        let wakeCenter = NSWorkspace.shared.notificationCenter
        for o in observers { wakeCenter.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        observers = []
        changes = []
    }

    // MARK: today

    var goal: Int { max(1, preferences.waterGoal) }
    var serving: Int { max(1, preferences.waterServing) }

    var entriesToday: [WaterEntry] {
        let t = now()
        return store.state.water.filter { calendar.isDate($0.date, inSameDayAs: t) }
    }

    var total: Int { entriesToday.reduce(0) { $0 + $1.ml } }
    var progress: Double { min(1, Double(total) / Double(goal)) }
    var reached: Bool { total >= goal }

    /// ml per hour of the local day, 24 bins.
    var hourly: [Int] {
        var bins = Array(repeating: 0, count: 24)
        for e in entriesToday { bins[min(23, max(0, calendar.component(.hour, from: e.date)))] += e.ml }
        return bins
    }

    // MARK: actions

    @discardableResult
    func drink() -> Bool {
        let ml = serving
        guard !total.addingReportingOverflow(ml).overflow else {
            actionError = "Jumlah air terlalu besar untuk disimpan."
            return false
        }
        let entry = WaterEntry(date: now(), ml: ml)
        return commit("Minum tidak tersimpan") { $0.water.append(entry) }
    }

    /// Removes the latest entry of today only; earlier days stay untouched.
    @discardableResult
    func undo() -> Bool {
        guard let last = entriesToday.max(by: { $0.date < $1.date }) else { return false }
        return commit("Pembatalan tidak tersimpan") { $0.water.removeAll { $0.id == last.id } }
    }

    private func commit(_ failure: String, _ change: (inout LocalState) -> Void) -> Bool {
        let ok = store.mutate(change)
        actionError = ok ? nil : "\(failure): \(store.error ?? "penyimpanan tidak bisa ditulis")"
        if ok { anchor = now(); schedule() }
        return ok
    }

    // MARK: day rollover

    private func scheduleMidnight() {
        midnight?.invalidate()
        let t = now()
        guard let next = calendar.nextDate(after: t, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        let tm = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.wake() }
        tm.tolerance = 1
        RunLoop.main.add(tm, forMode: .common)
        midnight = tm
    }

    /// Wake, clock change or midnight: redraw today's totals and deliver at most one coalesced reminder.
    func wake() {
        objectWillChange.send()
        scheduleMidnight()
        check()
    }

    // MARK: reminders

    /// Earliest moment the next reminder may fire: anchor + interval moved into the active window.
    func nextDue() -> Date? {
        guard preferences.waterReminders else { return nil }
        let candidate = anchor.addingTimeInterval(Double(max(1, preferences.waterInterval)) * 60)
        return inWindow(candidate) ?? nextWindowStart(after: candidate)
    }

    private func dayStart(_ d: Date) -> Date { calendar.startOfDay(for: d) }
    private func hour(_ h: Int, of d: Date) -> Date { calendar.date(byAdding: .hour, value: h, to: dayStart(d)) ?? d }

    private func inWindow(_ d: Date) -> Date? {
        d >= hour(preferences.waterStartHour, of: d) && d < hour(preferences.waterEndHour, of: d) ? d : nil
    }

    private func nextWindowStart(after d: Date) -> Date {
        let start = hour(preferences.waterStartHour, of: d)
        if d < start { return start }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: dayStart(d)) ?? d.addingTimeInterval(86400)
        return hour(preferences.waterStartHour, of: tomorrow)
    }

    /// Fires at most once however many intervals were missed, never outside active hours or after the goal.
    func check() {
        let t = now()
        if preferences.waterReminders, let due = nextDue(), due <= t, inWindow(t) != nil, !reached {
            anchor = t
            onReminder("Waktunya minum · \(total)/\(goal) ml")
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard preferences.waterReminders, var due = nextDue() else { return }
        let t = now()
        if due <= t { due = inWindow(t) == nil ? nextWindowStart(after: t) : t.addingTimeInterval(60) }
        // After the goal is met nothing fires until tomorrow's window.
        if reached {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: dayStart(t)) ?? t.addingTimeInterval(86400)
            due = max(due, hour(preferences.waterStartHour, of: tomorrow))
        }
        let tm = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in self?.check() }
        tm.tolerance = 1
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    // MARK: selftest

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "WaterSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchy-water-\(UUID().uuidString)")
        let suite = "notchy.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        try check(!prefs.waterReminders, "reminders default off")
        let store = LocalStore(url: dir.appendingPathComponent("state.json"))
        let w = WaterController(store: store, preferences: prefs)
        defer { w.shutdown() }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        w.calendar = cal
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
        }
        var clock = at(15, 9)
        w.now = { clock }
        w.anchor = clock

        try check(w.total == 0 && w.progress == 0, "empty")
        w.drink(); clock = at(15, 9, 30); w.drink()
        try check(w.total == 500 && w.hourly[9] == 500, "total \(w.total)")
        try check(abs(w.progress - 500.0 / 1500) < 1e-9, "progress")
        w.undo()
        try check(w.total == 250, "undo latest")

        clock = at(16, 0)
        try check(w.total == 0 && w.entriesToday.isEmpty, "midnight clears display")
        try check(store.state.water.count == 1, "history kept")
        try check(!w.undo() && store.state.water.count == 1, "undo never touches previous days")

        // Reminders: off by default → silent.
        var fired = 0
        w.onReminder = { _ in fired += 1 }
        clock = at(16, 12); w.anchor = at(16, 8); w.check()
        try check(fired == 0, "off is silent")
        prefs.waterReminders = true
        prefs.waterInterval = 60
        w.check()
        try check(fired == 1, "due fires")
        w.check()
        try check(fired == 1, "no repeat inside interval")
        // Sleep across many intervals: one prompt only.
        w.anchor = at(16, 9); clock = at(16, 18); w.check()
        try check(fired == 2, "coalesced to one \(fired)")
        // Outside active hours: silent, next due is tomorrow's start.
        w.anchor = at(16, 20, 30); clock = at(16, 22); w.check()
        try check(fired == 2, "outside window silent")
        try check(w.nextDue() == at(17, 8), "next due tomorrow start")
        // Goal reached gates reminders.
        clock = at(17, 10); w.anchor = at(17, 8)
        for _ in 0..<6 { w.drink() }
        w.anchor = at(17, 8); w.check()
        try check(w.reached && fired == 2, "target reached gates")
        prefs.waterServing = Int.max
        let before = store.state
        try check(!w.drink() && store.state == before && w.actionError != nil, "overflow rejects drink without losing history")
    }
}
