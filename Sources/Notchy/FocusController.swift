import AppKit
import Combine

/// Pomodoro state lives in LocalStore as a deadline, so sleep and relaunch never stretch a session.
/// One one-shot timer targets the deadline; wake and launch re-check against the clock.
final class FocusController: ObservableObject {
    static let durations: [String: Double] = ["focus": 25 * 60, "break": 5 * 60]
    static let modeLabels: [(id: String, label: String)] = [("focus", "Fokus 25 mnt"), ("break", "Istirahat 5 mnt")]

    let store: LocalStore
    private let now: () -> Date
    private let onReminder: (String) -> Void
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?
    private var announced: Date?

    init(store: LocalStore, now: @escaping () -> Date = Date.init, onReminder: @escaping (String) -> Void) {
        self.store = store
        self.now = now
        self.onReminder = onReminder
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check() }
        check()
    }

    var session: FocusSession { store.state.focus ?? FocusSession() }
    var running: Bool { session.deadline != nil }
    var finished: Bool { session.deadline == nil && session.remaining <= 0 }
    var error: String? { store.error }

    func remaining(at date: Date) -> Double {
        let s = session
        return s.deadline.map { max(0, $0.timeIntervalSince(date)) } ?? s.remaining
    }

    private func full(_ mode: String) -> Double { Self.durations[mode] ?? 1500 }

    func setMode(_ mode: String) {
        guard Self.durations[mode] != nil, !running else { return }
        store.mutate { $0.focus = FocusSession(mode: mode, deadline: nil, remaining: self.full(mode), delivered: false) }
    }

    func start() {
        check()
        var s = session
        guard s.deadline == nil else { return }
        if s.remaining <= 0 || s.delivered { s = FocusSession(mode: s.mode, remaining: full(s.mode)) }
        s.deadline = now().addingTimeInterval(s.remaining)
        if store.mutate({ $0.focus = s }) { schedule() }
    }

    func pause() {
        check()
        var s = session
        guard let deadline = s.deadline else { return }
        s.remaining = max(0, deadline.timeIntervalSince(now()))
        s.deadline = nil
        if store.mutate({ $0.focus = s }) { schedule() }
    }

    func reset() {
        let mode = session.mode
        if store.mutate({ $0.focus = FocusSession(mode: mode, deadline: nil, remaining: self.full(mode), delivered: false) }) { schedule() }
    }

    /// Delivers an expired session exactly once, then marks it finished.
    func check() {
        let s = session
        guard let deadline = s.deadline, deadline <= now() else { schedule(); return }
        timer?.invalidate()
        timer = nil
        guard store.mutate({ $0.focus = FocusSession(mode: s.mode, deadline: nil, remaining: 0, delivered: true) }) else { return }
        if announced != deadline {
            announced = deadline
            onReminder(s.mode == "break" ? "Istirahat selesai" : "Sesi fokus selesai")
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let deadline = session.deadline else { return }
        let t = Timer(timeInterval: max(0.05, deadline.timeIntervalSince(now())), repeats: false) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
        bag.removeAll()
    }

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "FocusSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchy-focus-\(UUID().uuidString)")
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")

        // store: missing file is empty, directory is user-only
        let store = LocalStore(url: url)
        try check(store.writable && store.error == nil && store.state == LocalState(), "missing file empty")
        let perms = (try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        try check(perms == 0o700, "directory user-only")

        var t = Date(timeIntervalSince1970: 1_800_000_000)
        var fired: [String] = []
        let c = FocusController(store: store, now: { t }, onReminder: { fired.append($0) })
        try check(c.session.mode == "focus" && c.remaining(at: t) == 1500 && !c.running, "idle default")

        // start, pause keeps remaining, resume rebuilds deadline
        c.start()
        try check(c.running && c.remaining(at: t) == 1500, "start")
        t.addTimeInterval(600); c.pause()
        try check(!c.running && c.session.remaining == 900, "pause retains remaining")
        t.addTimeInterval(3600)
        try check(c.remaining(at: t) == 900, "paused does not decay")
        c.start()
        try check(c.remaining(at: t) == 900, "resume")

        // sleep past the deadline: delivered once, further checks and wakes are silent
        t.addTimeInterval(5000); c.check(); c.check()
        try check(fired == ["Sesi fokus selesai"] && c.finished && c.session.delivered, "expiry once")

        // relaunch with an expired running session delivers once, then never again
        c.setMode("break")
        try check(c.session.mode == "break" && c.remaining(at: t) == 300, "mode select")
        c.start()
        t.addTimeInterval(400)
        c.shutdown()
        let relaunched = FocusController(store: LocalStore(url: url), now: { t }, onReminder: { fired.append($0) })
        try check(fired == ["Sesi fokus selesai", "Istirahat selesai"], "relaunch delivers once")
        relaunched.shutdown()
        let again = FocusController(store: LocalStore(url: url), now: { t }, onReminder: { fired.append($0) })
        try check(fired.count == 2 && again.finished, "no repeat after relaunch")
        again.reset()
        try check(!again.finished && again.remaining(at: t) == 300, "reset")
        again.shutdown()

        // failed save keeps prior state and shows error (directory made read-only)
        let before = store.state
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let saved = store.mutate { $0.tasks.append(TaskEntry(text: "x")) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try check(!saved && store.state == before && store.error != nil, "failed save retains state")
        try check(store.mutate { $0.tasks.append(TaskEntry(text: "x")) } && store.error == nil, "save recovers")
        let precise = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)
        try check(store.mutate { $0.tasks.append(TaskEntry(text: "Precise deadline", due: precise)) }, "save precise date")
        try check(LocalStore(url: url).state == store.state, "atomic reload preserves fractional deadlines")

        // corrupt bytes: error, writes disabled, file untouched
        let bad = dir.appendingPathComponent("bad.json")
        let junk = Data("{not json".utf8)
        try junk.write(to: bad)
        let corrupt = LocalStore(url: bad)
        try check(corrupt.error != nil && !corrupt.writable, "corrupt flagged")
        try check(!corrupt.mutate { $0.tasks.append(TaskEntry(text: "y")) }, "corrupt rejects writes")
        try check(try Data(contentsOf: bad) == junk, "corrupt bytes unchanged")
    }
}
