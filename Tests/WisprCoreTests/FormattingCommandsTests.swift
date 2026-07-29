import XCTest
@testable import WisprCore

final class FormattingCommandsTests: XCTestCase {
    func testNewParagraph() {
        XCTAssertEqual(FormattingCommands.apply("hello new paragraph world"), "hello\n\nWorld")
    }

    func testNewParagraphWithSurroundingCommas() {
        XCTAssertEqual(FormattingCommands.apply("hello, new paragraph, world"), "hello\n\nWorld")
    }

    func testNewLine() {
        XCTAssertEqual(FormattingCommands.apply("hello new line world"), "hello\nworld")
    }

    func testFrenchNewParagraph() {
        XCTAssertEqual(FormattingCommands.apply("Bonjour nouveau paragraphe monde"), "Bonjour\n\nMonde")
    }

    func testFrenchALaLigne() {
        XCTAssertEqual(FormattingCommands.apply("un à la ligne deux"), "un\ndeux")
    }

    func testFrenchNouvelleLigne() {
        XCTAssertEqual(FormattingCommands.apply("une nouvelle ligne deux"), "une\ndeux")
    }

    func testCommandOnlyIsCaseInsensitive() {
        XCTAssertEqual(FormattingCommands.apply("New Paragraph"), "\n\n")
    }

    func testNoCommandsUnchanged() {
        XCTAssertEqual(FormattingCommands.apply("no commands here"), "no commands here")
    }

    func testEmptyInput() {
        XCTAssertEqual(FormattingCommands.apply(""), "")
    }

    // "newline" (one word) must not be split into "new" + "line".
    func testNewlineOneWordDoesNotMatch() {
        XCTAssertEqual(FormattingCommands.apply("the newline character"), "the newline character")
    }

    // "Newfoundland" must not partially match "new" + "line" fragments.
    func testNewfoundlandDoesNotMatch() {
        XCTAssertEqual(FormattingCommands.apply("visit Newfoundland line by line"), "visit Newfoundland line by line")
    }

    func testDetectBulletListEnglishTrailing() {
        let result = DirectiveDetector.detect("buy milk and eggs make this a bullet list")
        XCTAssertEqual(result?.directive, .bulletList)
        XCTAssertEqual(result?.content, "buy milk and eggs")
    }

    func testDetectBulletListWithPunctuation() {
        let result = DirectiveDetector.detect("buy milk, make it a bullet list.")
        XCTAssertEqual(result?.directive, .bulletList)
        XCTAssertEqual(result?.content, "buy milk")
    }

    func testDetectBulletListFrench() {
        let result = DirectiveDetector.detect("les courses fais une liste à puces")
        XCTAssertEqual(result?.directive, .bulletList)
        XCTAssertEqual(result?.content, "les courses")
    }

    func testDetectEmailEnglish() {
        let result = DirectiveDetector.detect("meeting friday draft this as an email")
        XCTAssertEqual(result?.directive, .email)
        XCTAssertEqual(result?.content, "meeting friday")
    }

    func testDetectEmailFrench() {
        let result = DirectiveDetector.detect("réunion vendredi rédige un e-mail")
        XCTAssertEqual(result?.directive, .email)
        XCTAssertEqual(result?.content, "réunion vendredi")
    }

    func testDetectNilWhenNoContentLeft() {
        XCTAssertNil(DirectiveDetector.detect("make this a bullet list"))
    }

    func testDetectNilWithPlainText() {
        XCTAssertNil(DirectiveDetector.detect("plain text"))
    }

    func testDetectRequiresWordBoundaryBeforePhrase() {
        XCTAssertNil(DirectiveDetector.detect("premake this a bullet list"))
    }
}
