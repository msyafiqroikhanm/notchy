import SwiftUI

/// Fokus page: one centered mode, countdown, session progress and action group.
/// Uses the existing 25/5 minute deadline semantics only; no rounds, long breaks or automatic phases.
struct FocusView: View {
    @ObservedObject var focus: FocusController
    var visible = true

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var full: Double { FocusController.durations[focus.session.mode] ?? 1 }
    private var resumable: Bool { !focus.running && !focus.finished && focus.session.remaining < full }

    var body: some View {
        ViewThatFits(in: .vertical) {
            controls(actionFirst: false)
            ScrollView { controls(actionFirst: true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func controls(actionFirst: Bool) -> some View {
        VStack(spacing: 6) {
            if actionFirst { actions }
            Picker("Mode fokus", selection: Binding(get: { focus.session.mode }, set: { focus.setMode($0) })) {
                Text("Fokus 25 mnt").tag("focus")
                Text("Istirahat 5 mnt").tag("break")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(focus.running)
            .accessibilityLabel("Mode fokus")

            TimelineView(.animation(minimumInterval: 1, paused: !visible || !focus.running)) { ctx in
                let left = focus.remaining(at: ctx.date)
                VStack(spacing: 6) {
                    Text(focus.finished ? "Selesai" : format(left))
                        .font(.system(size: 36, weight: .semibold).monospacedDigit())
                    ProgressView(value: focus.finished ? 1 : max(0, min(1, 1 - left / full)))
                        .progressViewStyle(.linear)
                        .tint(focus.running ? Palette.focus : .white)
                        .frame(maxWidth: 220)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(focus.finished ? "Sesi selesai" : "Sisa waktu \(format(left))")
                .accessibilityValue(focus.running ? "Berjalan" : resumable ? "Dijeda" : "Siap")
            }

            if !actionFirst { actions }

            if let error = focus.error {
                Text(error).font(.system(size: 11)).lineLimit(2).help(error)
                    .accessibilityLabel("Kesalahan penyimpanan: \(error)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                focus.running ? focus.pause() : focus.start()
            } label: {
                Label(focus.running ? "Jeda" : resumable ? "Lanjut" : "Mulai",
                      systemImage: focus.running ? "pause.fill" : "play.fill")
            }
            .buttonStyle(ShellControlStyle(kind: .fill(Palette.focus)))
            .help(focus.running ? "Jeda sesi" : "Mulai atau lanjutkan sesi")
            Button { focus.reset() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(ShellControlStyle(kind: .icon(28)))
            .accessibilityLabel("Reset")
            .help("Atur ulang ke durasi penuh")
        }
    }
}
