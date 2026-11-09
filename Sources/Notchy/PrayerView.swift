import SwiftUI

private let unavailable = "Tidak tersedia di lokasi/tanggal ini"

/// Sholat page: next prayer, time and countdown with a small sun arc on the left; five times on the right.
/// Location and calculation disclosures sit behind a labelled info control instead of being removed.
struct PrayerView: View {
    @ObservedObject var controller: PrayerController
    @ObservedObject var shell: ShellState
    @Environment(\.narrowShell) private var narrow
    var visible = true
    @State private var showInfo = false

    var body: some View {
        // The controller republishes at every prayer/midnight; the minute timeline keeps the arc and spoken text current.
        Group {
            if visible {
                TimelineView(.periodic(from: Date(), by: 60)) { _ in content(controller.now()) }
            } else {
                content(controller.now())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onChange(of: showInfo) { presented in
            shell.prayerInfoPresented = presented && visible
        }
        .onChange(of: visible) { active in
            if !active { dismissInfo() }
        }
        .onChange(of: shell.expanded) { expanded in
            if !expanded { dismissInfo() }
        }
        .onChange(of: shell.selectedTab) { tab in
            if tab != ShellTab.sholat.rawValue { dismissInfo() }
        }
        .onDisappear(perform: dismissInfo)
    }

    @ViewBuilder
    private func content(_ t: Date) -> some View {
        let prefs = controller.preferences
        if !prefs.prayerEnabled {
            notice("moon.zzz", "Waktu sholat nonaktif", "Aktifkan di Pengaturan untuk melihat jadwal dan pengingat.")
        } else if let error = controller.locationError {
            notice("exclamationmark.triangle.fill", "Lokasi tidak valid", error)
        } else if let today = controller.day(from: t) {
            let next = controller.next(after: t)
            Group {
                if narrow {
                    Columns(narrow: true) { prayerColumns(today, next, t, prefs) }
                } else {
                    HStack(spacing: 20) { prayerColumns(today, next, t, prefs) }
                }
            }
        }
    }

    @ViewBuilder
    private func prayerColumns(_ today: PrayerDay, _ next: (prayer: Prayer, date: Date)?, _ t: Date, _ prefs: Preferences) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(next, t)
            arc(today, t)
            infoButton(prefs)
        }
        .frame(width: narrow ? nil : 188, alignment: .leading)
        list(today, next?.prayer)
    }

    private func dismissInfo() {
        showInfo = false
        shell.prayerInfoPresented = false
    }

    // MARK: next prayer

    private func header(_ next: (prayer: Prayer, date: Date)?, _ t: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let next {
                Text(next.prayer.name).font(.system(size: 24, weight: .semibold))
                HStack(spacing: 8) {
                    Text(controller.hm(next.date)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(MusicView.format(max(0, next.date.timeIntervalSince(t))))
                        .font(.system(size: 13).monospacedDigit()).foregroundColor(Palette.secondary)
                        .accessibilityHidden(true)
                }
            } else {
                Text(unavailable).font(.system(size: 13)).foregroundColor(Palette.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sholat berikutnya")
        .accessibilityValue(next.map {
            "\($0.prayer.name) pukul \(controller.hm($0.date)), \(Self.spoken($0.date.timeIntervalSince(t)))"
        } ?? unavailable)
    }

    private static func spoken(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        return m >= 60 ? "dalam \(m / 60) jam \(m % 60) menit" : "dalam \(m) menit"
    }

    // MARK: list

    private func list(_ today: PrayerDay, _ next: Prayer?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Prayer.allCases, id: \.self) { p in
                let time = today.time(p)
                let isNext = p == next
                HStack(spacing: 8) {
                    Text(p.name).font(.system(size: 13, weight: isNext ? .semibold : .regular))
                    Spacer(minLength: 8)
                    if let time {
                        Text(controller.hm(time)).font(.system(size: 13, weight: isNext ? .semibold : .regular).monospacedDigit())
                    } else {
                        Text(unavailable).font(.system(size: 11)).foregroundColor(Palette.secondary).lineLimit(1)
                    }
                }
                .foregroundColor(isNext ? .black : .white)
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isNext ? Color.white : Color.clear))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.name)
                .accessibilityValue((time.map { controller.hm($0) } ?? unavailable) + (isNext ? ", berikutnya" : ""))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: sun arc

    private func arc(_ today: PrayerDay, _ t: Date) -> some View {
        guard let rise = today.sunrise, let set = today.maghrib, set > rise else {
            return AnyView(Text("Matahari terbit/terbenam: \(unavailable.lowercased())")
                .font(.system(size: 10)).foregroundColor(Palette.secondary).lineLimit(2))
        }
        let fraction = max(0, min(1, t.timeIntervalSince(rise) / set.timeIntervalSince(rise)))
        let state = t < rise ? "Matahari belum terbit" : t > set ? "Matahari sudah terbenam" : "Matahari di atas cakrawala"
        return AnyView(
            HStack(alignment: .bottom, spacing: 6) {
                Text(controller.hm(rise))
                SunArc(fraction: fraction, up: t >= rise && t <= set).frame(width: 80, height: 26)
                Text(controller.hm(set))
            }
            .font(.system(size: 10).monospacedDigit()).foregroundColor(Palette.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Busur matahari")
            .accessibilityValue("Terbit \(controller.hm(rise)), terbenam \(controller.hm(set)). \(state)."))
    }

    // MARK: disclosures

    private func infoButton(_ prefs: Preferences) -> some View {
        Button {
            guard visible, shell.expanded else { return }
            shell.prayerInfoPresented = true
            showInfo = true
        } label: {
            Label(prefs.locationConfirmed ? "Lokasi & metode" : "Konfirmasi lokasi",
                  systemImage: prefs.locationConfirmed ? "info.circle" : "mappin.slash")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(ShellControlStyle(kind: .plain))
        .help("Lokasi, metode perhitungan, dan status pengingat")
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            disclosure(prefs)
                .padding(12)
                .frame(width: 280)
                .frame(maxHeight: 240)
                .onExitCommand(perform: dismissInfo)
        }
    }

    private func disclosure(_ prefs: Preferences) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !prefs.locationConfirmed {
                    Text(prefs.isJakartaPreset
                         ? "Jakarta adalah preset awal, bukan lokasi terdeteksi. Konfirmasi lokasi di Pengaturan agar pengingat aktif."
                         : "Lokasi belum dikonfirmasi. Konfirmasi di Pengaturan agar pengingat aktif.")
                        .foregroundColor(.white)
                } else if !prefs.prayerReminders {
                    Text("Pengingat nonaktif. Aktifkan di Pengaturan.").foregroundColor(.white)
                }
                Text("Dihitung di perangkat (Kemenag: Subuh −20°, Isya −18°), bukan jadwal resmi. Periksa jadwal masjid setempat.")
                    .foregroundColor(Palette.secondary)
                Button("Pengaturan") {
                    dismissInfo()
                    shell.requestSettings()
                }
                .buttonStyle(ShellControlStyle(kind: .quiet))
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notice(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundColor(Palette.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Half-ellipse horizon arc; white up to the sun's position, dot only while the sun is up.
private struct SunArc: View {
    let fraction: Double
    let up: Bool

    var body: some View {
        Canvas { ctx, size in
            let base = size.height - 2
            func point(_ f: Double) -> CGPoint {
                let phi = Double.pi * f
                return CGPoint(x: size.width / 2 - CGFloat(Darwin.cos(phi)) * (size.width / 2 - 4),
                               y: base - CGFloat(Darwin.sin(phi)) * (base - 4))
            }
            func path(_ to: Double) -> Path {
                var p = Path()
                p.move(to: point(0))
                for i in 1...32 { p.addLine(to: point(to * Double(i) / 32)) }
                return p
            }
            ctx.stroke(path(1), with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            guard up else { return }
            ctx.stroke(path(fraction), with: .color(.white), lineWidth: 1.5)
            let s = point(fraction)
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6)), with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}
