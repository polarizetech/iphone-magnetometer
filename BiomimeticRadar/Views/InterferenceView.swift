import SwiftUI

/// The phone-interference catalogue, on the phone — because that is where the operator is when they
/// are deciding whether to take the MagSafe wallet off. Same data as the web viewer's panel
/// (`InterferenceRegistry`), read-only here.
struct InterferenceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(InterferenceRegistry.philosophy)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(12)
                    .background(LabTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                ForEach(InterferenceRegistry.sources) { src in
                    LabCard(src.name) {
                        HStack(spacing: 6) {
                            tag(src.character.rawValue, color: characterColor(src.character))
                            tag(src.origin.rawValue, color: .secondary)
                            tag(src.orderOfMagnitude, color: .secondary)
                        }
                        row("Effect", src.effect)
                        row("Tell", src.tell)
                        row("Do", src.mitigation)
                        if let f = src.suggestedFilter, f.kind != .none {
                            Text(
                                "Viewer filter: \(f.kind == .highPass ? "high-pass" : "notch")\(f.hz.map { String(format: " at %.2f Hz", $0) } ?? "")"
                            )
                            .font(.caption2).foregroundStyle(LabTheme.cyan)
                        }
                    }
                }
                Text(
                    "Amplitudes are order-of-magnitude, tier [C] — none measured on this phone. A clean baseline run is what turns them into numbers. See INTERFERENCE.md."
                )
                .font(.caption).foregroundStyle(.tertiary)
            }.padding()
        }
        .navigationTitle("Phone interference")
        .background(Color.black.ignoresSafeArea())
    }

    private func row(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.primary)
        }
    }
    private func tag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.5))).foregroundStyle(color)
    }
    private func characterColor(_ c: InterferenceRegistry.Character) -> Color {
        switch c {
        case .hardIronDC: LabTheme.orange
        case .currentModulated: LabTheme.cyan
        case .movingActuator, .softIron: LabTheme.blue
        }
    }
}
