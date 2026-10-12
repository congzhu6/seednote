import XCTest

/// Local file delivery only. Does not run Safari or change physical trigger bindings.
final class ShortcutHandoffTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func checkHandoff(title: String, identifier: String) {
        app.buttons["Settings"].tap()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.tap()
        let open = app.buttons[identifier]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let handler = app.cells.matching(NSPredicate(format: "label == 'Shortcuts' OR label == 'Copy to Shortcuts' OR label == '快捷指令'")).firstMatch
        if !handler.waitForExistence(timeout: 8) {
            print("SHORTCUT_HANDOFF_INTERFACE=\(app.debugDescription)")
        }
        XCTAssertTrue(handler.exists, "The system should offer Shortcuts for this signed local file.")
        handler.tap()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        XCTAssertTrue(shortcuts.wait(for: .runningForeground, timeout: 10))
        let add = shortcuts.buttons.matching(NSPredicate(format: "label == 'Add Shortcut' OR label == '添加快捷指令'")).firstMatch
        if !add.waitForExistence(timeout: 10) { print("SHORTCUT_IMPORT_INTERFACE=\(shortcuts.debugDescription)") }
        XCTAssertTrue(add.exists, "Apple's import preview must accept the bundled signed document.")
        let screenshot = XCTAttachment(screenshot: shortcuts.screenshot())
        screenshot.name = "Apple import preview - \(identifier)"
        screenshot.lifetime = .keepAlways
        self.add(screenshot)
        // Existing installed copies and trigger bindings stay in place; preview proves this handoff.
        app.activate()
    }

    func testScreenshotFileReachesAppleImportPreview() {
        checkHandoff(title: "Screenshot to Seednote", identifier: "openScreenshotShortcut")
    }

    func testShareFileReachesAppleImportPreview() {
        checkHandoff(title: "Share to Seednote", identifier: "openShareShortcut")
    }
}
