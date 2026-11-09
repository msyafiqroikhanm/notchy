import AppKit
import SwiftUI

/// Musik page: artwork and title, one timeline row, transport row. Lyrics widen the shell and sit beside a 280 pt player.
struct MusicView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var shell: ShellState
    @ObservedObject var preferences: Preferences
    @State private var dragValue: Double?

    private var snap: MediaSnapshot { media.snapshot }
    private var showLyrics: Bool { shell.lyricsExpanded && preferences.lyricsEnabled }

    var body: some View {
        Group {
            if let error = media.error {
                unavailable(error)
            } else if !snap.hasTrack {
                message(icon: "music.note", title: "Tidak ada musik diputar", detail: "Putar lagu di Music, Spotify, atau browser.")
            } else if shell.expanded && shell.selectedTab == ShellTab.musik.rawValue && snap.playing {
                // Tick only while visible and advancing; 0.25 s when lyrics need line-accurate highlighting.
                TimelineView(.periodic(from: .now, by: showLyrics ? 0.25 : 0.5)) { player(now: $0.date) }
            } else {
                player(now: Date())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { lyrics.update(track: snap) }
        .onChange(of: snap.trackID) { _ in lyrics.update(track: snap) }
        .onChange(of: preferences.lyricsEnabled) { enabled in
            if !enabled { shell.lyricsExpanded = false }
            lyrics.update(track: snap)
        }
        .onDisappear { dragValue = nil; shell.interacting = false }
    }

    // MARK: player

    private func player(now: Date) -> some View {
        let elapsed = snap.elapsedSeconds(at: now)
        let controls = VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    artworkView(size: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.title ?? "")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2).truncationMode(.tail)
                            .help(snap.title ?? "")
                        Text(snap.artist ?? "Artis tidak diketahui")
                            .font(.system(size: 12)).foregroundColor(Palette.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .help(snap.artist ?? "")
                        if let failure = media.commandError {
                            Text(failure).font(.system(size: 11)).foregroundColor(.white).lineLimit(1)
                                .help(failure)
                                .accessibilityLabel("Kesalahan perintah: \(failure)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 60)
                timeline(elapsed: elapsed)
                transport
            }
            .fixedSize(horizontal: false, vertical: true)
        let playerControls = ViewThatFits(in: .vertical) {
            controls
            ScrollView { controls }
        }
        return Group {
            if showLyrics {
                let pane = LyricsView(lyrics: lyrics, position: dragValue ?? elapsed, canSeek: snap.duration != nil) {
                    media.seek(toSeconds: $0)
                }
                if shell.narrow {
                    VStack(spacing: 12) {
                        playerControls
                        pane.frame(minHeight: 0, maxHeight: 180)
                    }
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        playerControls.frame(width: 280)
                        pane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                playerControls
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func artworkView(size: CGFloat) -> some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Palette.control
                    Image(systemName: "music.note").font(.system(size: size * 0.36)).foregroundColor(Palette.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(media.artwork == nil ? "Tanpa sampul" : "Sampul album")
    }

    /// Lyrics toggle at the left, previous / play-pause / next centered.
    private var transport: some View {
        ZStack {
            HStack {
                if preferences.lyricsEnabled {
                    Button { shell.lyricsExpanded.toggle() } label: {
                        Image(systemName: "quote.bubble").font(.system(size: 13))
                            .foregroundColor(showLyrics ? .black : .white)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(showLyrics ? Color.white : Palette.control))
                    }
                    .buttonStyle(ShellControlStyle(kind: .plain))
                    .accessibilityLabel(showLyrics ? "Sembunyikan lirik" : "Tampilkan lirik")
                    .help(showLyrics ? "Sembunyikan lirik" : "Tampilkan lirik")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 18) {
                Button { media.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 14)) }
                    .buttonStyle(ShellControlStyle(kind: .icon(28)))
                    .accessibilityLabel("Lagu sebelumnya").help("Lagu sebelumnya")
                Button { media.togglePlayPause() } label: {
                    Image(systemName: snap.playing ? "pause.fill" : "play.fill").font(.system(size: 18))
                }
                .buttonStyle(ShellControlStyle(kind: .icon(28)))
                .accessibilityLabel(snap.playing ? "Jeda" : "Putar").help(snap.playing ? "Jeda" : "Putar")
                Button { media.next() } label: { Image(systemName: "forward.fill").font(.system(size: 14)) }
                    .buttonStyle(ShellControlStyle(kind: .icon(28)))
                    .accessibilityLabel("Lagu berikutnya").help("Lagu berikutnya")
            }
        }
        .frame(height: 28)
        .foregroundColor(.white)
    }

    private func timeline(elapsed: Double) -> some View {
        let duration = snap.duration
        let value = dragValue ?? elapsed
        return HStack(spacing: 8) {
            Text(Self.format(value))
            Slider(
                value: Binding(get: { min(value, duration ?? 1) }, set: { dragValue = $0 }),
                in: 0...(duration ?? 1)
            ) { editing in
                shell.interacting = editing
                if !editing, let v = dragValue {
                    media.seek(toSeconds: v)
                    dragValue = nil
                }
            }
            .controlSize(.small)
            .tint(.white)
            .disabled(duration == nil)
            .accessibilityLabel("Posisi lagu")
            .accessibilityValue(duration.map { "\(Self.format(value)) dari \(Self.format($0))" } ?? Self.format(value))
            .help(duration == nil ? "Durasi tidak tersedia, geser dimatikan" : "Geser untuk mencari posisi")
            Text(duration.map { "-" + Self.format(max(0, $0 - value)) } ?? "--:--")
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundColor(Palette.secondary)
    }

    // MARK: states

    private func unavailable(_ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundColor(Palette.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let detail = media.errorDetail {
                Text(detail).font(.system(size: 11)).foregroundColor(Palette.secondary).multilineTextAlignment(.center).lineLimit(2)
                    .help(detail)
            }
            Button("Coba lagi") { media.retry() }
                .buttonStyle(ShellControlStyle(kind: .quiet))
                .help("Jalankan ulang adaptor musik")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(Palette.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundColor(Palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
