import AppKit
import SwiftUI

/// Root shell view inside a fixed, oversized host. Layouts follow the destination geometry only;
/// NotchPanel reveals them through the presented silhouette, so motion never re-lays out features.
struct NotchView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var preferences: Preferences
    let content: AnyView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Open: body waits 60 ms for the shell to lead, then fades in 120 ms. Close: fades out 80 ms.
    private var bodyFade: Animation {
        if reduceMotion { return .easeOut(duration: 0.1) }
        return shell.expanded ? .easeOut(duration: 0.12).delay(0.06) : .easeOut(duration: 0.08)
    }

    private var compactFade: Animation {
        if reduceMotion { return .easeOut(duration: 0.1) }
        return shell.expanded ? .easeOut(duration: 0.06) : .easeOut(duration: 0.12).delay(0.08)
    }

    var body: some View {
        ZStack(alignment: .top) {
            compact
                .frame(width: shell.layout.width, height: shell.layout.height, alignment: .top)
                .opacity(shell.expanded ? 0 : 1)
                .animation(compactFade, value: shell.expanded)
                .allowsHitTesting(!shell.expanded)
                .accessibilityHidden(shell.expanded)
            expanded
                .frame(width: shell.expandedLayout.width, height: shell.expandedLayout.height, alignment: .top)
                .opacity(shell.expanded ? 1 : 0)
                .animation(bodyFade, value: shell.expanded)
                .allowsHitTesting(shell.expanded)
                .accessibilityHidden(!shell.expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            content.frame(height: shell.expandedLayout.height - (shell.notice == nil ? 0 : ShellProfile.noticeStripHeight))
            if let notice = shell.notice {
                // Appended below the unchanged body and footer; never covers controls or takes focus.
                Button(action: shell.activateNotice) {
                    NoticeRow(notice: notice).padding(.horizontal, 24).frame(maxHeight: .infinity)
                }
                .buttonStyle(ShellControlStyle(kind: .plain))
                .frame(height: ShellProfile.noticeStripHeight)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 24) }
                .accessibilityLabel("\(notice.title), \(notice.subtitle). Buka")
            }
        }
    }

    // MARK: Compact presentations

    @ViewBuilder private var compact: some View {
        switch shell.profile.presentation {
        case .closed, .resting: closedRow
        case .transient:
            if let notice = shell.notice {
                VStack(spacing: 0) {
                    if shell.cameraWidth > 0 { Color.clear.frame(height: shell.clearance) }
                    Button(action: shell.activateNotice) {
                        NoticeRow(notice: notice).padding(.horizontal, 20).frame(maxHeight: .infinity)
                    }
                    .buttonStyle(ShellControlStyle(kind: .plain))
                    .accessibilityLabel("\(notice.title), \(notice.subtitle). Buka Notchy")
                }
            }
        case .minimal, .expanded, .lyrics, .taskEditor:
            Color.clear
        }
    }

    /// Status wings stay at camera height; the camera itself remains empty.
    @ViewBuilder private var closedRow: some View {
        let ring = RingGauge(progress: shell.ringProgress, tint: preferences.ringSource == "water" ? Palette.water : Palette.green, size: 16, line: 2.5)
            .help(shell.ringLabel)
        let clock = ClockText(size: 12, weight: .semibold).fixedSize()
        if shell.cameraWidth > 0 {
            let wing = max(0, (shell.layout.width - shell.cameraWidth) / 2)
            HStack(spacing: 0) {
                ring.frame(width: wing)
                Color.clear.frame(width: shell.cameraWidth)
                clock.padding(.trailing, 4).frame(width: wing)
            }
            .frame(height: shell.clearance)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(shell.ringLabel)
        } else {
            ViewThatFits(in: .horizontal) {
                if preferences.mascot, shell.profile.presentation == .resting {
                    HStack(spacing: 8) {
                        clock.hidden().accessibilityHidden(true).overlay(alignment: .leading) { ring }
                        Spacer(minLength: 0)
                        MascotEyes(sleeping: shell.idleSeconds >= 300 && !shell.waking, waking: shell.waking)
                        Spacer(minLength: 0)
                        clock
                    }
                }
                HStack {
                    ring
                    Spacer(minLength: 0)
                    clock
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(shell.ringLabel)
        }
    }
}
