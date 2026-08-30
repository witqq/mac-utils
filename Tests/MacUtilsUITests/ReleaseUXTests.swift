import Foundation
import XCTest

@MainActor
final class ReleaseUXTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnglishAndRussianOnboardingExposeAccessibleGuidance() throws {
        let configurationURL = makeConfigurationURL()
        defer { try? FileManager.default.removeItem(at: configurationURL) }
        try writeEmptyConfiguration(to: configurationURL)
        var app = launch(language: "english", onboarding: true, configurationURL: configurationURL)
        XCTAssertTrue(app.staticTexts["Welcome to Mac Utils"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Build visually"].exists)
        XCTAssertTrue(app.staticTexts["Run from anywhere"].exists)
        XCTAssertTrue(app.buttons["Get Started"].isEnabled)
        app.terminate()

        app = launch(language: "russian", onboarding: true, configurationURL: configurationURL)
        XCTAssertTrue(app.staticTexts["Добро пожаловать в Mac Utils"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Собирайте мышкой"].exists)
        XCTAssertTrue(app.staticTexts["Запускайте откуда угодно"].exists)
        XCTAssertTrue(app.buttons["Начать"].isEnabled)
    }

    func testHelpAndEmptyStatesTeachTheVisualWorkflowWithoutDSL() throws {
        let configurationURL = makeConfigurationURL()
        defer { try? FileManager.default.removeItem(at: configurationURL) }
        try writeEmptyConfiguration(to: configurationURL)
        let app = launch(language: "english", onboarding: false, configurationURL: configurationURL)
        XCTAssertTrue(app.staticTexts["No scripts yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New script"].exists)

        app.radioButtons["Help"].click()
        XCTAssertTrue(app.staticTexts["How Mac Utils works"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Switch between mirror and extended mode"].exists)
        XCTAssertTrue(app.staticTexts["Toggle by State: reads the current state and chooses Then when it matches, or Otherwise when it does not."].exists)

        app.radioButtons["Shortcuts"].click()
        XCTAssertTrue(app.staticTexts["Create a script first"].waitForExistence(timeout: 3))
    }

    func testConflictingHotkeyEditKeepsTheOldAssignment() throws {
        let configurationURL = makeConfigurationURL()
        defer { try? FileManager.default.removeItem(at: configurationURL) }
        try writeConfigurationWithTwoBindings(to: configurationURL)
        let app = launch(language: "english", onboarding: false, configurationURL: configurationURL)
        app.radioButtons["Shortcuts"].click()
        XCTAssertTrue(app.staticTexts["⌥⌘K"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["⌥⌘E"].exists)

        let editButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Edit"))
        XCTAssertEqual(editButtons.count, 2)
        editButtons.element(boundBy: 0).click()
        let recorder = app.buttons["shortcut-recorder"]
        recorder.click()
        recorder.typeKey("e", modifierFlags: [.command, .option])
        app.buttons["Save Change"].click()

        let conflictError = app.staticTexts["shortcut-error"]
        XCTAssertTrue(conflictError.waitForExistence(timeout: 3))
        XCTAssertEqual(
            conflictError.value as? String,
            "That global shortcut is already assigned. The previous shortcut is still active."
        )
        XCTAssertTrue(app.staticTexts["⌥⌘K"].exists)
        XCTAssertTrue(app.staticTexts["⌥⌘E"].exists)
    }

    private func launch(language: String, onboarding: Bool, configurationURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--open-settings",
            onboarding ? "--show-onboarding" : "--skip-onboarding",
            "--ui-language", language,
            "--configuration-file", configurationURL.path,
        ]
        app.launch()
        return app
    }

    private func makeConfigurationURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mac-utils-ui-\(UUID().uuidString).json")
    }

    private func writeEmptyConfiguration(to url: URL) throws {
        try writeJSON(["schemaVersion": 1, "scripts": [], "bindings": []], to: url)
    }

    private func writeConfigurationWithTwoBindings(to url: URL) throws {
        let scriptID = "11111111-1111-4111-8111-111111111111"
        try writeJSON([
            "schemaVersion": 1,
            "scripts": [[
                "id": scriptID,
                "name": "Display toggle",
                "source": "set-main-display display=\"test-display\"",
            ]],
            "bindings": [
                [
                    "id": "22222222-2222-4222-8222-222222222222",
                    "scriptID": scriptID,
                    "shortcut": ["keyCode": 40, "modifiers": 3],
                ],
                [
                    "id": "33333333-3333-4333-8333-333333333333",
                    "scriptID": scriptID,
                    "shortcut": ["keyCode": 14, "modifiers": 3],
                ],
            ],
        ], to: url)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
