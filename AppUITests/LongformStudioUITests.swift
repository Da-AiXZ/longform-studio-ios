import XCTest

final class LongformStudioUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
    }

    func testEmptyLibraryAndCreateProjectFlow() throws {
        XCTAssertTrue(app.staticTexts["还没有作品"].waitForExistence(timeout: 5))
        attachScreenshot(named: "01-empty-library")

        app.buttons["create-first-project"].tap()
        let title = app.textFields["new-project-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Test Novel")
        app.buttons["new-project-next"].tap()

        let sellingPoint = app.textFields["一句话核心卖点"]
        XCTAssertTrue(sellingPoint.waitForExistence(timeout: 3))
        sellingPoint.tap()
        sellingPoint.typeText("Every failure reveals a clue")
        let goal = app.textFields["主角长期目标"]
        goal.tap()
        goal.typeText("Find the cause of the disaster")
        app.buttons["new-project-next"].tap()

        attachScreenshot(named: "02-project-confirmation")
        app.buttons["new-project-next"].tap()
        XCTAssertTrue(app.navigationBars["Test Novel"].waitForExistence(timeout: 8))
        attachScreenshot(named: "03-writing-workspace")

        XCTAssertTrue(app.staticTexts["先创建第一章"].exists)
        app.buttons["添加章节"].tap()
        XCTAssertTrue(app.textViews["chapter-editor"].waitForExistence(timeout: 3))
        attachScreenshot(named: "04-chapter-editor")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
