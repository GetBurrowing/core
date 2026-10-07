import AppIntents
import Foundation

/// Wires the shared intent code to the app process: Spotlight indexing;
/// App Shortcut parameters refreshed when the app's scene goes to the
/// background, only if the agents or spaces changed
/// (ShortcutParameterRefresh), never from a fetch; and, after an Ask, a
/// recipients-only donation of the agent (DonationPolicy).
enum IntentAppHooks {
    static func install() {
        IntentHooks.indexesSpotlight = true
        IntentHooks.didSucceed = { intent in didSucceed(intent) }
        ShortcutParameterRefresh.shared.update = { BurrowShortcuts.updateAppShortcutParameters() }
        IntentHooks.didFetchEntities = { route, host, keys in
            ShortcutParameterRefresh.shared.record(route: route, host: host, keys: keys)
        }
        InstallStore.didRemove = { host in forget(host: host) }
        // Joining a meeting from Siri, Shortcuts or Spotlight starts a native
        // call in this process (task 01a10db7 stage 3). The widget process
        // never sets this, so a widget keeps opening the web page. An intent
        // run is not donated again (`donates: false`).
        MeetingLauncher.start = { host, meetingID in
            Task { @MainActor in CallController.shared.start(host: host, meetingID: meetingID, donates: false) }
        }
    }

    /// A successful intent run. It is NOT donated whole (task 01a111bb
    /// stage 4): the system already knows about a Siri or Shortcuts run,
    /// and a whole intent would donate its message, question or note. The
    /// one exception is an Ask, whose AGENT (only) is donated as a recipient.
    @discardableResult
    static func didSucceed(_ intent: Any, donations: Donations = .shared) -> Task<Void, Never>? {
        guard let ask = intent as? AskAgentIntent, let ref = EntityRef(ask.agent.id) else { return nil }
        return donations.donate(.askedAgent(host: ref.host, agentID: ref.uuid))
    }

    /// Sign-out or removal of an install: its titles stop being searchable,
    /// its donations are deleted, and its remembered meeting space is
    /// forgotten. Another install's entries and donations are untouched.
    @discardableResult
    static func forget(host: String, donations: Donations = .shared) -> Task<Void, Never> {
        SpotlightIndex.removeAll(host: host)
        ShortcutParameterRefresh.shared.forget(host: host)
        EntityCatalog.spaceIDsBySegment[host] = nil
        LastMeetingSpaceStore().remove(for: host)
        if #available(iOS 27, *) { PeopleCache.shared.removeAll(host: host) }
        return Task { await donations.forget(host: host) }
    }
}
