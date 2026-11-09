import Foundation

struct LyricLine: Equatable, Identifiable {
    var id: Int = 0
    let time: TimeInterval
    let text: String
}

enum LyricsState: Equatable {
    case disabled
    case idle                      // no track
    case loading
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
    case failed(String)
}

/// Caller (MusicView/Media) drives it with `setTrack`. No network unless `enabled` is true.
final class LyricsController: ObservableObject {
    @Published private(set) var state: LyricsState = .disabled

    private struct Track: Equatable {
        let title: String, artist: String, album: String?, duration: TimeInterval?
    }
    private var track: Track?
    private var enabled = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var cache: [String: LyricsState] = [:]   // session only; failures never cached
    private let fetch: (URL) async throws -> (Data, Int)

    private var preferences: Preferences?

    init(preferences: Preferences? = nil, fetch: @escaping (URL) async throws -> (Data, Int) = LyricsController.liveFetch) {
        self.preferences = preferences
        self.fetch = fetch
    }

    /// Media-facing entry: reads the opt-in from Preferences each call.
    func update(track s: MediaSnapshot) {
        setTrack(enabled: preferences?.lyricsEnabled ?? false, title: s.hasTrack ? s.title : nil, artist: s.artist, album: s.album,
                 duration: s.durationMicros.map { Double($0) / 1_000_000 })
    }

    static func currentIndex(_ lines: [LyricLine], at position: Double) -> Int? { activeIndex(in: lines, at: position) }

    /// Call on every track/metadata/preference change; identical input is a no-op. Main thread.
    func setTrack(enabled: Bool, title: String?, artist: String?, album: String?, duration: TimeInterval?) {
        let newTrack: Track? = {
            guard let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
                  let a = artist?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return nil }
            let al = album?.trimmingCharacters(in: .whitespaces)
            let d = duration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            return Track(title: t, artist: a, album: al?.isEmpty == false ? al : nil, duration: d)
        }()
        if enabled == self.enabled, newTrack == track, !(enabled && state == .disabled) { return }
        self.enabled = enabled
        track = newTrack
        invalidate()
        guard enabled else { state = .disabled; return }
        guard let t = newTrack else { state = .idle; return }
        load(t)
    }

    func retry() {
        guard enabled, let t = track else { return }
        invalidate()
        load(t)
    }

    private func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func load(_ t: Track) {
        let key = Self.cacheKey(t.title, t.artist, t.album, t.duration)
        if let hit = cache[key] { state = hit; return }
        state = .loading
        let gen = generation
        let url = Self.requestURL(title: t.title, artist: t.artist, album: t.album, duration: t.duration)
        task = Task { @MainActor [weak self, fetch] in
            let result: LyricsState
            do {
                let (data, code) = try await fetch(url)
                result = try Self.interpret(data: data, status: code)
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch {
                result = .failed(error.localizedDescription)
            }
            self?.apply(result, key: key, generation: gen)
        }
    }

    /// Discards results from obsolete requests.
    func apply(_ result: LyricsState, key: String, generation gen: Int) {
        guard gen == generation, enabled else { return }
        if case .failed = result {} else { cache[key] = result }
        state = result
    }

    // MARK: pure helpers

    static func cacheKey(_ title: String, _ artist: String, _ album: String?, _ duration: TimeInterval?) -> String {
        [title, artist, album ?? "", duration.map { String(Int($0.rounded())) } ?? ""].joined(separator: "\u{1F}")
    }

    static func requestURL(title: String, artist: String, album: String?, duration: TimeInterval?) -> URL {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: title)]
        if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        c.queryItems = items
        return c.url!
    }

    static func liveFetch(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Notchy/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func interpret(data: Data, status: Int) throws -> LyricsState {
        if status == 404 { return .notFound }
        guard (200..<300).contains(status) else { throw NSError(domain: "Lyrics", code: status, userInfo: [NSLocalizedDescriptionKey: "Server lirik membalas HTTP \(status)"]) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Lyrics", code: 0, userInfo: [NSLocalizedDescriptionKey: "Respons lirik tidak valid"])
        }
        if obj["instrumental"] as? Bool == true { return .instrumental }
        if let s = obj["syncedLyrics"] as? String {
            let lines = parseLRC(s)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let p = obj["plainLyrics"] as? String, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .plain(p) }
        return .notFound
    }

    /// `[mm:ss.xx]` tags (repeatable per line), `[offset:ms]` (positive = lyrics earlier, so subtract). Other metadata ignored.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var out: [(Int, LyricLine)] = []
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        for (n, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = String(raw)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let r = line.range(of: #"^\s*\[offset:\s*(-?\d+)\s*\]"#, options: .regularExpression) {
                let digits = line[r].filter { $0.isNumber || $0 == "-" }
                offset = (Double(digits) ?? 0) / 1000
                continue
            }
            let ms = tag.matches(in: line, range: full)
            guard let last = ms.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let min = Double(ns.substring(with: m.range(at: 1)))!, sec = Double(ns.substring(with: m.range(at: 2)))!
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append((n, LyricLine(time: min * 60 + sec + frac, text: body)))
            }
        }
        // offset line may follow tags in file, so apply after collecting; stable sort by time then source order
        return out.sorted { $0.1.time != $1.1.time ? $0.1.time < $1.1.time : $0.0 < $1.0 }
            .enumerated().map { LyricLine(id: $0.offset, time: max(0, $0.element.1.time - offset), text: $0.element.1.text) }
    }

    /// Index of the latest line with time <= position, nil before the first.
    static func activeIndex(in lines: [LyricLine], at position: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi { let mid = (lo + hi) / 2; if lines[mid].time <= position { lo = mid + 1 } else { hi = mid } }
        return lo == 0 ? nil : lo - 1
    }

    // MARK: selftest

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "LyricsSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        let lrc = "[ar:X]\n[00:10.50][00:30.5] Chorus\n[00:05.00]Intro\n[01:00.123] End\n[00:20]\n"
        var l = parseLRC(lrc)
        try check(l.map(\.text) == ["Intro", "Chorus", "", "Chorus", "End"], "order/repeat \(l.map(\.text))")
        try check(abs(l[1].time - 10.5) < 1e-9 && abs(l[4].time - 60.123) < 1e-9, "times")
        l = parseLRC("[offset:500]\n[00:10.00]a\n[00:00.20]b")
        try check(abs(l[0].time) < 1e-9 && abs(l[1].time - 9.5) < 1e-9, "positive offset subtracts, clamps")
        l = parseLRC("[00:10.00]a\n[offset:-500]")
        try check(abs(l[0].time - 10.5) < 1e-9, "negative offset adds")
        l = parseLRC("[00:05.00]a\n[00:10.00]b")
        try check(activeIndex(in: l, at: 4.999) == nil, "before first")
        try check(activeIndex(in: l, at: 5) == 0 && activeIndex(in: l, at: 9.999) == 0, "boundary a")
        try check(activeIndex(in: l, at: 10) == 1 && activeIndex(in: l, at: 999) == 1, "boundary b")

        let u = requestURL(title: "Yellow & Co", artist: "Coldplay", album: "Parachutes", duration: 269.4)
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try check(items.first(where: { $0.name == "track_name" })?.value == "Yellow & Co"
                  && items.count == 4, "Track ampersand must not split query parameters")
        try check(interpret(data: Data(), status: 404) == .notFound, "404")
        try check(interpret(data: Data(#"{"instrumental":true}"#.utf8), status: 200) == .instrumental, "instrumental")
        try check(interpret(data: Data(#"{"plainLyrics":"hi"}"#.utf8), status: 200) == .plain("hi"), "plain")
        do { _ = try interpret(data: Data(), status: 500); throw NSError(domain: "LyricsSelfTest", code: 2) } catch let e as NSError { try check(e.domain == "Lyrics", "500 throws") }

        // gating + stale discard, no network
        let c = LyricsController(fetch: { _ in throw NSError(domain: "LyricsSelfTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "network must not be used"]) })
        c.setTrack(enabled: false, title: "A", artist: "B", album: nil, duration: 10)
        try check(c.state == .disabled && c.task == nil, "disabled makes no request")
        c.cache[cacheKey("A", "B", nil, 10)] = .plain("cached")
        c.setTrack(enabled: true, title: "A", artist: "B", album: nil, duration: 10)
        try check(c.state == .plain("cached"), "cache hit")
        c.cache[cacheKey("C", "D", nil, nil)] = .plain("c")
        c.setTrack(enabled: true, title: "C", artist: "D", album: nil, duration: nil)
        let staleGen = c.generation - 1
        c.apply(.plain("stale"), key: "x", generation: staleGen)
        try check(c.state == .plain("c"), "stale discarded")
        c.setTrack(enabled: false, title: "C", artist: "D", album: nil, duration: nil)
        c.apply(.plain("late"), key: "x", generation: c.generation)
        try check(c.state == .disabled, "disabled discards late")
    }
}
