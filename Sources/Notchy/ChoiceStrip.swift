import SwiftUI

struct ChoiceStrip: View {
    let options: [String]
    @Binding var selection: String
    var labels: [String: String] = [:]
    var accent = Color(red: 0x30 / 255, green: 0xd1 / 255, blue: 0x59 / 255)
    @FocusState private var focused: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { value in
                let selected = selection == value
                Button { selection = value } label: {
                    Text(labels[value] ?? value)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundColor(selected ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selected ? accent : Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused == value ? Color.white : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: value)
                .accessibilityValue(selected ? "Dipilih" : "")
                .help(labels[value] ?? value)
            }
        }
    }
}
