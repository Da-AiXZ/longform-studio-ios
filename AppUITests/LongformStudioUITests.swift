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
        XCTAssertTrue(app.navigationBars["Test Novel"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["我们从想法开始。你想写什么类型的故事？可以只说一个模糊念头，我会逐步帮你整理成设定。"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["先连接你的 AI 模型"].exists)
        XCTAssertTrue(app.textFields["agent-input"].exists)
        attachScreenshot(named: "02-agent-workspace")

        app.buttons["手动模式"].tap()
        XCTAssertTrue(app.staticTexts["先创建第一章"].exists)
        app.buttons["添加章节"].tap()
        XCTAssertTrue(app.textViews["chapter-editor"].waitForExistence(timeout: 3))
        attachScreenshot(named: "03-manual-chapter-editor")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
