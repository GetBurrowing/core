import Foundation

/// Which installs a widget shows (task 01a21e75 stage 3): every signed-in
/// install (the default), or one.
enum WidgetScope: Equatable {
    case all
    case pinned(String)

    /// The host a pinned scope names, if it is still saved; a pinned install
    /// that was removed falls back to All installs.
    func resolved(saved installs: [Install]) -> WidgetScope {
        guard case .pinned(let host) = self else { return .all }
        return installs.contains { $0.host == host } ? self : .all
    }

    /// The installs this scope covers, in saved order.
    func installs(from saved: [Install]) -> [Install] {
        switch resolved(saved: saved) {
        case .all: return saved
        case .pinned(let host): return saved.filter { $0.host == host }
        }
    }

    var pinnedHost: String? {
        if case .pinned(let host) = self { return host }
        return nil
    }

    /// The My approvals widget's scope (task 01a21e75 stage 3): an explicit
    /// one-install `scope` that is still saved; else a v1 `legacyInstall`
    /// that is still saved (a widget placed before this change stays
    /// PINNED); else All installs.
    static func approvals(legacyInstall: String?, scope: WidgetScope?, saved: [Install]) -> WidgetScope {
        if case .pinned(let host)? = scope, saved.contains(where: { $0.host == host }) { return .pinned(host) }
        if let host = legacyInstall, saved.contains(where: { $0.host == host }) { return .pinned(host) }
        return .all
    }
}
