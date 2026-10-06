import AppIntents
import SwiftUI
import WidgetKit

// Control Center, Lock Screen and Action button controls (iOS 18; canvas
// 01a10db8 "Controls"). Both are buttons, no toggles, and take the system
// tint: no brand colour.

@available(iOS 18, *)
struct WhatsWaitingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kobo-ai.burrow.controls.waiting", provider: WaitingControlProvider()) { copy in
            ControlWidgetButton(action: OpenWaitingIntent()) {
                Label {
                    Text(copy.label)
                    Text(copy.value)
                } icon: {
                    Image(systemName: copy.symbol)
                }
            }
        }
        .displayName("What's waiting")
        .description("Opens what is waiting for your approval.")
    }
}

@available(iOS 18, *)
struct StartMeetingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kobo-ai.burrow.controls.start-meeting", provider: MeetingControlProvider()) { copy in
            ControlWidgetButton(action: StartMeetingIntent()) {
                Label {
                    Text(copy.label)
                    Text(copy.value)
                } icon: {
                    Image(systemName: copy.symbol)
                }
            }
        }
        .displayName("Start meeting")
        .description("Starts a meeting in the last space you used.")
    }
}

/// The selected install's approvals count: the approvals widget's list or
/// the counts widgets' number, whichever this device fetched last.
@available(iOS 18, *)
struct WaitingControlProvider: ControlValueProvider {
    var previewValue: ControlCopy { .waiting(signedIn: true, approvals: 3, install: nil) }

    func currentValue() async throws -> ControlCopy {
        let installs = InstallStore.shared
        guard let host = installs.selectedHost else { return .waiting(signedIn: false, approvals: nil, install: nil) }
        let listed = ApprovalsCache().approvals(for: host)
        let counted = CountsCache().counts(for: host)
        let approvals: Int?
        switch (listed, counted) {
        case (let list?, let counts?): approvals = list.fetchedAt >= counts.fetchedAt ? list.approvals.count : counts.approvals
        case (let list?, nil): approvals = list.approvals.count
        case (nil, let counts?): approvals = counts.approvals
        case (nil, nil): approvals = nil
        }
        return .waiting(signedIn: SuiteAPIClient.shared.isSignedIn(host: host), approvals: approvals, install: installName(host, installs))
    }
}

@available(iOS 18, *)
struct MeetingControlProvider: ControlValueProvider {
    var previewValue: ControlCopy { .startMeeting(lastSpace: nil, install: nil) }

    func currentValue() async throws -> ControlCopy {
        let installs = InstallStore.shared
        guard let host = installs.selectedHost else { return .startMeeting(lastSpace: nil, install: nil) }
        return .startMeeting(lastSpace: LastMeetingSpaceStore().spaceName(for: host), install: installName(host, installs))
    }
}

/// The install name, only when more than one install is saved.
private func installName(_ host: String, _ installs: InstallStore) -> String? {
    installs.installs.count > 1 ? installs.installs.first { $0.host == host }?.displayName : nil
}
