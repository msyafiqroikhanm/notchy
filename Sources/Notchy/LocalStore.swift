import Foundation

struct TaskEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var completed: Bool = false
    var created: Date = Date()
    var due: Date? = nil
    var reminderDelivered: Bool = false
}

struct WaterEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var ml: Int
}

struct ShelfEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var bookmark: Data
    var name: String
}

/// mode "focus"|"break". Running: deadline set. Paused/idle: deadline nil, remaining > 0.
/// Finished: deadline nil, remaining 0, delivered true.
struct FocusSession: Codable, Equatable {
    var mode: String = "focus"
    var deadline: Date? = nil
    var remaining: Double = 1500
    var delivered: Bool = false
}

struct LocalState: Codable, Equatable {
    var tasks: [TaskEntry] = []
    var water: [WaterEntry] = []
    var shelf: [ShelfEntry] = []
    var focus: FocusSession? = nil
}

/// Atomic JSON persistence. A corrupt or unreadable file disables writes so it is never overwritten.
final class LocalStore: ObservableObject {
    @Published private(set) var state = LocalState()
    @Published private(set) var error: String?
    private(set) var writable = true
    private let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchy/state.json")
    }

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        let fm = FileManager.default
        let dir = self.url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { fail("Folder data tidak dapat dibuat: \(error.localizedDescription)"); return }
        }
        guard fm.fileExists(atPath: self.url.path) else { return }
        do { state = try Self.decoder.decode(LocalState.self, from: Data(contentsOf: self.url)) }
        catch { fail("Data tersimpan rusak atau tidak terbaca; penyimpanan dimatikan agar file tidak tertimpa. \(error.localizedDescription)") }
    }

    private func fail(_ message: String) { writable = false; error = message }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    /// Persists the candidate first and publishes only on success. Main thread only.
    @discardableResult
    func mutate(_ change: (inout LocalState) -> Void) -> Bool {
        guard writable else { return false }
        var candidate = state
        change(&candidate)
        if candidate == state { return true }
        do {
            try Self.encoder.encode(candidate).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            self.error = "Gagal menyimpan: \(error.localizedDescription)"
            return false
        }
        state = candidate
        error = nil
        return true
    }
}
