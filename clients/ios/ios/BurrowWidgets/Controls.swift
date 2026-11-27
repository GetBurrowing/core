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

/// The approvals waiting across every signed-in install (task 01a21e75
/// stage 3): per install, the approvals widget's list or the counts
/// widgets' number, whichever this device fetched last, summed. With
/// several installs the value line says how many it sums ("2 installs").
@available(iOS 18, *)
struct WaitingControlProvider: ControlValueProvider {
    var previewValue: ControlCopy { .waiting(signedIn: true, approvals: 3, install: nil) }

    func currentValue() async throws -> ControlCopy {
        Self.copy(installs: InstallStore.shared.installs, client: .shared, approvals: ApprovalsCache(), counts: CountsCache())
    }

    static func copy(installs: [Install], client: BurrowAPIClient, approvals: ApprovalsCache, counts: CountsCache) -> ControlCopy {
        let signedIn = installs.filter { client.isSignedIn(host: $0.host) }
        guard !signedIn.isEmpty else { return .waiting(signedIn: false, approvals: nil, install: nil) }
        let known = signedIn.compactMap { install in waiting(approvals.approvals(for: install.host), counts.counts(for: install.host)) }
        let label = signedIn.count > 1 ? InstallLabel.count(signedIn.count) : nil
        return .waiting(signedIn: true, approvals: known.isEmpty ? nil : known.reduce(0, +), install: label)
    }

    private static func waiting(_ listed: CachedApprovals?, _ counted: BurrowCounts?) -> Int? {
        switch (listed, counted) {
        case (let list?, let counts?): return list.fetchedAt >= counts.fetchedAt ? list.approvals.count : counts.approvals
        case (let list?, nil): return list.approvals.count
        case (nil, let counts?): return counts.approvals
        case (nil, nil): return nil
        }
    }
}

@available(iOS 18, *)
struct MeetingControlProvider: ControlValueProvider {
    var previewValue: ControlCopy { .startMeeting(lastSpace: nil, install: nil) }

    func currentValue() async throws -> ControlCopy {
        let installs = InstallStore.shared
        guard let host = installs.selectedHost else { return .startMeeting(lastSpace: nil, install: nil) }
        let signedIn = Set(installs.installs.map(\.host).filter { BurrowAPIClient.shared.isSignedIn(host: $0) })
        return .startMeeting(
            lastSpace: LastMeetingSpaceStore().spaceName(for: host),
            install: InstallLabel.label(for: host, installs: installs.installs, signedIn: signedIn))
    }
}
