import AppIntents
import Foundation

/// Wires the shared intent code to the app process: donations after a
/// successful open, send, ask or start; Spotlight indexing; App Shortcut
/// parameters refreshed when the app's scene goes to the background, only if
/// the agents or spaces changed (ShortcutParameterRefresh), never from a
/// fetch.
enum IntentAppHooks {
    static func install() {
        IntentHooks.indexesSpotlight = true
        IntentHooks.didSucceed = { intent in
            guard let intent = intent as? any AppIntent else { return }
            donate(intent)
        }
        ShortcutParameterRefresh.shared.update = { BurrowShortcuts.updateAppShortcutParameters() }
        IntentHooks.didFetchEntities = { route, host, keys in
            ShortcutParameterRefresh.shared.record(route: route, host: host, keys: keys)
        }
        InstallStore.didRemove = { host in forget(host: host) }
    }

    private static func donate(_ intent: some AppIntent) {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: intent) }
    }

    /// Sign-out or removal of an install: its titles stop being searchable
    /// and its remembered meeting space is forgotten.
    static func forget(host: String) {
        SpotlightIndex.removeAll(host: host)
        ShortcutParameterRefresh.shared.forget(host: host)
        EntityCatalog.spaceIDsBySegment[host] = nil
        LastMeetingSpaceStore().remove(for: host)
    }
}
