import SwiftUI

/// Expanded body: camera-safe header, side page arrows, the mounted pages, and the position footer.
/// Every page stays mounted so drafts, scroll positions and seek gestures survive page changes.
struct FeatureView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: LocalStore
    let media: MediaController
    let lyrics: LyricsController
    let focus: FocusController
    let water: WaterController
    let tasks: TaskController
    let shelf: ShelfController
    let clipboard: ClipboardController
    let prayer: PrayerController
    let devices: DeviceMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if shell.expanded {
                ShellHeader(shell: shell, width: shell.expandedLayout.width)
            } else {
                Color.clear.frame(height: shell.clearance)
            }
            HStack(spacing: 0) {
                PageArrow(shell: shell, delta: -1).frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    if let error = store.error, shell.selectedTab != ShellTab.fokus.rawValue,
                       shell.selectedTab != ShellTab.air.rawValue, shell.selectedTab != ShellTab.tugas.rawValue {
                        Text(error).font(.system(size: 11)).lineLimit(2).help(error)
                            .textSelection(.enabled)
                    }
                    ZStack(alignment: .topLeading) {
                        page(.musik) { MusicView(media: media, lyrics: lyrics, shell: shell, preferences: preferences) }
                        page(.fokus) { FocusView(focus: focus, visible: shell.expanded && shell.selectedTab == ShellTab.fokus.rawValue) }
                        page(.air) { WaterView(controller: water, shell: shell) }
                        page(.shelf) { ShelfView(controller: shelf, shell: shell) }
                        page(.clipboard) { ClipboardView(clipboard: clipboard, preferences: preferences) }
                        page(.tugas) { TaskView(controller: tasks, shell: shell) }
                        page(.sholat) { PrayerView(controller: prayer, shell: shell, visible: shell.expanded && shell.selectedTab == ShellTab.sholat.rawValue) }
                        page(.widgets) { WidgetsView(tasks: tasks, devices: devices, shell: shell) }
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                PageArrow(shell: shell, delta: 1).frame(width: 40)
            }
            PageDots(shell: shell).frame(height: 24)
        }
        .tint(Palette.green)
        .environment(\.narrowShell, shell.narrow)
        .onChange(of: shell.selectedTab) { tab in
            if tab != ShellTab.musik.rawValue { shell.lyricsExpanded = false }
        }
    }

    /// A short directional crossfade preserves carousel position while hidden pages stay inert.
    private func page<Content: View>(_ tab: ShellTab, @ViewBuilder content: () -> Content) -> some View {
        let active = shell.selectedTab == tab.rawValue
        let index = ShellTab.allCases.firstIndex(of: tab) ?? 0
        let offset: CGFloat = reduceMotion || active ? 0 : index < shell.tabIndex ? -12 : 12
        return content()
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .opacity(active ? 1 : 0)
            .offset(x: offset)
            .allowsHitTesting(active)
            .disabled(!active)
            .accessibilityHidden(!active)
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: shell.selectedTab)
    }
}
