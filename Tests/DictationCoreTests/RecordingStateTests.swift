@main
struct RecordingStateTests {
    static func main() {
        let checks = RecordingStateTests()
        checks.testHoldFinishesExactlyOnce()
        checks.testToggleIgnoresHoldAndKeyUp()
        checks.testCancelResetsRecordingAndTranscription()
        checks.testExplicitStopHandlesBothRecordingModes()
        checks.testShortcutValidationRejectsCollisionsAndPlainTyping()
        checks.testInputLanguageUsesOnlyTheActiveSourcesPrimaryLanguage()
        checks.testCarbonModifiersKeepStoredShortcutMeaning()
        print("7 dictation core checks passed.")
    }

    private func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) { precondition(left == right) }
    private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
    private func XCTAssertTrue(_ value: Bool) { precondition(value) }
    private func XCTAssertFalse(_ value: Bool) { precondition(!value) }
    func testHoldFinishesExactlyOnce() {
        var state = RecordingState()
        XCTAssertEqual(state.press(.hold), .start)
        XCTAssertNil(state.press(.hold))
        XCTAssertNil(state.press(.toggle))
        XCTAssertNil(state.release(.toggle))
        XCTAssertEqual(state.release(.hold), .finish)
        XCTAssertNil(state.release(.hold))
        XCTAssertNil(state.press(.toggle))
        XCTAssertEqual(state.phase, .transcribing)
        state.complete()
        XCTAssertEqual(state.phase, .idle)
    }

    func testToggleIgnoresHoldAndKeyUp() {
        var state = RecordingState()
        XCTAssertEqual(state.press(.toggle), .start)
        XCTAssertNil(state.release(.toggle))
        XCTAssertNil(state.press(.hold))
        XCTAssertNil(state.release(.hold))
        XCTAssertEqual(state.phase, .recording(.toggle))
        XCTAssertEqual(state.press(.toggle), .finish)
        XCTAssertNil(state.press(.toggle))
    }

    func testCancelResetsRecordingAndTranscription() {
        var state = RecordingState()
        XCTAssertNil(state.cancel())
        _ = state.press(.hold)
        XCTAssertEqual(state.cancel(), .cancel)
        XCTAssertEqual(state.phase, .idle)
        _ = state.press(.toggle)
        _ = state.press(.toggle)
        XCTAssertEqual(state.cancel(), .cancel)
        XCTAssertEqual(state.press(.hold), .start)
    }

    func testExplicitStopHandlesBothRecordingModes() {
        for mode in [RecordingMode.hold, .toggle] {
            var state = RecordingState()
            XCTAssertNil(state.finish())
            _ = state.press(mode)
            XCTAssertEqual(state.finish(), .finish)
            XCTAssertNil(state.finish())
            XCTAssertEqual(state.phase, .transcribing)
        }
    }

    func testShortcutValidationRejectsCollisionsAndPlainTyping() {
        XCTAssertTrue(ShortcutPair().isValid)
        XCTAssertFalse(ShortcutPair(hold: .hold, toggle: .hold).isValid)
        XCTAssertFalse(Shortcut(keyCode: 49, modifiers: 0).isValid)
        XCTAssertFalse(Shortcut(keyCode: 58, modifiers: 1 << 18).isValid)
        XCTAssertFalse(Shortcut(keyCode: 200, modifiers: 1 << 18).isValid)
        XCTAssertFalse(Shortcut(keyCode: 49, modifiers: 1 << 16).isValid)
    }

    func testInputLanguageUsesOnlyTheActiveSourcesPrimaryLanguage() {
        XCTAssertEqual(DictationLanguage.inputSource.resolved(inputLanguages: ["ru-RU"]), "ru")
        XCTAssertEqual(DictationLanguage.inputSource.resolved(inputLanguages: ["en-US"]), "en")
        XCTAssertNil(DictationLanguage.inputSource.resolved(inputLanguages: ["de", "en"]))
        XCTAssertNil(DictationLanguage.inputSource.resolved(inputLanguages: []))
        XCTAssertNil(DictationLanguage.mixed.resolved(inputLanguages: ["ru"]))
        XCTAssertEqual(DictationLanguage.english.resolved(inputLanguages: ["ru"]), "en")
    }

    func testCarbonModifiersKeepStoredShortcutMeaning() {
        XCTAssertEqual(Shortcut.hold.carbonModifiers, 0x1000)
        XCTAssertEqual(Shortcut.toggle.carbonModifiers, 0x1800)
        XCTAssertEqual(Shortcut(keyCode: 49, modifiers: (1 << 17) | (1 << 20)).carbonModifiers, 0x0300)
        XCTAssertEqual(Shortcut(keyCode: 49, modifiers: Shortcut.modifierMask).carbonModifiers, 0x1B00)
        XCTAssertEqual(Shortcut(keyCode: 53, modifiers: 0).carbonModifiers, 0)
    }
}
