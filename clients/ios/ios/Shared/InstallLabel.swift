import Foundation

/// The name a widget row, header or control shows for an install (task
/// 01a21e75 stage 3; canvas 01a21e80 "All installs").
///
/// Nil while only one install is signed in: with no choice there is no
/// label. Otherwise the install's own name, and when it has none yet,
/// "Install <n>" by its position in the saved list. Never the host:
/// `Install.displayName` falls back to the host, and the widgets show
/// display names only.
enum InstallLabel {
    /// `host`'s label among `installs`, given the hosts holding a bearer.
    static func label(for host: String, installs: [Install], signedIn: Set<String>) -> String? {
        let signedInCount = installs.filter { signedIn.contains($0.host) }.count
        guard signedInCount > 1 else { return nil }
        return name(for: host, installs: installs)
    }

    /// The label regardless of how many installs are signed in: for a
    /// pinned widget or a failure line, which always names its install.
    static func name(for host: String, installs: [Install]) -> String {
        guard let index = installs.firstIndex(where: { $0.host == host }) else { return "Install" }
        if let name = installs[index].name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != host {
            return name
        }
        return "Install \(index + 1)"
    }

    /// "2 installs": the small widgets' line under a summed count.
    static func count(_ n: Int) -> String { n == 1 ? "1 install" : "\(n) installs" }
}
