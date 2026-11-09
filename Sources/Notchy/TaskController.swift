import AppKit
import Combine

/// Tugas: CRUD over LocalStore tasks plus once-only due reminders driven by one timer for the nearest due date.
final class TaskController: ObservableObject {
    let store: LocalStore
    /// Wired by the parent: show the reminder pill, play the sound, switch to the Tugas tab.
    var onReminder: (String) -> Void = { _ in }
    /// Injected clock; selftests advance it instead of sleeping.
    var now: () -> Date = Date.init

    /// Last rejected action (blank text, failed save); the store's own error is exposed separately.
    @Published var actionError: String?

    // Drafts live here, not in the view, so they survive tab switches that destroy the view.
    @Published var draftText = ""
    @Published var draftHasDue = false
    @Published var draftDue = Date().addingTimeInterval(3600)
    @Published var editingID: UUID?
    @Published var editText = ""
    @Published var editHasDue = false
    @Published var editDue = Date()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var storeChange: AnyCancellable?

    init(store: LocalStore) {
        self.store = store
        storeChange = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.check() }
        let clock = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.check() }
        observers = [wake, clock]
    }

    deinit { shutdown() }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        let wakeCenter = NSWorkspace.shared.notificationCenter
        for o in observers { wakeCenter.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    // MARK: queries

    /// Incomplete by due date (undated last) then creation; completed last by creation.
    var tasks: [TaskEntry] { Self.sorted(store.state.tasks) }

    static func sorted(_ tasks: [TaskEntry]) -> [TaskEntry] {
        tasks.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            if !a.completed, a.due != b.due {
                guard let x = a.due else { return false }
                guard let y = b.due else { return true }
                return x < y
            }
            return a.created < b.created
        }
    }

    var openCount: Int { store.state.tasks.filter { !$0.completed }.count }

    // MARK: actions

    @discardableResult
    func add(text: String, due: Date?) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { actionError = "Tulis nama tugas dulu."; return false }
        let entry = TaskEntry(text: clean, created: now(), due: due)
        return commit("Tugas tidak tersimpan") { $0.tasks.append(entry) }
    }

    /// Resets the delivered marker whenever the due date changes, so an edited deadline can remind again.
    @discardableResult
    func update(id: UUID, text: String, due: Date?) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { actionError = "Tulis nama tugas dulu."; return false }
        return commit("Perubahan tidak tersimpan") { s in
            guard let i = s.tasks.firstIndex(where: { $0.id == id }) else { return }
            if s.tasks[i].due != due { s.tasks[i].reminderDelivered = false }
            s.tasks[i].text = clean
            s.tasks[i].due = due
        }
    }

    @discardableResult
    func toggle(_ id: UUID) -> Bool {
        commit("Perubahan tidak tersimpan") { s in
            if let i = s.tasks.firstIndex(where: { $0.id == id }) { s.tasks[i].completed.toggle() }
        }
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        if editingID == id { editingID = nil }
        return commit("Tugas tidak terhapus") { $0.tasks.removeAll { $0.id == id } }
    }

    @discardableResult
    func submitDraft() -> Bool {
        guard add(text: draftText, due: draftHasDue ? draftDue : nil) else { return false }
        draftText = ""
        draftHasDue = false
        draftDue = now().addingTimeInterval(3600)
        return true
    }

    func beginEdit(_ t: TaskEntry) {
        editingID = t.id
        editText = t.text
        editHasDue = t.due != nil
        editDue = t.due ?? now().addingTimeInterval(3600)
    }

    @discardableResult
    func commitEdit() -> Bool {
        guard let id = editingID, update(id: id, text: editText, due: editHasDue ? editDue : nil) else { return false }
        editingID = nil
        return true
    }

    func cancelEdit() { editingID = nil; actionError = nil }

    private func commit(_ failure: String, _ change: (inout LocalState) -> Void) -> Bool {
        let ok = store.mutate(change)
        actionError = ok ? nil : "\(failure): \(store.error ?? "penyimpanan tidak bisa ditulis")"
        if ok { check() }
        return ok
    }

    // MARK: reminders

    /// Delivers every overdue, undelivered, open task once (one pill for the batch), then arms the next timer.
    func check() {
        let t = now()
        let dueIDs = store.state.tasks.filter { !$0.completed && !$0.reminderDelivered && ($0.due ?? .distantFuture) <= t }
        if !dueIDs.isEmpty {
            let ids = Set(dueIDs.map(\.id))
            // Only announce after the marker is persisted; otherwise a failing store would repeat it forever.
            if store.mutate({ s in for i in s.tasks.indices where ids.contains(s.tasks[i].id) { s.tasks[i].reminderDelivered = true } }) {
                let first = Self.sorted(dueIDs)[0].text
                onReminder(dueIDs.count == 1 ? "Tugas: \(first)" : "Tugas: \(first) +\(dueIDs.count - 1) lagi")
            }
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        let t = now()
        let next = store.state.tasks
            .filter { !$0.completed && !$0.reminderDelivered }
            .compactMap(\.due).filter { $0 > t }.min()
        guard let next else { return }
        let tm = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.check() }
        tm.tolerance = 0.5
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    // MARK: selftest

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "TaskSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchy-task-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(url: dir.appendingPathComponent("state.json"))
        let c = TaskController(store: store)
        defer { c.shutdown() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        c.now = { clock }
        var fired: [String] = []
        c.onReminder = { fired.append($0) }

        try check(!c.add(text: "  \n ", due: nil), "blank rejected")
        try check(c.add(text: "  b  ", due: nil), "add b")
        clock += 1
        try check(c.add(text: "a", due: clock.addingTimeInterval(600)), "add a")
        clock += 1
        try check(c.add(text: "c", due: clock.addingTimeInterval(60)), "add c")
        try check(c.tasks.map(\.text) == ["c", "a", "b"], "sort due then undated \(c.tasks.map(\.text))")
        c.toggle(c.tasks[0].id)
        try check(c.tasks.map(\.text) == ["a", "b", "c"], "completed last")
        c.toggle(c.tasks[2].id)

        clock += 61
        c.check()
        try check(fired == ["Tugas: c"], "c fires once \(fired)")
        c.check(); clock += 30; c.check()
        try check(fired.count == 1, "no repeat")

        let a = c.tasks.first { $0.text == "a" }!
        clock += 3600
        c.check()
        try check(fired.count == 2 && fired[1] == "Tugas: a", "a fires on late check (wake)")
        c.update(id: a.id, text: "a2", due: a.due)
        try check(c.tasks.first { $0.id == a.id }?.reminderDelivered == true, "same due keeps marker")
        c.update(id: a.id, text: "a2", due: clock.addingTimeInterval(10))
        try check(c.tasks.first { $0.id == a.id }?.reminderDelivered == false, "due edit rearms")
        clock += 11
        c.check()
        try check(fired.count == 3, "rearmed fires again")
        c.toggle(a.id)
        c.delete(a.id)
        try check(c.tasks.count == 2, "delete")

        c.draftText = "  "
        try check(!c.submitDraft() && c.draftText == "  ", "failed draft keeps unsaved text")
        c.draftText = "saved draft"
        try check(c.submitDraft() && c.draftText.isEmpty && c.tasks.contains { $0.text == "saved draft" }, "successful draft persists before clearing")
        c.beginEdit(c.tasks[0])
        let editing = c.editingID
        c.editText = ""
        try check(!c.commitEdit() && c.editingID == editing, "rejected edit remains open")
        c.editText = "saved edit"
        try check(c.commitEdit() && c.editingID == nil && c.tasks.contains { $0.text == "saved edit" }, "successful edit persists before closing")
    }
}
