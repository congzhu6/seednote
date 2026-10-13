import SwiftUI
import UIKit

/// Picks the string for the localization the system resolved for this app (en or zh-Hans),
/// matching InfoPlist.strings permission prompts and the per-app language in iPhone Settings.
func L(_ english: String, _ chinese: String) -> String {
    Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? chinese : english
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

/// A short confirmation at the top of the screen that clears itself, such as
/// "Idea saved" or "New material is waiting in your drafts" (PRD 6.1).
struct NoticeBanner: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line))
                    .padding(.top, 8).padding(.horizontal, 24)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("noticeBanner")
                    .task(id: message) {
                        AccessibilityNotification.Announcement(message).post()
                        try? await Task.sleep(for: .seconds(3))
                        if self.message == message { self.message = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: message)
    }
}

extension View {
    func noticeBanner(_ message: Binding<String?>) -> some View { modifier(NoticeBanner(message: message)) }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

extension TimeInterval {
    var clockText: String { String(format: "%02d:%02d", max(0, Int(self)) / 60, max(0, Int(self)) % 60) }
}

/// Same rule the store enforces on save, so a link accepted here is never rejected later.
func validWebURL(_ string: String) -> URL? {
    WebLink.url(from: string.trimmingCharacters(in: .whitespacesAndNewlines))
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}
