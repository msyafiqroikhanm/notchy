import AppKit
import SwiftUI

/// Shelf page: real file references, with a drop outline only when empty or accepting additions.
struct ShelfView: View {
    @ObservedObject var controller: ShelfController
    @ObservedObject var shell: ShellState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var acknowledged = false
    @State private var knownCount = 0

    private var accepting: Bool { shell.dragHover || acknowledged }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let error = controller.error {
                    Text(error).font(.system(size: 11)).lineLimit(1).help(error)
                    Button("Tutup") { controller.error = nil }
                        .buttonStyle(ShellControlStyle(kind: .plain)).font(.system(size: 11, weight: .semibold))
                } else {
                    Text(controller.items.isEmpty ? "Referensi file" : "\(controller.items.count) referensi")
                        .font(.system(size: 11)).foregroundColor(Palette.secondary)
                }
                Spacer(minLength: 0)
                Button { choose() } label: { Label("Tambah", systemImage: "plus") }
                    .buttonStyle(ShellControlStyle(kind: .plain)).font(.system(size: 12, weight: .semibold))
                    .help("Pilih file atau folder")
                if !controller.items.isEmpty {
                    Button("Bersihkan") { controller.clear() }
                        .buttonStyle(ShellControlStyle(kind: .plain)).font(.system(size: 12)).foregroundColor(Palette.secondary)
                        .help("Hapus semua referensi; file asli tidak dihapus")
                }
            }
            .accessibilityElement(children: .contain)

            zone
        }
        .onAppear { knownCount = controller.items.count }
        .onChange(of: controller.items.count) { new in
            // One 180 ms acknowledgement per successful addition; no repeating demo animation.
            defer { knownCount = new }
            guard new > knownCount, !reduceMotion else { return }
            acknowledged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { acknowledged = false }
        }
    }

    private var zone: some View {
        Group {
            if controller.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 18)).foregroundColor(Palette.secondary).accessibilityHidden(true)
                    Text("Seret file atau folder ke sini").font(.system(size: 13, weight: .medium))
                    Text("Hanya referensi yang disimpan; file asli tidak dipindahkan.")
                        .font(.system(size: 11)).foregroundColor(Palette.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                        ForEach(controller.items) { tile($0) }
                    }
                    .padding(8)
                }
            }
        }
        .background(
            Group {
                if controller.items.isEmpty || accepting {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(accepting ? Palette.green : Palette.secondary,
                                      style: StrokeStyle(lineWidth: accepting ? 2 : 1, dash: [5, 4]))
                }
            }
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: accepting)
    }

    private func tile(_ item: ShelfItem) -> some View {
        VStack(spacing: 2) {
            Button { controller.open(item) } label: {
                VStack(spacing: 2) {
                    Image(nsImage: item.icon).resizable().frame(width: 30, height: 30).opacity(item.available ? 1 : 0.5)
                    Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(item.available ? item.size : "Tidak ditemukan").font(.system(size: 10)).foregroundColor(Palette.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(ShellControlStyle(kind: .plain))
            .help(item.url?.path ?? "File tidak ditemukan")
            .accessibilityLabel(item.available ? "Buka \(item.name), \(item.size)" : "\(item.name), tidak ditemukan")
            .modifier(DragOut(url: item.url))
        }
        .overlay(alignment: .topTrailing) {
            Button { controller.remove(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 24, height: 24).background(Circle().fill(Palette.control))
            }
            .buttonStyle(ShellControlStyle(kind: .icon(24)))
            .foregroundColor(.white)
            .help("Hapus dari Shelf (file asli tetap ada)").accessibilityLabel("Hapus \(item.name) dari Shelf")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        shell.interacting = true
        panel.begin { response in
            shell.interacting = false
            if response == .OK { controller.add(urls: panel.urls) }
        }
    }
}

/// Drags the original file URL out (Finder copies/moves the real file, the shelf entry stays).
/// shortcut: SwiftUI onDrag vends public.file-url via NSURL; not verified against every drop target, move to NSDraggingSource if one rejects it.
private struct DragOut: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.onDrag { NSItemProvider(object: url as NSURL) } } else { content }
    }
}
