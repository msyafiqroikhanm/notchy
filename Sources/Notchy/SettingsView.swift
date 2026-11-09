import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var section = "Umum"

    var body: some View {
        VStack(spacing: 12) {
            ChoiceStrip(options: ["Umum", "Musik & Privasi", "Air", "Sholat"], selection: $section)
            switch section {
            case "Musik & Privasi": MusicPrivacySettings(preferences: preferences)
            case "Air": WaterSettings(preferences: preferences)
            case "Sholat": PrayerSettings(preferences: preferences)
            default: GeneralSettings(preferences: preferences)
            }
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 420)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Toggle("Maskot saat diam", isOn: $preferences.mascot)
            Toggle("Notch minimal (hanya pegangan tipis)", isOn: $preferences.minimal)
            Picker("Cincin status", selection: $preferences.ringSource) {
                Text("Baterai").tag("battery")
                Text("Air minum").tag("water")
            }
            Section {
                Toggle("Buka saat login", isOn: Binding(
                    get: { preferences.loginEnabled },
                    set: { preferences.setLogin(enabled: $0) }))
                if let error = preferences.loginError {
                    Text(error).foregroundColor(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { preferences.refreshLogin() }
    }
}

private struct MusicPrivacySettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Lirik") {
                Toggle("Tampilkan lirik sinkron", isOn: $preferences.lyricsEnabled)
                Text("Saat aktif, judul, artis, album, dan durasi lagu dikirim ke LRCLIB (lrclib.net) untuk mencari lirik. Tidak ada permintaan sebelum Anda mengaktifkannya.")
                    .font(.callout).foregroundColor(.secondary)
            }
            Section("Clipboard") {
                Toggle("Riwayat clipboard (teks saja)", isOn: $preferences.clipboardEnabled)
                Text("Nonaktif secara bawaan. Saat aktif, 20 teks terbaru disimpan hanya di memori dan tidak pernah ditulis ke disk. Salinan yang ditandai rahasia, sementara, atau otomatis dilewati, tetapi ini tidak bisa menjamin semua pengelola kata sandi menandai rahasia dengan benar.")
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WaterSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            PositiveIntegerSetting(title: "Target harian (ml)", value: $preferences.waterGoal)
            PositiveIntegerSetting(title: "Takaran sekali minum (ml)", value: $preferences.waterServing)
            Section("Pengingat") {
                Toggle("Aktifkan pengingat minum", isOn: $preferences.waterReminders)
                PositiveIntegerSetting(title: "Interval (menit)", value: $preferences.waterInterval)
                Stepper("Mulai: \(hour(preferences.waterStartHour))", value: $preferences.waterStartHour,
                        in: 0...(preferences.waterEndHour - 1))
                Stepper("Selesai: \(hour(preferences.waterEndHour))", value: $preferences.waterEndHour,
                        in: (preferences.waterStartHour + 1)...24)
                Text("Pengingat tidak muncul setelah target tercapai. Jam mengikuti waktu lokal Mac.")
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func hour(_ h: Int) -> String { String(format: "%02d:00", h) }
}

private struct PrayerSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var zoneText = ""
    @State private var error: String?

    private var parsed: (Double, Double)? {
        guard let lat = Self.number(latitudeText), let lon = Self.number(longitudeText) else { return nil }
        return (lat, lon)
    }

    private var draftMatchesApplied: Bool {
        guard let (lat, lon) = parsed else { return false }
        return lat == preferences.latitude && lon == preferences.longitude && zoneText == preferences.timeZoneID
    }

    var body: some View {
        Form {
            Toggle("Aktifkan waktu sholat", isOn: $preferences.prayerEnabled)
            Section("Lokasi") {
                Text(preferences.isJakartaPreset && !preferences.locationConfirmed
                     ? "Jakarta adalah preset awal, bukan lokasi yang terdeteksi. Notchy tidak memakai layanan lokasi."
                     : "Koordinat diisi manual. Notchy tidak memakai layanan lokasi.")
                    .font(.callout).foregroundColor(.secondary)
                TextField("Lintang", text: $latitudeText)
                TextField("Bujur", text: $longitudeText)
                TextField("Zona waktu (ID)", text: $zoneText)
                if let error { Text(error).foregroundColor(.red).font(.callout) }
                HStack {
                    Button("Terapkan") { apply() }
                        .disabled(draftMatchesApplied)
                    Button("Preset Jakarta") { loadJakartaDraft() }
                    Spacer()
                    if preferences.locationConfirmed {
                        Label("Lokasi dikonfirmasi", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    } else {
                        Button("Konfirmasi lokasi ini") { preferences.locationConfirmed = true }
                            .disabled(!draftMatchesApplied)
                    }
                }
            }
            Section("Pengingat") {
                Toggle("Pengingat sholat (10 menit sebelum dan saat waktunya)", isOn: $preferences.prayerReminders)
                    .disabled(!preferences.locationConfirmed)
                Toggle("Jeda musik saat waktu sholat", isOn: $preferences.prayerPauseMusic)
                    .disabled(!preferences.locationConfirmed)
                if !preferences.locationConfirmed {
                    Text("Konfirmasi lokasi terlebih dahulu untuk mengaktifkan pengingat.")
                        .font(.callout).foregroundColor(.secondary)
                }
                Text("Waktu dihitung (Kemenag: Subuh −20°, Isya −18°). Periksa jadwal masjid setempat.")
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: syncDraft)
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func syncDraft() {
        latitudeText = String(preferences.latitude)
        longitudeText = String(preferences.longitude)
        zoneText = preferences.timeZoneID
    }

    private func loadJakartaDraft() {
        latitudeText = String(Preferences.jakartaLatitude)
        longitudeText = String(Preferences.jakartaLongitude)
        zoneText = Preferences.jakartaTimeZone
        error = nil
    }

    private func apply() {
        guard let (lat, lon) = parsed else {
            error = "Lintang dan bujur harus berupa angka."
            return
        }
        error = preferences.applyLocation(latitude: lat, longitude: lon,
                                          timeZoneID: zoneText.trimmingCharacters(in: .whitespaces))
        if error == nil { syncDraft() }
    }
}

private struct PositiveIntegerSetting: View {
    let title: String
    @Binding var value: Int
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField(title, text: $draft)
                    .onSubmit(save)
                Button("Simpan", action: save)
                    .disabled(draft == String(value))
                    .accessibilityLabel("Simpan \(title)")
            }
            if let error { Text(error).foregroundColor(.red) }
        }
        .onAppear { draft = String(value) }
    }

    private func save() {
        guard let number = Int(draft), number > 0 else {
            error = "Masukkan bilangan bulat positif yang valid."
            return
        }
        value = number
        error = nil
    }
}
