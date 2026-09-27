import SwiftUI

enum LabTheme {
    static let cyan = Color(red: 0.25, green: 0.90, blue: 0.86)
    static let blue = Color(red: 0.30, green: 0.55, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.64, blue: 0.25)
    static let panel = Color.white.opacity(0.055)
    static let border = Color.white.opacity(0.10)
}

struct LabCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(LabTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(LabTheme.border, lineWidth: 1))
    }
}

struct MetricView: View {
    let label: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced, weight: .semibold)).foregroundStyle(color).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusPill: View {
    let text: String
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(active ? LabTheme.cyan : Color.secondary).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }.padding(.horizontal, 10).padding(.vertical, 6)
            .background((active ? LabTheme.cyan : .secondary).opacity(0.12), in: Capsule())
    }
}

struct EmptyChart: View {
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").font(.title).foregroundStyle(.tertiary)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 170)
    }
}
