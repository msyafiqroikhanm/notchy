import SwiftUI

/// Clipboard page: opt-in prompt, empty state, or newest-first text rows. Memory only.
struct ClipboardView: View {
    @ObservedObject var clipboard: ClipboardController
    @ObservedObject var preferences: Preferences
    @State private var copied: String?

    var body: some View {
        if !preferences.clipboardEnabled {
            ViewThatFits(in: .vertical) {
                disclosure.fixedSize(horizontal: false, vertical: true)
                ScrollView { disclosure }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        historyStatus
                        Spacer(minLength: 0)
                        historyActions
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        historyStatus
                        historyActions
                    }
                }
                Text("Nonaktifkan menghapus riwayat dari memori")
                    .font(.system(size: 11)).foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if clipboard.entries.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 18)).foregroundColor(Palette.secondary).accessibilityHidden(true)
                        Text("Belum ada teks disalin").font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(clipboard.entries, id: \.self) { row($0) }
                        }
                    }
                }
            }
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Riwayat clipboard nonaktif").font(.system(size: 13, weight: .medium))
            Text("Saat aktif, 20 teks terbaru disimpan hanya di memori. Salinan yang ditandai rahasia atau sementara dilewati, tetapi tidak semua pengelola kata sandi menandainya.")
                .font(.system(size: 11)).foregroundColor(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Aktifkan riwayat") { preferences.clipboardEnabled = true }
                .buttonStyle(ShellControlStyle(kind: .quiet))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyStatus: some View {
        Text(clipboard.entries.isEmpty ? "Hanya di memori" : "\(clipboard.entries.count) teks · hanya di memori")
            .font(.system(size: 11)).foregroundColor(Palette.secondary)
            .fixedSize()
    }

    private var historyActions: some View {
        HStack(spacing: 8) {
            if !clipboard.entries.isEmpty {
                Button("Kosongkan") { clipboard.clear() }
                    .buttonStyle(ShellControlStyle(kind: .plain)).font(.system(size: 12)).foregroundColor(Palette.secondary)
            }
            Button("Nonaktifkan") { preferences.clipboardEnabled = false }
                .buttonStyle(ShellControlStyle(kind: .plain)).font(.system(size: 12)).foregroundColor(Palette.secondary)
                .help("Berhenti membaca clipboard dan hapus riwayat dari memori")
        }
        .fixedSize()
    }

    private func row(_ text: String) -> some View {
        Button {
            clipboard.copy(text)
            copied = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == text { copied = nil } }
        } label: {
            HStack(spacing: 8) {
                Text(text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if copied == text { Text("Disalin").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.green) }
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(ShellControlStyle(kind: .plain))
        .onDrag { NSItemProvider(object: text as NSString) }
        .help("Klik untuk menyalin, seret untuk menyisipkan")
        .accessibilityLabel("Salin: \(text)")
    }
}
