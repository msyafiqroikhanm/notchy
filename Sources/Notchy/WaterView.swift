import SwiftUI

/// Air page: today's real intake against the configured target on the left, actual hourly bars on the right.
struct WaterView: View {
    @ObservedObject var controller: WaterController
    @ObservedObject var shell: ShellState
    @Environment(\.narrowShell) private var narrow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var error: String? { controller.store.error ?? controller.actionError }

    private static func litres(_ ml: Int) -> String {
        (Double(ml) / 1000).formatted(.number.precision(.fractionLength(1))) + " L"
    }

    var body: some View {
        Group {
            if narrow {
                Columns(narrow: true) { content }
            } else {
                ViewThatFits(in: .vertical) {
                    HStack(spacing: 20) { content }.fixedSize(horizontal: false, vertical: true)
                    ScrollView { HStack(spacing: 20) { content }.fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var content: some View {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.litres(controller.total)).font(.system(size: 28, weight: .semibold).monospacedDigit())
                    Text("dari \(Self.litres(controller.goal)) · \(Int((controller.progress * 100).rounded()))%")
                        .font(.system(size: 12).monospacedDigit()).foregroundColor(Palette.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Air hari ini \(controller.total) dari \(controller.goal) mililiter")
                ProgressView(value: controller.progress)
                    .progressViewStyle(.linear)
                    .tint(Palette.water)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Button("+\(controller.serving) ml") { controller.drink() }
                        .buttonStyle(ShellControlStyle(kind: .fill(Palette.water)))
                        .help("Catat satu porsi").accessibilityLabel("Minum \(controller.serving) mililiter")
                    Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(ShellControlStyle(kind: .icon(24)))
                        .disabled(controller.entriesToday.isEmpty)
                        .help("Batalkan catatan terakhir hari ini").accessibilityLabel("Batalkan catatan terakhir")
                    Button(action: shell.requestSettings) { Image(systemName: "gearshape") }
                        .buttonStyle(ShellControlStyle(kind: .icon(24)))
                        .help("Atur target, porsi dan jam aktif").accessibilityLabel("Pengaturan air")
                }
                .fixedSize(horizontal: true, vertical: false)
                if let error {
                    HStack(spacing: 6) {
                        Text(error).font(.system(size: 11)).lineLimit(1).help(error)
                        if controller.actionError != nil {
                            Button("Tutup") { controller.actionError = nil }.buttonStyle(ShellControlStyle(kind: .plain)).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(width: narrow ? nil : 188, alignment: .leading)

            bars(controller.hourly)
    }

    private func bars(_ hourly: [Int]) -> some View {
        let peak = max(hourly.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Per jam" + (hourly.contains(where: { $0 > 0 }) ? " · puncak \(peak) ml" : ""))
                .font(.system(size: 11).monospacedDigit()).foregroundColor(Palette.secondary)
            Group {
                if controller.entriesToday.isEmpty {
                    Text("Belum ada catatan hari ini")
                        .font(.system(size: 12)).foregroundColor(Palette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<24, id: \.self) { h in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.water)
                                .frame(height: hourly[h] > 0 ? max(4, 72 * CGFloat(hourly[h]) / CGFloat(peak)) : 0)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .help("\(String(format: "%02d", h)):00 · \(hourly[h]) ml")
                        }
                    }
                }
            }
            .frame(height: 76)
            // Only a real record/undo changes these values, so page entry never replays the bars.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hourly)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Konsumsi air per jam")
            .accessibilityValue(hourly.enumerated().filter { $0.element > 0 }
                .map { "\(String(format: "%02d", $0.offset)):00 \($0.element) ml" }.joined(separator: ", ").nonEmpty ?? "Belum ada catatan")
            Rectangle().fill(Palette.secondary).frame(height: 1).accessibilityHidden(true)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { hour in
                    Text(hour).fixedSize()
                    if hour != "24" { Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 10).monospacedDigit()).foregroundColor(Palette.secondary)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
