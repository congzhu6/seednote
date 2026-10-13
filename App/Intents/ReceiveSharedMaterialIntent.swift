import AppIntents
import Foundation

/// A Shortcuts action for a share-sheet shortcut that routes its input into
/// the main app, where the editor and microphone UI are available.
struct ReceiveSharedMaterialIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Shared Material in Seednote"
    static var description = IntentDescription("Open a Seednote draft with an image, web link, or selected text from Shortcuts.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Image") var image: IntentFile?
    @Parameter(title: "Link") var link: URL?
    @Parameter(title: "Selected Text") var selectedText: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Record shared material in Seednote") {
            \.$image
            \.$link
            \.$selectedText
        }
    }

    func perform() async throws -> some IntentResult {
        let trace = PerfTrace.begin("Capture", "Shared material → editor")
        let imageData = image?.data
        let url = link?.absoluteString

        guard imageData != nil || url != nil || selectedText != nil else {
            PerfTrace.end(trace, outcome: "no input")
            throw SeednoteShortcutError.noInput
        }

        try await AppModel.shared.receive(
            imageData: imageData,
            sourceURL: url,
            sourceText: selectedText,
            origin: CaptureSetupOrigin.shareShortcut.rawValue,
            trace: trace
        )
        return .result()
    }
}

private enum SeednoteShortcutError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput:
            return L("No image, link, or text was shared with Seednote.", "没有收到分享的图片、链接或文字。")
        }
    }
}
