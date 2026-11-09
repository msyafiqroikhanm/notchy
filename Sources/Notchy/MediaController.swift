import AppKit
import Combine

/// Immutable view of the system now-playing state. Built only from adapter payloads; no placeholder metadata.
struct MediaSnapshot: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var durationMicros: Int64?
    var elapsedMicros: Int64?
    var timestampEpochMicros: Int64?
    var rate: Double = 1
    var playing = false

    var hasTrack: Bool { title != nil }
    /// Seconds; nil when the player reports no usable duration (seeking is then disabled).
    var duration: TimeInterval? { durationMicros.flatMap { $0 > 0 ? Double($0) / 1e6 : nil } }
    var trackID: String { "\(title ?? "")\u{1}\(artist ?? "")\u{1}\(album ?? "")\u{1}\(durationMicros ?? 0)" }

    init() {}

    init(state: [String: Any]) {
        func int(_ key: String) -> Int64? { (state[key] as? NSNumber)?.int64Value }
        let text = { (key: String) -> String? in
            guard let s = state[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        title = text("title")
        guard title != nil else { return }  // adapter contract: media without a title is not media
        artist = text("artist")
        album = text("album")
        durationMicros = int("durationMicros")
        elapsedMicros = int("elapsedTimeMicros")
        timestampEpochMicros = int("timestampEpochMicros")
        if let r = (state["playbackRate"] as? NSNumber)?.doubleValue, r > 0 { rate = r }
        playing = (state["playing"] as? NSNumber)?.boolValue ?? false
    }

    /// Interpolated elapsed seconds: frozen while paused, advancing by rate while playing, clamped to [0, duration].
    func elapsedSeconds(at now: Date = Date()) -> TimeInterval {
        guard let elapsedMicros else { return 0 }
        var micros = Double(elapsedMicros)
        if playing, let ts = timestampEpochMicros {
            micros += max(0, now.timeIntervalSince1970 * 1e6 - Double(ts)) * rate
        }
        var seconds = max(0, micros / 1e6)
        if let duration { seconds = min(seconds, duration) }
        return seconds
    }
}

/// Splits adapter stdout into NDJSON records across arbitrary read boundaries and maintains the merged state.
/// Replace on `diff:false`, merge on `diff:true`, `null` deletes. Malformed lines are logged and skipped.
struct MediaStreamDecoder {
    static let maxLineBytes = 8 * 1024 * 1024
    struct Overflow: Error {}

    private var pending = Data()
    private(set) var state: [String: Any] = [:]
    private(set) var malformedLines = 0

    /// Returns true when at least one record changed `state`. Throws `Overflow` once a line exceeds the bound.
    mutating func feed(_ chunk: Data) throws -> Bool {
        pending.append(chunk)
        var changed = false
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            if newline - start > Self.maxLineBytes { throw Overflow() }
            if apply(Data(pending[start..<newline])) { changed = true }
            start = newline + 1
        }
        pending.removeSubrange(pending.startIndex..<start)
        if pending.count > Self.maxLineBytes { throw Overflow() }
        return changed
    }

    private mutating func apply(_ line: Data) -> Bool {
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { return false }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else {
            malformedLines += 1
            NSLog("Notchy media: malformed adapter line (%d bytes) ignored", line.count)
            return false
        }
        guard type == "data" else { return false }  // unknown record kinds are ignored
        guard let payload = object["payload"] as? [String: Any], let diff = object["diff"] as? Bool else {
            malformedLines += 1
            NSLog("Notchy media: data record without payload/diff ignored")
            return false
        }
        if !diff { state = [:] }
        for (key, value) in payload {
            if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
        }
        return true
    }
}

/// Owns exactly one long-lived adapter `stream` child plus short-lived command children.
/// Every child is cancelled and reaped on `shutdown()`; stale events are rejected by generation.
final class MediaController: ObservableObject {
    @Published private(set) var snapshot = MediaSnapshot()
    @Published private(set) var artwork: NSImage?
    /// Non-nil while the stream is down ("Musik tidak tersedia"); `retry()` replaces the child.
    @Published private(set) var error: String?
    @Published private(set) var errorDetail: String?
    /// Last failed command (toggle/next/seek...), shown next to the controls.
    @Published private(set) var commandError: String?

    fileprivate enum StreamEvent {
        case update(MediaSnapshot, NSImage?)
        case failed(String)
    }

    private let adapter: (script: String, framework: String)?
    private var generation = 0
    private var session: StreamSession?
    private var commands: [Process] = []
    private var cancellables = Set<AnyCancellable>()

    init(resources: URL? = Bundle.main.resourceURL, autostart: Bool = true) {
        if let resources {
            adapter = (resources.appendingPathComponent("mediaremote-adapter.pl").path,
                       resources.appendingPathComponent("MediaRemoteAdapter.framework").path)
        } else {
            adapter = nil
        }
        if autostart { start() }
    }

    deinit { shutdown() }

    /// Mirrors playing state into the shell so the closed notch reflects media.
    func bind(_ shell: ShellState) {
        $snapshot.map(\.playing).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak shell] in shell?.playing = $0 }.store(in: &cancellables)
    }

    // MARK: stream lifecycle

    func start() {
        guard session == nil else { return }
        guard let adapter, FileManager.default.fileExists(atPath: adapter.script),
              FileManager.default.fileExists(atPath: adapter.framework) else {
            fail("Adapter MediaRemote tidak ditemukan di bundel aplikasi")
            return
        }
        generation += 1
        let gen = generation
        let new = StreamSession(generation: gen, arguments: [adapter.script, adapter.framework, "stream", "--micros"]) { [weak self] gen, event in
            DispatchQueue.main.async { self?.handle(gen, event) }
        }
        do {
            try new.start()
            session = new
        } catch {
            fail("Adapter gagal dijalankan: \(error.localizedDescription)")
        }
    }

    func retry() {
        retire()
        generation += 1
        error = nil
        errorDetail = nil
        commandError = nil
        snapshot = MediaSnapshot()
        artwork = nil
        start()
    }

    /// Synchronous: terminates and reaps the stream and all command children (Quit path).
    func shutdown() {
        generation += 1
        let children = commands + (session.map { [$0.process] } ?? [])
        session?.cancel()
        session = nil
        commands.removeAll()
        for process in children { Self.reap(process) }
    }

    private func retire() {
        generation += 1
        session?.cancel()  // reaped by the session's own waiter thread
        session = nil
    }

    private func handle(_ gen: Int, _ event: StreamEvent) {
        guard gen == generation else { return }
        switch event {
        case .update(let new, let image):
            if error != nil { error = nil; errorDetail = nil }
            if snapshot != new { snapshot = new }
            if artwork !== image { artwork = image }
        case .failed(let detail):
            session = nil
            fail(detail)
        }
    }

    private func fail(_ detail: String) {
        snapshot = MediaSnapshot()
        artwork = nil
        error = "Musik tidak tersedia"
        errorDetail = detail
    }

    private static func reap(_ process: Process) {
        guard process.processIdentifier > 0 else { return }
        if process.isRunning { process.terminate() }
        for _ in 0..<50 where process.isRunning { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    // MARK: commands (argv arrays only; no shell)

    static func sendArguments(_ id: Int) -> [String] { ["send", String(id)] }

    /// Adapter requires a positive integer of microseconds, so zero seeks to 1 µs.
    static func seekMicros(_ seconds: TimeInterval, duration: TimeInterval?) -> Int64 {
        var s = max(0, seconds)
        if let duration { s = min(s, duration) }
        return max(1, Int64((s * 1e6).rounded()))
    }

    func togglePlayPause() { run(Self.sendArguments(2)) }
    func next() { run(Self.sendArguments(4)) }
    func previous() { run(Self.sendArguments(5)) }
    /// Explicit pause (never a toggle): already-paused music stays paused.
    func pause() { run(Self.sendArguments(1)) }

    func seek(toSeconds seconds: TimeInterval) {
        guard snapshot.hasTrack else { return }
        let micros = Self.seekMicros(seconds, duration: snapshot.duration)
        run(["seek", String(micros)])
        snapshot.elapsedMicros = micros
        snapshot.timestampEpochMicros = Int64(Date().timeIntervalSince1970 * 1e6)
    }

    private func run(_ arguments: [String]) {
        guard let adapter else { commandError = "Adapter MediaRemote tidak ditemukan"; return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapter.script, adapter.framework] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do { try process.run() } catch {
            commandError = "Perintah gagal: \(error.localizedDescription)"
            return
        }
        commands.append(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        DispatchQueue.global().async { [weak self] in
            let output = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let status = process.terminationStatus
            let reason = process.terminationReason
            DispatchQueue.main.async {
                guard let self else { return }
                self.commands.removeAll { $0 === process }
                guard status != 0 || reason != .exit else { self.commandError = nil; return }
                let tail = String(decoding: output.suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                self.commandError = "Perintah gagal (\(status))" + (tail.isEmpty ? "" : ": \(tail)")
            }
        }
    }

    // MARK: selftest

    static func selftest() throws {
        func check(_ ok: Bool, _ what: String) throws {
            if !ok { throw NSError(domain: "MediaSelftest", code: 1, userInfo: [NSLocalizedDescriptionKey: what]) }
        }
        let full = #"{"type":"data","diff":false,"payload":{"title":"Judul","artist":"Artis","playing":true,"durationMicros":200000000,"elapsedTimeMicros":10000000,"timestampEpochMicros":1000000000,"playbackRate":1,"artworkMimeType":"image/png","unknown":{"x":1}}}"#
        let diff = #"{"type":"data","diff":true,"payload":{"artist":null,"elapsedTimeMicros":20000000}}"#
        let bytes = Array((full + "\n" + diff + "\n").utf8)

        // Fragmentation at every byte boundary yields the same merged state.
        var d = MediaStreamDecoder()
        for byte in bytes { _ = try d.feed(Data([byte])) }
        try check(d.state["title"] as? String == "Judul", "fragmented title")
        try check(d.state["artist"] == nil, "diff null deletes key")
        try check((d.state["elapsedTimeMicros"] as? NSNumber)?.int64Value == 20_000_000, "diff merge")
        try check(d.state["unknown"] != nil && d.malformedLines == 0, "unknown fields tolerated")
        let snap = MediaSnapshot(state: d.state)
        try check(snap.title == "Judul" && snap.artist == nil && snap.playing && snap.duration == 200, "snapshot fields")

        // Multiple records in one chunk plus a trailing partial line.
        var d2 = MediaStreamDecoder()
        _ = try d2.feed(Data((full + "\n" + diff + "\n" + #"{"type":"da"#).utf8))
        try check(d2.state["artist"] == nil && d2.malformedLines == 0, "partial tail retained")
        _ = try d2.feed(Data(#"ta","diff":true,"payload":{"title":"Baru"}}"#.utf8 + [0x0A]))
        try check(d2.state["title"] as? String == "Baru", "partial tail completed")

        // Malformed lines are logged and keep the last valid state.
        _ = try d2.feed(Data("not json\n{\"type\":\"data\",\"diff\":true}\n".utf8))
        try check(d2.malformedLines == 2 && d2.state["title"] as? String == "Baru", "malformed keeps state")

        // Full non-diff record replaces; empty payload clears media.
        _ = try d2.feed(Data(#"{"type":"data","diff":false,"payload":{"title":"Lain"}}"#.utf8 + [0x0A]))
        try check(d2.state.count == 1 && d2.state["playing"] == nil, "full replaces")
        _ = try d2.feed(Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8 + [0x0A]))
        try check(d2.state.isEmpty && !MediaSnapshot(state: d2.state).hasTrack, "empty payload clears")

        // Oversize incomplete line fails visibly.
        var d3 = MediaStreamDecoder()
        var overflowed = false
        do { _ = try d3.feed(Data(count: MediaStreamDecoder.maxLineBytes + 1)) } catch is MediaStreamDecoder.Overflow { overflowed = true }
        try check(overflowed, "8 MiB bound")

        // Interpolation: advances at rate, freezes when paused, clamps at 0 and duration (exact boundary).
        var s = MediaSnapshot()
        s.title = "T"; s.durationMicros = 200_000_000; s.elapsedMicros = 10_000_000
        s.timestampEpochMicros = 1_000_000_000; s.playing = true
        let t0 = Date(timeIntervalSince1970: 1000)
        try check(abs(s.elapsedSeconds(at: t0.addingTimeInterval(5)) - 15) < 1e-6, "interpolates")
        s.rate = 2
        try check(abs(s.elapsedSeconds(at: t0.addingTimeInterval(5)) - 20) < 1e-6, "rate")
        try check(s.elapsedSeconds(at: t0.addingTimeInterval(190)) == 200, "reaches duration exactly")
        try check(s.elapsedSeconds(at: t0.addingTimeInterval(10_000)) == 200, "clamps to duration")
        try check(s.elapsedSeconds(at: t0.addingTimeInterval(-50)) == 10, "clock before timestamp")
        s.playing = false
        try check(s.elapsedSeconds(at: t0.addingTimeInterval(500)) == 10, "paused freezes")

        // Command argv.
        try check(seekMicros(0, duration: 200) == 1 && seekMicros(-3, duration: nil) == 1, "seek zero is minimal positive")
        try check(seekMicros(999, duration: 200) == 200_000_000, "seek clamps")
        try check(sendArguments(1) == ["send", "1"], "explicit pause id")
    }
}

/// One adapter `stream` child. Handlers run off the main thread; results go out through `emit` tagged with generation.
private final class StreamSession {
    let process = Process()
    private let generation: Int
    private let arguments: [String]
    private let emit: (Int, MediaController.StreamEvent) -> Void
    private let out = Pipe()
    private let err = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var reported = false
    private var stderrTail = Data()
    private var decoder = MediaStreamDecoder()
    private var artworkText: String?
    private var artworkImage: NSImage?

    init(generation: Int, arguments: [String], emit: @escaping (Int, MediaController.StreamEvent) -> Void) {
        self.generation = generation
        self.arguments = arguments
        self.emit = emit
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; finish(); return }
            readStdout(data)
        }
        err.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            lock.lock()
            stderrTail = Data((stderrTail + data).suffix(2048))
            lock.unlock()
            NSLog("Notchy media adapter: %@", String(decoding: data.prefix(500), as: UTF8.self))
        }
        try process.run()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func readStdout(_ data: Data) {
        guard !isCancelled, !reported else { return }
        do {
            guard try decoder.feed(data) else { return }
        } catch {
            report("Aliran adapter melebihi 8 MiB tanpa baris lengkap")
            process.terminate()
            return
        }
        let state = decoder.state
        let text = state["artworkData"] as? String
        if text != artworkText {
            artworkText = text
            artworkImage = text.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }.flatMap(NSImage.init(data:))
        }
        emit(generation, .update(MediaSnapshot(state: state), artworkImage))
    }

    private func report(_ detail: String) {
        lock.lock()
        let skip = cancelled || reported
        reported = true
        lock.unlock()
        if !skip { emit(generation, .failed(detail)) }
    }

    /// stdout closed: reap the child, then report unexpected exit unless we cancelled it.
    private func finish() {
        DispatchQueue.global().async { [self] in
            process.waitUntilExit()
            out.fileHandleForReading.closeFile()
            err.fileHandleForReading.closeFile()
            lock.lock()
            let tail = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            let status = process.terminationStatus
            report(tail.isEmpty ? "Proses adapter berhenti (kode \(status))" : "Adapter berhenti (kode \(status)): \(tail.suffix(200))")
        }
    }
}
