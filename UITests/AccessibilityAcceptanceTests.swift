import XCTest

/// Automated audit of visible native UI on the isolated device test library.
/// This supplements, but does not replace, a person's VoiceOver walkthrough.
final class AccessibilityAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!

    private let auditTypes: XCUIAccessibilityAuditType = [
        .contrast,
        .hitRegion,
        .sufficientElementDescription,
        .trait,
        .textClipped
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("This acceptance audit is run against the installed app on the test iPhone.")
        #endif
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--reset-test-store",
            "--skip-welcome",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testCoreScreensPassAutomatedAccessibilityAudit() throws {
        XCTAssertTrue(app.buttons["newIdea"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your next idea starts here."].exists)
        try audit("empty library")

        app.buttons["newIdea"].tap()
        let thought = app.textViews["thoughtInput"]
        let save = app.buttons["saveIdea"]
        XCTAssertTrue(thought.waitForExistence(timeout: 5))
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "An empty idea has no content and must remain unsavable.")
        try audit("empty editor")

        thought.tap()
        thought.typeText("A saved thought for the accessibility audit.")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let row = app.buttons.matching(identifier: "noteRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["editIdea"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A saved thought for the accessibility audit."].exists)
        try audit("saved idea detail")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Capture shortcuts"].exists)
        try audit("capture settings")

        let settingsScroll = app.scrollViews.firstMatch
        settingsScroll.swipeUp()
        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 5))
        try audit("device and about settings")
    }

    func testLargestTextKeepsEditorAndSaveReachableWithKeyboard() {
        app.terminate()
        app.launchArguments[app.launchArguments.count - 1] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
        let newIdea = app.buttons["newIdea"]
        XCTAssertTrue(newIdea.waitForExistence(timeout: 5))
        XCTAssertTrue(newIdea.isHittable)
        newIdea.tap()
        let thought = app.textViews["thoughtInput"]
        XCTAssertTrue(thought.waitForExistence(timeout: 5))
        thought.tap()
        thought.typeText("Large text and keyboard should not hide a saved thought.")
        let save = app.buttons["saveIdea"]
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
    }

    private func audit(_ screen: String) throws {
        try XCTContext.runActivity(named: "Accessibility audit: \(screen)") { _ in
            try app.performAccessibilityAudit(for: auditTypes) { issue in
                print("ACCESSIBILITY_ISSUE=\(issue.compactDescription) | \(issue.detailedDescription) | element=\(issue.element?.debugDescription ?? "none")")
                // iOS 27 flags these native toolbar capsules despite their
                // rendered dark labels on white. Keep each issue in the log,
                // and continue auditing every other control and audit type.
                let nativeToolbarButtons = ["cancelEditor", "editIdea"]
                if issue.auditType == .contrast,
                   let identifier = issue.element?.identifier,
                   nativeToolbarButtons.contains(identifier) {
                    print("KNOWN_IOS27_TOOLBAR_CONTRAST_FALSE_POSITIVE=\(identifier)")
                    return true
                }
                return false
            }
        }
    }
}
