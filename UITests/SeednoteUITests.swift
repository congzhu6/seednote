import XCTest

final class SeednoteUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSaveRelaunchSearchAndCancelEdit() throws {
        app.buttons["newIdea"].tap()
        let thought = app.textViews["thoughtInput"]
        XCTAssertTrue(thought.waitForExistence(timeout: 5))
        capture("Native editor - English")
        thought.tap()
        thought.typeText("An original thought about small creative habits.")
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
        capture("Native library - English")
        app.terminate()
        app.launchArguments = ["--uitesting", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons.matching(identifier: "noteRow").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["An original thought about small creative habits."].waitForExistence(timeout: 5))
        capture("Native detail - English")
        app.buttons["editIdea"].tap()
        let editing = app.textViews["thoughtInput"]
        editing.tap()
        editing.typeText(" Temporary edit.")
        app.buttons["cancelEditor"].tap()
        app.buttons.matching(identifier: "discardDraft").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["An original thought about small creative habits."].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["searchIdeas"].tap()
        app.textFields["searchField"].tap()
        app.textFields["searchField"].typeText("unmatched query")
        XCTAssertTrue(app.staticTexts["No matching ideas"].waitForExistence(timeout: 4))
    }

    func testCancelNewDoesNotCreateRecord() throws {
        app.buttons["newIdea"].tap()
        app.textViews["thoughtInput"].tap()
        app.textViews["thoughtInput"].typeText("Discard this")
        app.buttons["cancelEditor"].tap()
        app.buttons.matching(identifier: "discardDraft").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your next idea starts here."].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons.matching(identifier: "noteRow").count, 0)
    }

    func testChineseLargeTypeCaptureLayout() throws {
        app.terminate()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--skip-welcome", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["newIdea"].waitForExistence(timeout: 5))
        capture("Native empty library - Chinese large type")
        app.buttons["newIdea"].tap()
        XCTAssertTrue(app.textViews["thoughtInput"].waitForExistence(timeout: 5))
        capture("Native editor - Chinese large type")
        XCTAssertTrue(app.buttons["saveIdea"].exists)
        XCTAssertTrue(app.buttons["recordThought"].isHittable)
        XCTAssertTrue(app.textViews["thoughtInput"].isHittable)
    }

    func testExportPreparesSystemShareSheet() throws {
        app.buttons["newIdea"].tap()
        app.textViews["thoughtInput"].tap()
        app.textViews["thoughtInput"].typeText("A thought to export with its attribution.")
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["exportIdeas"].waitForExistence(timeout: 5))
        app.buttons["exportIdeas"].tap()
        // iOS 27 exposes the system preview caption as Other; earlier versions use StaticText.
        let archiveTitle = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Seednote-export-")).firstMatch
        let archiveVisible = archiveTitle.waitForExistence(timeout: 15)
        capture("Native ZIP export share sheet")
        if !archiveVisible { print("EXPORT_SHARE_INTERFACE=\(app.debugDescription)") }
        XCTAssertTrue(archiveVisible)
    }

    func testDraftRecoveryAfterTermination() throws {
        app.buttons["newIdea"].tap()
        app.textViews["thoughtInput"].tap()
        app.textViews["thoughtInput"].typeText("A recoverable thought")
        // Wait for visible, genuine draft persistence acknowledgement, not a fixed delay.
        XCTAssertTrue(app.staticTexts["Draft kept on this iPhone"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--uitesting", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["reviewDrafts"].tap()
        app.buttons["resumeDraft"].firstMatch.tap()
        XCTAssertEqual(app.textViews["thoughtInput"].value as? String, "A recoverable thought")
    }
}
