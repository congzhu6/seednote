import AppIntents
import Foundation

/// The second action in the user-installed screenshot shortcut. The first
/// action must be Shortcuts' system "Take Screenshot" action; App Intents
/// cannot capture another app's screen themselves.
struct CaptureScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Screenshot in Seednote"
    static var description = IntentDescription("Open a Seednote draft with the screenshot passed from Shortcuts.")

    // iOS 18 compatibility. The iOS 26 replacement, supportedModes, is not
    // available on the app's minimum deployment target.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Screenshot", description: "The output of Take Screenshot")
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Record \(\.$screenshot) in Seednote")
    }

    func perform() async throws -> some IntentResult {
        let trace = PerfTrace.begin("Capture", "Screenshot capture → editor")
        let data = screenshot.data
        try await AppModel.shared.receive(
            imageData: data,
            sourceURL: nil,
            sourceText: nil,
            origin: "shortcutScreenshot",
            trace: trace
        )
        return .result()
    }
}
