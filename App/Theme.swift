import SwiftUI
import UIKit

func L(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

enum Theme {
    static let paper = adaptive(0xFFFFFF, 0x202220)
    static let surface = adaptive(0xF4F4F1, 0x2C2F2A)
    static let ink = adaptive(0x252625, 0xF0F2EA)
    static let muted = adaptive(0x656762, 0xB2B8AB)
    static let line = adaptive(0xE2E3DF, 0x484D42)
    static let red = adaptive(0xC64031, 0xFF9F8E)
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { trait in
            let rgb = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct PillButtonStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(secondary ? Theme.ink : Theme.paper)
            .background(secondary ? Theme.surface : Theme.ink, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct IconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 20, weight: .regular)).frame(width: 44, height: 44) }
            .accessibilityLabel(title)
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View { Text(text).font(.subheadline).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading) }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

extension TimeInterval {
    var clockText: String { String(format: "%02d:%02d", max(0, Int(self)) / 60, max(0, Int(self)) % 60) }
}

func validWebURL(_ string: String) -> URL? {
    guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty else { return nil }
    return url
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}
