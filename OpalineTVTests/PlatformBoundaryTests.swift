import XCTest
@testable import OpalineTV

final class PlatformBoundaryTests: XCTestCase {
    func testTVStringsUseTheirOwnTableAndUpstreamStringsStillResolve() {
        let previous = AppLanguage.override
        defer { AppLanguage.override = previous }
        AppLanguage.override = .english
        XCTAssertEqual("TV.cancel".tvLocalized, "Cancel")
        XCTAssertEqual("TV.skipSegment".tvLocalized(with: "Sponsor"), "Skip Sponsor")
        XCTAssertNotEqual("account.signIn".localized, "account.signIn")
        // This key must stay out of the stock upstream table.
        XCTAssertEqual("TV.cancel".localized, "TV.cancel")
    }

}
