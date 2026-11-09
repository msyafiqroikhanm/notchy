import AppKit
import Combine

/// One shelf row as displayed. `url == nil` means the bookmark no longer resolves (target missing).
struct ShelfItem: Identifiable {
    let id: UUID
    let name: String
    let url: URL?
    let size: String
    let icon: NSImage
    var available: Bool { url != nil }
}

/// Holds file references (bookmarks) only. Removing or clearing never touches the real files.
final class ShelfController: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var error: String?
    /// Brief confirmation text for the shell ("Ditambahkan ke Shelf: x").
    var onAdded: (String) -> Void = { _ in }

    private let store: LocalStore
    private var cancellable: AnyCancellable?

    init(store: LocalStore) {
        self.store = store
        refresh()
        // Store errors (corrupt state) must stay visible; mirror them without overwriting our own messages.
        cancellable = store.$error.sink { [weak self] message in
            guard let self, let message else { return }
            self.error = message
        }
    }

    func shutdown() { cancellable = nil }

    // MARK: add / remove

    func add(urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        var problems: [String] = []
        if files.count < urls.count { problems.append("Hanya file atau folder yang bisa ditambahkan ke Shelf.") }
        guard store.writable else {
            error = store.error ?? "Penyimpanan tidak dapat ditulis."
            return
        }
        var known = Set(store.state.shelf.compactMap { Self.resolve($0.bookmark)?.url }.map(Self.key))
        var entries: [ShelfEntry] = []
        for url in files {
            let key = Self.key(url)
            guard known.insert(key).inserted else { continue }
            do {
                let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                entries.append(ShelfEntry(bookmark: data, name: url.lastPathComponent))
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !entries.isEmpty {
            if store.mutate({ $0.shelf.append(contentsOf: entries) }) {
                refresh()
                onAdded(entries.count == 1 ? entries[0].name : "\(entries.count) item")
            } else {
                problems.append(store.error ?? "Gagal menyimpan Shelf.")
            }
        }
        error = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    func rejectNonFileDrop() { error = "Hanya file atau folder yang bisa ditambahkan ke Shelf." }

    func remove(_ id: UUID) {
        if store.mutate({ $0.shelf.removeAll { $0.id == id } }) { error = nil; refresh() }
        else { error = store.error ?? "Gagal menyimpan Shelf." }
    }

    func clear() {
        if store.mutate({ $0.shelf.removeAll() }) { error = nil; refresh() }
        else { error = store.error ?? "Gagal menyimpan Shelf." }
    }

    func open(_ item: ShelfItem) {
        guard let url = item.url else { error = "\(item.name) tidak ditemukan. Hapus referensinya."; return }
        if NSWorkspace.shared.open(url) { error = nil }
        else { error = "Tidak dapat membuka \(item.name)." }
    }

    // MARK: resolution

    /// Re-resolves every bookmark; refreshes stale ones in a single atomic write.
    func refresh() {
        var refreshed: [UUID: Data] = [:]
        var list: [ShelfItem] = []
        for entry in store.state.shelf {
            guard let r = Self.resolve(entry.bookmark) else {
                list.append(ShelfItem(id: entry.id, name: entry.name, url: nil, size: "Tidak ditemukan",
                                      icon: NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil) ?? NSImage()))
                continue
            }
            if r.stale, let fresh = try? r.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                refreshed[entry.id] = fresh
            }
            list.append(ShelfItem(id: entry.id, name: r.url.lastPathComponent, url: r.url,
                                  size: Self.sizeText(r.url), icon: NSWorkspace.shared.icon(forFile: r.url.path)))
        }
        items = list
        if !refreshed.isEmpty, store.writable {
            // Best effort: a failed refresh write leaves the old, still-resolving bookmark in place.
            _ = store.mutate { state in
                for i in state.shelf.indices { if let d = refreshed[state.shelf[i].id] { state.shelf[i].bookmark = d } }
            }
        }
    }

    static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, stale)
    }

    static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private static func sizeText(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if v?.isDirectory == true { return "Folder" }
        guard let n = v?.fileSize else { return "Ukuran tidak tersedia" }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    // MARK: selftest

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "ShelfSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchy-shelf-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: file)
        let link = dir.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        let gone = dir.appendingPathComponent("gone.txt")
        try Data("x".utf8).write(to: gone)

        let store = LocalStore(url: dir.appendingPathComponent("state.json"))
        let shelf = ShelfController(store: store)

        shelf.add(urls: [file, link, file])
        try check(store.state.shelf.count == 1 && shelf.items.count == 1, "dedupe resolved URL")
        try check(shelf.items[0].available, "bookmark resolves existing file")

        shelf.add(urls: [URL(string: "https://example.com/x")!])
        try check(shelf.error != nil && store.state.shelf.count == 1, "non-file rejected visibly")

        shelf.add(urls: [gone])
        try check(shelf.items.count == 2, "second file added")
        try fm.removeItem(at: gone)
        shelf.refresh()
        try check(shelf.items.count == 2 && !shelf.items[1].available, "missing target retained as unavailable")

        shelf.remove(shelf.items[1].id)
        try check(shelf.items.count == 1, "remove reference")
        shelf.clear()
        try check(shelf.items.isEmpty && store.state.shelf.isEmpty, "clear references")
        try check(fm.fileExists(atPath: file.path) && fm.fileExists(atPath: link.path), "originals untouched")
        shelf.shutdown()
    }
}
