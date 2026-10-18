import XCTest
@testable import App

/// iOS kills the app (TCC SIGABRT, "attempted to access privacy-sensitive data
/// without a usage description") the moment it asks for a capture device whose
/// usage key is missing from Info.plist. The web view asks too: a meeting page's
/// getUserMedia reaches TCC on behalf of the app. v1.1 (3) had no microphone key
/// and crashed on joining a meeting.
final class PrivacyUsageDescriptionTests: XCTestCase {
    private let info = Bundle(for: BurrowBridgeViewController.self).infoDictionary ?? [:]

    func testEveryCaptureTheWebViewCanRequestHasAUsageDescription() {
        // Meetings (LiveKit in the web view) use the microphone and the camera;
        // the chat composer uses the camera and the photo library.
        for key in ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSPhotoLibraryUsageDescription"] {
            let text = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            XCTAssertFalse(text.isEmpty, "Info.plist has no \(key); iOS terminates the app when that capture is requested")
        }
    }
}
