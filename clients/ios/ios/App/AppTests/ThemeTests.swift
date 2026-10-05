import XCTest
@testable import App

final class ThemeTests: XCTestCase {
    func testEveryColourSlotHasANamedAsset() {
        for slot in SuiteColor.allCases {
            XCTAssertNotNil(UIColor(named: slot.rawValue, in: Bundle(for: SuiteBridgeViewController.self), compatibleWith: nil),
                            "missing colour asset \(slot.rawValue)")
        }
    }

    func testPublicSansIsBundled() {
        XCTAssertTrue(UIFont.familyNames.contains("Public Sans"))
    }
}
