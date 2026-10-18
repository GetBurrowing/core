import Foundation

/// Where an intent that joins a meeting sends the person (task 01a10db7
/// stage 3).
///
/// The app installs `start` (IntentAppHooks.install), which begins a NATIVE
/// call through CallKit and LiveKit. The widget extension compiles this file
/// too and installs nothing, so there the intent keeps opening the meeting's
/// web page, exactly as before. This file must never import LiveKit: it is
/// compiled into BurrowWidgets.
enum MeetingLauncher {
    enum Route: Equatable {
        case native
        case web(DeepLink)
    }

    /// `(host, meetingID)`. Nil outside the app process.
    static var start: ((_ host: String, _ meetingID: String) -> Void)?

    /// Joins `meetingID` on `host`: natively when a launcher is installed,
    /// else by opening `fallback` (the meeting's web page).
    @discardableResult
    static func open(host: String, meetingID: String, fallback: DeepLink, installs: InstallStore = .shared) -> Route {
        guard let start else {
            IntentNavigator.open(fallback, installs: installs)
            return .web(fallback)
        }
        installs.select(host)
        start(host, meetingID)
        return .native
    }
}
