import SwiftUI

/// Tugas page: a compact completion/Add row above the full-width actionable list.
/// Add/Edit opens a full-width inline composer in the taller task profile. Drafts live in the controller.
struct TaskView: View {
    @ObservedObject var controller: TaskController
    @ObservedObject var shell: ShellState
    @State private var composeNew = false
    @FocusState private var fieldFocused: Bool

    private var error: String? { controller.store.error ?? controller.actionError }
    private var editorOpen: Bool { composeNew || controller.editingID != nil }

    var body: some View {
        Group {
            if editorOpen { composer } else { overview }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            let compose = $composeNew
            shell.cancelTaskEditor = { [controller] in
                compose.wrappedValue = false
                controller.cancelEdit()
            }
            sync()
        }
        .onChange(of: composeNew) { _ in sync() }
        .onChange(of: controller.editingID) { _ in sync() }
        .onChange(of: fieldFocused) { _ in sync() }
        .onChange(of: shell.expanded) { _ in sync() }
        .onChange(of: shell.selectedTab) { _ in sync() }
        .onDisappear { shell.interacting = false }
    }

    /// The editor sizes the shell only on this page; it also holds the shell open while the pointer is outside.
    private func sync() {
        if shell.taskEditorExpanded != editorOpen { shell.taskEditorExpanded = editorOpen }
        shell.interacting = shell.expanded && shell.selectedTab == ShellTab.tugas.rawValue && (editorOpen || fieldFocused)
    }

    // MARK: overview

    private var overview: some View {
        let all = controller.tasks
        let done = all.filter(\.completed).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(done)/\(all.count) selesai")
                    .font(.system(size: 12).monospacedDigit()).foregroundColor(Palette.secondary)
                    .accessibilityLabel("\(done) dari \(all.count) tugas selesai")
                Spacer(minLength: 8)
                Button {
                    controller.actionError = nil
                    composeNew = true
                } label: { Label("Tambah", systemImage: "plus") }
                    .buttonStyle(ShellControlStyle(kind: .fill(Palette.green)))
                    .help("Tambah tugas baru")
            }
            if let error { errorRow(error) }

            if all.isEmpty {
                Text("Belum ada tugas. Tambah tugas pertama untuk melihatnya di sini.")
                    .font(.system(size: 12)).foregroundColor(Palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(all) { row($0) }
                    }
                }
            }
        }
    }

    private func row(_ t: TaskEntry) -> some View {
        let overdue = !t.completed && (t.due ?? .distantFuture) < controller.now()
        return HStack(spacing: 8) {
            Button { controller.toggle(t.id) } label: {
                Image(systemName: t.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15)).foregroundColor(t.completed ? Palette.green : Palette.secondary)
            }
            .buttonStyle(ShellControlStyle(kind: .icon(22)))
            .help(t.completed ? "Tandai belum selesai" : "Tandai selesai")
            .accessibilityLabel(t.completed ? "Tandai \(t.text) belum selesai" : "Tandai \(t.text) selesai")

            VStack(alignment: .leading, spacing: 1) {
                Text(t.text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    .strikethrough(t.completed).foregroundColor(t.completed ? Palette.secondary : .white)
                    .help(t.text)
                if let due = t.due {
                    Text(overdue ? "Lewat · " + Self.dueText(due) : Self.dueText(due))
                        .font(.system(size: 11).monospacedDigit()).foregroundColor(Palette.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { composeNew = false; controller.beginEdit(t) } label: { Image(systemName: "pencil").font(.system(size: 12)) }
                .buttonStyle(ShellControlStyle(kind: .icon(22))).foregroundColor(Palette.secondary)
                .help("Ubah").accessibilityLabel("Ubah \(t.text)")
            Button { controller.delete(t.id) } label: { Image(systemName: "trash").font(.system(size: 12)) }
                .buttonStyle(ShellControlStyle(kind: .icon(22))).foregroundColor(Palette.secondary)
                .help("Hapus").accessibilityLabel("Hapus \(t.text)")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    // MARK: composer

    private var composer: some View {
        ViewThatFits(in: .vertical) {
            composerForm
            ScrollView { composerForm }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { fieldFocused = true }
    }

    private var composerForm: some View {
        let isNew = controller.editingID == nil
        let hasDue = isNew ? $controller.draftHasDue : $controller.editHasDue
        return VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "Tugas baru" : "Ubah tugas").font(.system(size: 13, weight: .semibold))
            TextField("Nama tugas", text: isNew ? $controller.draftText : $controller.editText)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.control))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(fieldFocused ? 1 : 0.25), lineWidth: fieldFocused ? 2 : 1))
                .focused($fieldFocused)
                .onSubmit(save)
                .accessibilityLabel(isNew ? "Nama tugas baru" : "Ubah teks tugas")
            HStack(spacing: 8) {
                Toggle("Tenggat", isOn: hasDue).toggleStyle(.checkbox)
                    .accessibilityLabel("Pakai tenggat dan pengingat")
                if hasDue.wrappedValue {
                    DatePicker("", selection: isNew ? $controller.draftDue : $controller.editDue,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.field)
                        .accessibilityLabel("Tenggat tugas")
                }
                Spacer(minLength: 0)
            }
            if let error { errorRow(error) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Batal", action: cancel)
                    .buttonStyle(ShellControlStyle(kind: .quiet))
                    .help("Tutup tanpa menyimpan (Esc)")
                Button("Simpan", action: save)
                    .buttonStyle(ShellControlStyle(kind: .fill(Palette.green)))
                    .help(isNew ? "Simpan tugas baru" : "Simpan perubahan")
            }
            .padding(.top, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The editor closes only after the controller reports the write succeeded.
    private func save() {
        if controller.editingID == nil {
            if controller.submitDraft() { composeNew = false }
        } else {
            controller.commitEdit()
        }
    }

    private func cancel() {
        composeNew = false
        controller.cancelEdit()
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(text).font(.system(size: 11)).lineLimit(2).help(text)
            if controller.actionError != nil {
                Button("Tutup") { controller.actionError = nil }
                    .buttonStyle(ShellControlStyle(kind: .plain)).font(.system(size: 11, weight: .semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func dueText(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}
