import XCTest

final class CompletionUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }
    private func save(_ thought: String) {
        app.buttons["newIdea"].tap()
        let field = app.textViews["thoughtInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(thought)
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons["newIdea"].waitForExistence(timeout: 5))
    }
    private func searchForUnmatchedText() {
        app.buttons["searchIdeas"].tap()
        app.textFields["searchField"].tap()
        app.textFields["searchField"].typeText("impossible match qzx")
        XCTAssertTrue(app.staticTexts["No matching ideas"].waitForExistence(timeout: 5))
    }
    func testClosingSearchRevealsSavedIdeas() {
        save("Visible after closing search")
        searchForUnmatchedText()
        app.buttons["searchIdeas"].tap()
        XCTAssertFalse(app.textFields["searchField"].exists)
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
    }
    func testNewSaveRevealsRecordOutsidePreviousSearch() {
        save("First idea")
        searchForUnmatchedText()
        save("Second idea outside the old filter")
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No matching ideas"].exists)
        app.buttons.matching(identifier: "noteRow").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Second idea outside the old filter"].waitForExistence(timeout: 5))
    }
    func testNewSaveReturnsScrolledLibraryToNewestRecord() {
        for index in 1...8 {
            save("Older idea \(index). A detailed thought that fills several lines in the library so the list extends well beyond the first screen.")
        }
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertFalse(app.buttons["searchIdeas"].isHittable, "The library must actually be scrolled before saving.")
        let thought = "Newest idea visible immediately after saving"
        save(thought)
        let newText = app.staticTexts[thought]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: newText)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["searchIdeas"].isHittable)
    }
    func testSetupProgressRequiresSavingThenReopeningTheSameIdea() {
        save("A manual capture used to check setup progress")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Saved once · Reopen that idea in the library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saved and reopened once on this iPhone"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(identifier: "noteRow").firstMatch.tap()
        XCTAssertTrue(app.buttons["editIdea"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Saved and reopened once on this iPhone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add, bind a trigger, then save and reopen one capture"].exists)
        XCTAssertTrue(app.staticTexts["Add when needed, then save and reopen one shared capture"].exists)
    }
}
