import SwiftUI
import AppKit

/// Side lyrics pane. `position` is the interpolated playback time from MusicView; `onSeek` seeks the player.
struct LyricsView: View {
    @ObservedObject var lyrics: LyricsController
    let position: TimeInterval
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void

    private let muted = Palette.secondary

    var body: some View {
        Group {
            switch lyrics.state {
            case .synced(let lines): syncedList(lines)
            case .plain(let text):
                ScrollView { Text(text).font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            case .loading: message("Memuat lirik…", icon: "ellipsis")
            case .instrumental: message("Instrumental", icon: "pianokeys")
            case .notFound: message("Lirik tidak ditemukan", icon: "text.magnifyingglass")
            case .idle: message("Tidak ada lagu", icon: "music.note")
            case .disabled: message("Lirik dimatikan di Pengaturan", icon: "text.quote")
            case .failed(let why):
                VStack(spacing: 8) {
                    message("Gagal memuat lirik", icon: "exclamationmark.triangle", detail: why)
                    Button("Coba lagi") { lyrics.retry() }.buttonStyle(ShellControlStyle(kind: .quiet)).help("Muat ulang lirik")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lirik")
    }

    private func syncedList(_ lines: [LyricLine]) -> some View {
        let active = LyricsController.activeIndex(in: lines, at: position)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        let i = line.id
                        let isActive = i == active
                        let label = Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: isActive ? 14 : 13, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? .white : muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Unknown duration: lines stay readable text instead of dimmed dead buttons.
                        Group {
                            if canSeek {
                                Button { onSeek(line.time) } label: { label }
                                    .buttonStyle(ShellControlStyle(kind: .plain))
                                    .help("Loncat ke baris ini")
                            } else {
                                label
                            }
                        }
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .id(i)
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 4)
            }
            // scrollTo moves the viewport only; focus is untouched.
            .onChange(of: active) { new in
                guard let new else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { proxy.scrollTo(new, anchor: .center) }
                else { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    private func message(_ text: String, icon: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(muted).accessibilityHidden(true)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundColor(muted)
                    .multilineTextAlignment(.center).lineLimit(3).help(detail)
            }
        }
        .padding(8)
    }
}
