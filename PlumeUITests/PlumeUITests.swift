//
//  PlumeUITests.swift
//  PlumeUITests
//
//  Created by Ryan Moelter on 8/31/26.
//

import XCTest

final class PlumeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// UI tests run out-of-process, so they can't import `Plume` to read
    /// `AccessibilityID` — these mirror its strings by hand.
    private enum AccessibilityID {
        static let newTaskButton = "new-task-button"
        static let composerField = "composer-field"
    }

    /// The sidebar's "New Task" affordance should be findable by identifier
    /// with no seeded state at all.
    @MainActor
    func testNewTaskButtonIsAccessible() throws {
        let app = XCUIApplication()
        app.launch()

        let newTaskButton = app.buttons[AccessibilityID.newTaskButton].firstMatch
        XCTAssertTrue(newTaskButton.waitForExistence(timeout: 10))
    }

    /// `PLUME_SEED_TASKS=1` seeds a task with a default agent tab, so the
    /// composer should be on screen and queryable by identifier.
    @MainActor
    func testComposerFieldIsAccessibleWithSeededTask() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PLUME_SEED_TASKS"] = "1"
        app.launch()

        let composerField = app.descendants(matching: .any)[AccessibilityID.composerField].firstMatch
        XCTAssertTrue(composerField.waitForExistence(timeout: 10))
    }
}
