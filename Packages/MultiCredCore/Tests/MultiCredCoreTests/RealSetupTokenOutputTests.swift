import XCTest
@testable import MultiCredCore

/// Bytes captured from the real `claude setup-token` 2.1.296 (fake code).
final class RealSetupTokenOutputTests: XCTestCase {
    private let prompt = Array("\u{1B}]8;;\u{07}\r\r\n\r\r\n\r\r\n\u{1B}[2GPaste\u{1B}[8Gcode\u{1B}[13Ghere\u{1B}[18Gif\u{1B}[21Gprompted\u{1B}[30G>\r\r\n".utf8)
    private let error = Array("\u{1B}(B\u{0F}\u{1B}[?2004h\r\u{1B}[31C\u{1B}[1A******************ate456\r\r\n\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[G\u{1B}[1A\r\u{1B}[1C\u{1B}[4A\u{1B}[38;5;211mOAuth error: Request failed with status code 400\u{1B}[39m\u{1B}[K\r\u{1B}[2B\u{1B}[K\r\u{1B}[1C\u{1B}[1B\u{1B}[38;5;153mPress \u{1B}[1mEnter\u{1B}[22m to retry. \r\u{1B}[1B\u{1B}[39m\u{1B}[K\r\u{1B}[1B\u{1B}[K\r\u{1B}[1A".utf8)

    func testInkCursorMovesBecomeSpacesAndPromptIsSeen() {
        var parser = SetupTokenParser()
        XCTAssertEqual(parser.consume(prompt), [.promptingForCode])
        XCTAssertTrue(parser.maskedTranscript.contains("Paste code here if prompted >"), parser.maskedTranscript)
    }

    func testOAuthErrorIsAFailure() {
        var parser = SetupTokenParser()
        _ = parser.consume(prompt)
        XCTAssertEqual(parser.consume(error), [.failed("OAuth error: Request failed with status code 400")])
    }

    func testAuthorizationCodeShape() {
        XCTAssertTrue(AuthorizationCode.looksLikeCode(" abcdefghijklmnopqrstuvwxyz012345#ABCDEFGHIJKLMNOP\n"))
        XCTAssertFalse(AuthorizationCode.looksLikeCode("hello world"))
        XCTAssertFalse(AuthorizationCode.looksLikeCode("https://claude.com/x#abcdefghijklmnop"))
        XCTAssertFalse(AuthorizationCode.looksLikeCode("abcdefghijklmnopqrstuvwxyz0123456789"), "needs #state")
    }

    func testCredentialLikeTextIsMaskedForLogs() {
        let text = "token sk-ant-oat01-abc_DEF-123 and code abcdefghijklmnopqrstuvwxyz0123456789ABCD#xyz and words"
        let masked = Redactor.redactCredentialLike(text)
        XCTAssertFalse(masked.contains("sk-ant"))
        XCTAssertFalse(masked.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        XCTAssertTrue(masked.contains("and words"))
    }
}
