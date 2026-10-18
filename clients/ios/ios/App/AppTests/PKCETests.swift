import XCTest
@testable import App

final class PKCETests: XCTestCase {
    /// RFC 7636 Appendix B known-answer vector.
    func testS256KnownAnswer() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierMatchesTheServerFormat() {
        let verifier = PKCE.makeVerifier()
        // Platform.Mobile @verifier_format: [A-Za-z0-9._~-]{43,128}
        XCTAssertNotNil(verifier.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression))
        XCTAssertNotEqual(verifier, PKCE.makeVerifier())
    }

    func testLoginURLCarriesTheChallenge() {
        let url = AuthSession.loginURL(host: "burrow.example.com", challenge: "abc")
        XCTAssertEqual(url.absoluteString, "https://burrow.example.com/auth/login?app_challenge=abc")
    }
}
