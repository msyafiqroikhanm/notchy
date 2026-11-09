import AppKit
import SwiftUI

/// Shell palette. Secondary text #A6A6AE on black measures 8.69:1; accents mark one job each.
enum Palette {
    static let secondary = Color(red: 0xa6 / 255, green: 0xa6 / 255, blue: 0xae / 255)
    static let control = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    /// Battery, completed tasks, Shelf acceptance.
    static let green = Color(red: 0x33 / 255, green: 0xd1 / 255, blue: 0x7a / 255)
    /// Focus progress and primary action.
    static let focus = Color(red: 0xb4 / 255, green: 0x9a / 255, blue: 0xff / 255)
    static let water = Color(red: 0x67 / 255, green: 0xd7 / 255, blue: 0xff / 255)
}

/// Every shell control: pressed and disabled states plus a 2 pt white keyboard-focus outline (21:1 on black).
struct ShellControlStyle: ButtonStyle {
    enum Kind { case circle(CGFloat), icon(CGFloat), fill(Color), quiet, plain }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View { ControlFace(configuration: configuration, kind: kind) }

    private struct ControlFace: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Group {
                switch kind {
                case .circle(let d):
                    configuration.label.frame(width: d, height: d)
                        .background(Circle().fill(Palette.control))
                        .overlay(Circle().stroke(Color.white, lineWidth: focused ? 2 : 0))
                        .contentShape(Circle())
                case .icon(let d):
                    configuration.label.frame(width: d, height: d)
                        .contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: focused ? 2 : 0))
                case .fill(let color):
                    configuration.label.font(.system(size: 13, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 12).frame(minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(color))
                        .overlay(RoundedRectangle(cornerRadius: 8).inset(by: -3).stroke(Color.white, lineWidth: focused ? 2 : 0))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                case .quiet:
                    configuration.label.font(.system(size: 13)).foregroundColor(.white)
                        .padding(.horizontal, 10).frame(minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.control))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: focused ? 2 : 0))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                case .plain:
                    configuration.label.contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 6).inset(by: -2).stroke(Color.white, lineWidth: focused ? 2 : 0))
                }
            }
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.38)
        }
    }
}
/// Two columns at normal width; one scrollable column when the screen forces the body under 480 pt.
struct Columns<Content: View>: View {
    let narrow: Bool
    var spacing: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        if narrow {
            ScrollView { VStack(alignment: .leading, spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension ShellState {
    var narrow: Bool { expandedLayout.width < 480 }
}

private struct NarrowShellKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when the screen forces the expanded body under 480 pt; pages switch to one column.
    var narrowShell: Bool {
        get { self[NarrowShellKey.self] }
        set { self[NarrowShellKey.self] = newValue }
    }
}


/// Actual progress ring; nil progress draws only the track and the caller must say "unavailable".
struct RingGauge: View {
    let progress: Double?
    var tint = Palette.green
    var size: CGFloat = 18
    var line: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.3), lineWidth: line)
            if let progress {
                Circle().trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Minute-resolution clock; no per-second redraw.
struct ClockText: View {
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(ctx.date, format: Date.VerbatimFormatStyle(
                format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent))
                .font(.system(size: size, weight: weight).monospacedDigit())
        }
    }
}

/// Expanded header: page menu and hide control flank an empty camera gap.
struct ShellHeader: View {
    @ObservedObject var shell: ShellState
    let width: CGFloat

    private var flank: CGFloat { shell.cameraWidth > 0 ? max(0, (width - shell.cameraWidth) / 2) : width / 2 }

    var body: some View {
        HStack(spacing: 0) {
            PageMenu(shell: shell)
                .padding(.leading, 20)
                .frame(width: flank, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: shell.requestDismiss) {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
            }
                .buttonStyle(ShellControlStyle(kind: .icon(24)))
                .accessibilityLabel("Sembunyikan panel")
                .help("Sembunyikan panel")
                .padding(.trailing, 20)
                .frame(width: flank, alignment: .trailing)
        }
        .frame(width: width, height: shell.clearance)
    }

}

/// Title menu: direct, keyboard-accessible page selection plus Settings and Hide.
struct PageMenu: View {
    @ObservedObject var shell: ShellState

    var body: some View {
        Menu {
            ForEach(ShellTab.allCases, id: \.self) { tab in
                Button { shell.selectedTab = tab.rawValue } label: {
                    if tab.rawValue == shell.selectedTab { Label(tab.rawValue, systemImage: "checkmark") } else { Text(tab.rawValue) }
                }
            }
            Divider()
            Button("Pengaturan…", action: shell.requestSettings)
            Button("Sembunyikan panel", action: shell.requestDismiss)
        } label: {
            Text(shell.selectedTab).font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .tint(.white)
        .fixedSize()
        .accessibilityLabel("Halaman \(shell.selectedTab)")
        .help("Pilih halaman, buka pengaturan, atau sembunyikan panel (⌘⌥← / ⌘⌥→ untuk berpindah)")
    }
}

/// Side-edge previous/next control; disabled at the first/last page, no wrapping.
struct PageArrow: View {
    @ObservedObject var shell: ShellState
    let delta: Int

    var body: some View {
        Button { shell.step(delta) } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(ShellControlStyle(kind: .circle(24)))
        .disabled(!shell.canStep(delta))
        .accessibilityLabel(delta < 0 ? "Halaman sebelumnya" : "Halaman berikutnya")
        .help(delta < 0 ? "Halaman sebelumnya (⌘⌥←)" : "Halaman berikutnya (⌘⌥→)")
    }
}

/// Position indicator, not a pointer target.
struct PageDots: View {
    @ObservedObject var shell: ShellState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tabs = ShellTab.allCases
        HStack(spacing: 5) {
            ForEach(tabs, id: \.self) { tab in
                let current = tab.rawValue == shell.selectedTab
                Capsule().fill(current ? Color.white : Palette.secondary)
                    .frame(width: current ? 14 : 5, height: 5)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: shell.selectedTab)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Halaman \(shell.tabIndex + 1) dari \(tabs.count): \(shell.selectedTab)")
    }
}

/// Resting companion below the camera. One blink and one fading underglow on wake; static otherwise.
struct MascotEyes: View {
    let sleeping: Bool
    let waking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false
    @State private var glow = 0.0

    var body: some View {
        HStack(spacing: 12) { eye; eye }
            .background(
                Ellipse().fill(Color(red: 0.43, green: 0.42, blue: 1))
                    .frame(width: 46, height: 10).blur(radius: 6).opacity(glow).offset(y: 6)
            )
            .onChange(of: waking) { awake in
                guard awake, !reduceMotion else { return }
                blink = true
                glow = 0.85
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) { blink = false }
                    withAnimation(.easeOut(duration: 0.9)) { glow = 0 }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sleeping ? "Maskot Notchy, tidur" : "Maskot Notchy, terjaga")
    }

    @ViewBuilder private var eye: some View {
        if sleeping {
            Capsule().fill(Color.white).frame(width: 7, height: 1.5)
        } else {
            RoundedRectangle(cornerRadius: 2).fill(Color.white)
                .frame(width: 5, height: 7)
                .scaleEffect(x: 1, y: blink ? 0.15 : 1)
        }
    }
}

/// Icon, title/subtitle and actual trailing value. Shared by the standalone transient and the expanded strip.
struct NoticeRow: View {
    let notice: ShellNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(notice.kind == .charging ? Palette.green : .white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.control))
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(notice.subtitle).font(.system(size: 11)).foregroundColor(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let trailing = notice.trailingText {
                Text(trailing).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            if let progress = notice.progress { RingGauge(progress: progress, size: 18) }
        }
        .help("\(notice.title). \(notice.subtitle)")
    }
}
