import SwiftUI
import UIKit

// The install picker (canvas 01a10887, Layout intent + Wireframes + States).
// Copy strings are the canvas's, verbatim.

enum InstallCopy {
    static let title = "Choose a Burrow install"
    static let subtitle = "Each install has its own spaces and sign-in."
    static let addButton = "Add an install"
    static let continueButton = "Continue"
    static let addTitle = "Add an install"
    static let addSubtitle = "Enter the address your team uses for Burrow."
    static let addressLabel = "Address"
    static let checkAndAdd = "Check and add"
    static let checking = "Checking"
    static let notBurrow = "Couldn't find Burrow at this address. Check the spelling, or ask your admin for the link."
    static let rowUnreachable = "Can't reach. Tap to retry."
    static func cantReach(_ host: String) -> String { "Can't reach \(host)" }
    static let tryAgain = "Try again"
    static let chooseAnother = "Choose another install"
    static let remove = "Remove"
    /// A stale row's host line: its count is the last one known (task 01a1261e).
    static let couldNotUpdate = "Could not update"
}

/// The per-install unread pill on a picker row (task 01a1261e stage 4).
/// Zero renders NO pill (never "0"); past 99 it reads "99+".
enum UnreadPill {
    static let cap = 99

    static func text(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > cap ? "\(cap)+" : "\(count)"
    }
}

/// Probes an install: `/health` must answer `{"status":"ok"}` and
/// `/manifest.json` must be a web app manifest. Both, or it is not Burrow.
enum InstallProbe {
    struct Result {
        let name: String?
    }

    static func probe(host: String, session: URLSession = .shared) async -> Result? {
        let install = Install(host: host)
        guard let health = try? await fetchJSON(install.healthURL, session: session),
            (health["status"] as? String) == "ok",
            let manifest = try? await fetchJSON(install.manifestURL, session: session),
            manifest["name"] != nil || manifest["short_name"] != nil
        else { return nil }
        return Result(name: (manifest["name"] as? String) ?? (manifest["short_name"] as? String))
    }

    static func reachable(host: String, session: URLSession = .shared) async -> Bool {
        guard let health = try? await fetchJSON(Install(host: host).healthURL, session: session) else { return false }
        return (health["status"] as? String) == "ok"
    }

    private static func fetchJSON(_ url: URL, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        // No `Accept: application/json`: /health answers that with 406
        // (measured on a production install, 2026-10-04).
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw URLError(.badServerResponse)
        }
        return json
    }
}

@MainActor
final class InstallPickerModel: ObservableObject {
    enum Reachability { case unknown, reachable, unreachable }

    @Published private(set) var installs: [Install] = []
    @Published private(set) var selectedHost: String?
    @Published private(set) var reachability: [String: Reachability] = [:]
    @Published private(set) var icons: [String: UIImage] = [:]
    /// Per-install unread (task 01a1261e). While a refresh runs the last
    /// counts stay on screen: this is only ever replaced by the store's
    /// current entries, never emptied first.
    @Published private(set) var unread: [String: InstallUnread] = [:]
    @Published var cantReachHost: String?
    @Published var continuing = false

    private let store: InstallStore
    private let unreadStore: InstallUnreadStore
    private let refreshUnread: () -> Void
    private var unreadObservation: NSObjectProtocol?

    init(store: InstallStore, unreadStore: InstallUnreadStore = .shared, refreshUnread: @escaping () -> Void = {}) {
        self.store = store
        self.unreadStore = unreadStore
        self.refreshUnread = refreshUnread
        reload()
        unreadObservation = NotificationCenter.default.addObserver(
            forName: .burrowInstallBadgesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadUnread() }
        }
    }

    deinit {
        if let unreadObservation { NotificationCenter.default.removeObserver(unreadObservation) }
    }

    func reload() {
        installs = store.installs
        selectedHost = store.selectedHost
        reloadUnread()
    }

    func reloadUnread() {
        unread = unreadStore.entries()
    }

    func select(_ host: String) {
        store.select(host)
        selectedHost = host
        if reachability[host] == .unreachable { refresh(host) }
    }

    func remove(_ host: String) {
        store.remove(host: host)
        reload()
    }

    func refreshAll() {
        for install in installs { refresh(install.host) }
        refreshUnread()
    }

    func refresh(_ host: String) {
        reachability[host] = .unknown
        Task {
            let result = await InstallProbe.probe(host: host)
            reachability[host] = result == nil ? .unreachable : .reachable
            if let name = result?.name {
                store.updateName(name, for: host)
                reload()
            }
            if icons[host] == nil, let image = await Self.fetchIcon(Install(host: host)) {
                icons[host] = image
            }
        }
    }

    /// Adds an install after probing it. Returns false with the field kept
    /// filled when the address is not a Burrow install.
    func add(_ typed: String) async -> Bool {
        guard let host = InstallStore.normalizeHost(typed),
            let result = await InstallProbe.probe(host: host)
        else { return false }
        store.add(host: host, name: result.name)
        reload()
        reachability[host] = .reachable
        refresh(host)
        return true
    }

    /// Continue: the chosen install must answer, else the full-screen
    /// Can't reach state.
    func continueWithSelection(_ done: (Install) -> Void) async {
        guard let host = selectedHost, let install = installs.first(where: { $0.host == host }) else { return }
        continuing = true
        let ok = await InstallProbe.reachable(host: host)
        continuing = false
        if ok {
            cantReachHost = nil
            reachability[host] = .reachable
            done(install)
        } else {
            reachability[host] = .unreachable
            cantReachHost = host
        }
    }

    private static func fetchIcon(_ install: Install) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: install.iconURL),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return UIImage(data: data)
    }
}

struct InstallPickerView: View {
    @StateObject var model: InstallPickerModel
    let onContinue: (Install) -> Void
    @State private var showingAdd = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // Regular width: a centred form sheet; compact: the iPhone layout.
        ZStack {
            BurrowColor.surface.color.ignoresSafeArea()
            if let host = model.cantReachHost {
                CantReachView(host: host) {
                    Task { await model.continueWithSelection(onContinue) }
                } chooseAnother: {
                    model.cantReachHost = nil
                }
            } else if model.installs.isEmpty {
                AddInstallFlow(store: model.installStore, mode: .firstLaunch) { install in
                    model.reload()
                    onContinue(install)
                }
            } else {
                list
            }
        }
        .burrowFormSheet(regular: sizeClass == .regular)
        .onAppear { model.refreshAll() }
        .sheet(isPresented: $showingAdd) {
            AddInstallFlow(store: model.installStore, mode: .sheet) { install in
                showingAdd = false
                model.reload()
                onContinue(install)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(InstallCopy.title)
                        .font(BurrowFont.title())
                        .tracking(-0.3)
                        .foregroundColor(BurrowColor.onSurface.color)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    Text(InstallCopy.subtitle)
                        .font(BurrowFont.secondary())
                        .foregroundColor(BurrowColor.muted.color)
                        .padding(.bottom, 24)
                    rows
                }
                .padding(.horizontal, 16)
            }
            VStack(spacing: 8) {
                BurrowButton(title: InstallCopy.addButton, style: .outlined) { showingAdd = true }
                BurrowButton(title: InstallCopy.continueButton, style: .primary, busy: model.continuing) {
                    Task { await model.continueWithSelection(onContinue) }
                }
                .disabled(model.selectedHost == nil)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var rows: some View {
        List {
            ForEach(model.installs) { install in
                InstallRow(
                    install: install,
                    icon: model.icons[install.host],
                    selected: install.host == model.selectedHost,
                    unreachable: model.reachability[install.host] == .unreachable,
                    unread: model.unread[install.host]
                )
                .contentShape(Rectangle())
                .hoverEffect()
                .onTapGesture { model.select(install.host) }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(BurrowColor.surface.color)
                .listRowSeparatorTint(BurrowColor.border.color)
                .listRowSeparator(install.host == model.installs.last?.host ? .hidden : .visible, edges: .bottom)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        model.remove(install.host)
                    } label: {
                        Text(InstallCopy.remove)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .environment(\.defaultMinListRowHeight, 64)
        .frame(height: CGFloat(model.installs.count) * 64)
        .clipShape(RoundedRectangle(cornerRadius: BurrowRadius.box, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BurrowRadius.box, style: .continuous)
                .stroke(BurrowColor.border.color, lineWidth: 1)
        )
    }
}

/// A picker row's line under the name (task 01a1261e, review round 2).
/// Android's `InstallPickerView.renderRow` has the same three outcomes.
enum InstallRowStatus: Equatable {
    /// The host, muted.
    case host
    /// Red dot, "Can't reach. Tap to retry.": unreachable, no stale count.
    case unreachable
    /// "Could not update": the count shown is the last one known. A red dot
    /// too when the probe also failed; a tap still retries.
    case couldNotUpdate(unreachable: Bool)

    init(unreachable: Bool, unread: InstallUnread?) {
        if unread?.stale == true {
            self = .couldNotUpdate(unreachable: unreachable)
        } else {
            self = unreachable ? .unreachable : .host
        }
    }

    func text(host: String) -> String {
        switch self {
        case .host: return host
        case .unreachable: return InstallCopy.rowUnreachable
        case .couldNotUpdate: return InstallCopy.couldNotUpdate
        }
    }

    var showsUnreachableDot: Bool {
        switch self {
        case .host, .couldNotUpdate(unreachable: false): return false
        case .unreachable, .couldNotUpdate(unreachable: true): return true
        }
    }

    /// A stale row is dimmed whatever its count, a zero count included.
    var dimmed: Bool {
        if case .couldNotUpdate = self { return true }
        return false
    }
}

struct InstallRow: View {
    let install: Install
    let icon: UIImage?
    let selected: Bool
    let unreachable: Bool
    var unread: InstallUnread? = nil

    var status: InstallRowStatus { InstallRowStatus(unreachable: unreachable, unread: unread) }

    var body: some View {
        HStack(spacing: 12) {
            InstallIcon(install: install, image: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(install.displayName)
                    .font(BurrowFont.body(.semibold))
                    .foregroundColor(BurrowColor.onSurface.color)
                    .lineLimit(1)
                // The status replaces the host line so it never takes width
                // from the name (canvas self-critique). A stale count says so
                // on that line (task 01a1261e), even when the install is also
                // unreachable; the red dot and tap-to-retry stay.
                HStack(spacing: 6) {
                    if status.showsUnreachableDot {
                        Circle().fill(BurrowColor.destructive.color).frame(width: 8, height: 8)
                    }
                    Text(status.text(host: install.host))
                        .font(BurrowFont.caption())
                        .foregroundColor(status.showsUnreachableDot ? BurrowColor.onSurface.color : BurrowColor.muted.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .opacity(status.dimmed ? UnreadPillView.staleOpacity : 1)
            Spacer(minLength: 8)
            // The CURRENT install shows its own count too, beside its check,
            // so the icon badge can be reconciled with the numbers shown.
            if let unread, let text = UnreadPill.text(unread.count) {
                UnreadPillView(text: text, stale: unread.stale)
            }
            SelectionMark(selected: selected)
        }
        .frame(height: 64)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Primary fill, onPrimary text, 12pt tabular digits; dimmed when stale.
struct UnreadPillView: View {
    static let staleOpacity = 0.45

    let text: String
    let stale: Bool

    var body: some View {
        Text(text)
            .font(BurrowFont.pill())
            .monospacedDigit()
            .foregroundColor(BurrowColor.onPrimary.color)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule(style: .continuous).fill(BurrowColor.primary.color))
            .opacity(stale ? Self.staleOpacity : 1)
            .accessibilityLabel("\(text) unread")
            .accessibilityIdentifier("unread-pill")
    }
}

struct InstallIcon: View {
    let install: Install
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                .fill(BurrowColor.surfaceMuted.color)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(install.displayName.prefix(1)).uppercased())
                    .font(BurrowFont.body(.heavy))
                    .foregroundColor(BurrowColor.onSurface.color)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                .stroke(BurrowColor.border.color, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

struct SelectionMark: View {
    let selected: Bool

    var body: some View {
        if selected {
            ZStack {
                Circle().fill(BurrowColor.primary.color)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(BurrowColor.onPrimary.color)
            }
            .frame(width: 24, height: 24)
        } else {
            Circle()
                .stroke(BurrowColor.border.color, lineWidth: 2)
                .frame(width: 24, height: 24)
        }
    }
}

struct BurrowButton: View {
    enum Style { case primary, outlined }

    let title: String
    let style: Style
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().tint(foreground)
                } else {
                    Text(title).font(BurrowFont.body(.bold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                    .fill(style == .primary ? BurrowColor.primary.color : BurrowColor.surface.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                    .stroke(style == .outlined ? BurrowColor.border.color : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous))
        .hoverEffect()
        .disabled(busy)
    }

    private var foreground: Color {
        style == .primary ? BurrowColor.onPrimary.color : BurrowColor.onSurface.color
    }
}

struct CantReachView: View {
    let host: String
    let tryAgain: () -> Void
    let chooseAnother: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(BurrowColor.destructive.color)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            Text(InstallCopy.cantReach(host))
                .font(BurrowFont.title())
                .multilineTextAlignment(.center)
                .foregroundColor(BurrowColor.onSurface.color)
            Spacer()
            VStack(spacing: 8) {
                BurrowButton(title: InstallCopy.tryAgain, style: .primary, action: tryAgain)
                BurrowButton(title: InstallCopy.chooseAnother, style: .outlined, action: chooseAnother)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Add your install (task 01a12787 stage 2)

// The first-launch flow and the switcher's Add install sheet: one field, then
// a confirmation card showing the install's own logo, name and host, before
// any sign-in. Canvas 01a12787-c69f "Design direction: first launch, add your
// install", revision 1. Copy is the canvas's, verbatim.

enum AddInstallCopy {
    static let title = "Add your install"
    static let body = "Enter the address your team uses for Burrow."
    /// Never a real host: a realistic placeholder gets typed in literally.
    static let placeholder = "yourteam.example.com"
    static let continueButton = "Continue"
    static let checking = "Checking..."
    static let help = "Don't know it? Ask the person who invited you."
    static let continueToSignIn = "Continue to sign in"
    static let changeAddress = "Not this one? Change address"
    static let offline = "You're offline. Connect and try again."
    static let addressLabel = "Address"
    static func notFound(_ host: String) -> String {
        "No Burrow install answered at \(host). Check the spelling, or ask the person who invited you."
    }
}

/// What a check of a typed address found. Offline is kept apart from not
/// found, because they ask the person to do different things.
enum InstallCheck: Equatable {
    case found(name: String?)
    case notFound
    case offline
}

extension InstallProbe {
    /// The URL errors that mean the device has no connection, not that the
    /// host is wrong.
    static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed]

    /// `probe(host:)`, but telling an offline device apart from a host that
    /// is not Burrow.
    static func check(host: String, session: URLSession = .shared) async -> InstallCheck {
        let install = Install(host: host)
        do {
            let health = try await fetchJSON(install.healthURL, session: session)
            guard (health["status"] as? String) == "ok" else { return .notFound }
            let manifest = try await fetchJSON(install.manifestURL, session: session)
            guard manifest["name"] != nil || manifest["short_name"] != nil else { return .notFound }
            return .found(name: (manifest["name"] as? String) ?? (manifest["short_name"] as? String))
        } catch {
            return classify(error)
        }
    }

    static func classify(_ error: Error) -> InstallCheck {
        if let urlError = error as? URLError, offlineCodes.contains(urlError.code) { return .offline }
        return .notFound
    }
}

extension InstallPickerModel {
    /// The store the picker reads, for the add flow to write to.
    var installStore: InstallStore { store }
}

@MainActor
final class AddInstallFlowModel: ObservableObject {
    enum Mode { case firstLaunch, sheet }

    /// The install the card shows before sign-in.
    struct Candidate: Equatable {
        let host: String
        let name: String?
        var displayName: String { name ?? host }
        var iconURL: URL { Install(host: host).iconURL }
    }

    enum State: Equatable {
        case idle
        case checking
        case confirm(Candidate)
        case notFound(host: String)
        case offline
    }

    typealias Probe = (String) async -> InstallCheck
    typealias IconLoader = (URL) async -> UIImage?

    @Published var address = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var icon: UIImage?

    private let store: InstallStore
    private let probe: Probe
    private let loadIcon: IconLoader

    init(store: InstallStore, probe: Probe? = nil, loadIcon: IconLoader? = nil) {
        self.store = store
        self.probe = probe ?? Self.defaultProbe
        self.loadIcon = loadIcon ?? Self.fetchIcon
    }

    var isChecking: Bool { state == .checking }
    var canSubmit: Bool { !isChecking && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var buttonTitle: String { isChecking ? AddInstallCopy.checking : AddInstallCopy.continueButton }

    /// The error line under the field, if any.
    var message: String? {
        switch state {
        case .notFound(let host): return AddInstallCopy.notFound(host)
        case .offline: return AddInstallCopy.offline
        case .idle, .checking, .confirm: return nil
        }
    }

    /// Continue: checks the typed address. The field stays editable while
    /// it runs.
    func submit() async {
        guard canSubmit else { return }
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = InstallStore.normalizeHost(typed) else {
            state = .notFound(host: typed)
            return
        }
        state = .checking
        icon = nil
        switch await probe(host) {
        case .found(let name):
            let candidate = Candidate(host: host, name: name)
            state = .confirm(candidate)
            if let image = await loadIcon(candidate.iconURL), state == .confirm(candidate) {
                icon = image
            }
        case .notFound:
            state = .notFound(host: host)
        case .offline:
            state = .offline
        }
    }

    /// "Not this one? Change address": back to the field, still filled.
    func changeAddress() {
        state = .idle
        icon = nil
    }

    /// "Continue to sign in": saves, selects and confirms the install. The
    /// caller then runs the same sign-in the picker's Continue runs.
    func confirm() -> Install? {
        guard case .confirm(let candidate) = state,
            let install = store.add(host: candidate.host, name: candidate.name)
        else { return nil }
        store.confirmSelection()
        return install
    }

    static let defaultProbe: Probe = { host in
        #if DEBUG
            // Screenshot seam: `-BurrowAddInstallProbe offline|notFound|<name>`.
            if let stub = UserDefaults.standard.string(forKey: "BurrowAddInstallProbe") {
                switch stub {
                case "offline": return .offline
                case "notFound": return .notFound
                default: return .found(name: stub)
                }
            }
        #endif
        return await InstallProbe.check(host: host)
    }

    static let fetchIcon: IconLoader = { url in
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return UIImage(data: data)
    }
}

struct AddInstallFlow: View {
    @StateObject private var model: AddInstallFlowModel
    let mode: AddInstallFlowModel.Mode
    let onContinue: (Install) -> Void
    @FocusState private var focused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(store: InstallStore, mode: AddInstallFlowModel.Mode, onContinue: @escaping (Install) -> Void) {
        _model = StateObject(wrappedValue: AddInstallFlowModel(store: store))
        self.mode = mode
        self.onContinue = onContinue
    }

    init(model: AddInstallFlowModel, mode: AddInstallFlowModel.Mode, onContinue: @escaping (Install) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.mode = mode
        self.onContinue = onContinue
    }

    var body: some View {
        ZStack {
            BurrowColor.surface.color.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image("LaunchMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                        .accessibilityHidden(true)
                        .padding(.top, mode == .sheet ? 32 : 24)
                        .padding(.bottom, 24)
                    Text(AddInstallCopy.title)
                        .font(BurrowFont.title())
                        .tracking(-0.3)
                        .foregroundColor(BurrowColor.onSurface.color)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 8)
                    if case .confirm(let candidate) = model.state {
                        card(candidate)
                    } else {
                        entry
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.never)
            .frame(maxWidth: mode == .sheet && sizeClass == .regular ? BurrowLayout.sheetWidth : .infinity)
        }
        .onAppear { focused = true }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AddInstallCopy.body)
                .font(BurrowFont.body())
                .foregroundColor(BurrowColor.onSurface.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            TextField(AddInstallCopy.placeholder, text: $model.address)
                .font(BurrowFont.input())
                .foregroundColor(BurrowColor.onSurface.color)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel(AddInstallCopy.addressLabel)
                .accessibilityIdentifier("install-address")
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                        .fill(BurrowColor.surfaceMuted.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                        .stroke(BurrowColor.border.color, lineWidth: 1)
                )
            if let message = model.message {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: model.state == .offline ? "wifi.exclamationmark" : "exclamationmark.circle.fill")
                        .foregroundColor(BurrowColor.destructive.color)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(BurrowFont.secondary())
                        .foregroundColor(BurrowColor.onSurface.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
                .accessibilityElement(children: .combine)
            }
            BurrowButton(title: model.buttonTitle, style: .primary, action: submit)
                .disabled(!model.canSubmit)
                .padding(.top, 16)
            Text(AddInstallCopy.help)
                .font(BurrowFont.secondary())
                .foregroundColor(BurrowColor.muted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
    }

    private func card(_ candidate: AddInstallFlowModel.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                InstallIcon(install: Install(host: candidate.host, name: candidate.name), image: model.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(BurrowFont.body(.semibold))
                        .foregroundColor(BurrowColor.onSurface.color)
                        .lineLimit(2)
                    Text(candidate.host)
                        .font(BurrowFont.mono())
                        .foregroundColor(BurrowColor.muted.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: BurrowRadius.box, style: .continuous)
                    .fill(BurrowColor.surfaceMuted.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BurrowRadius.box, style: .continuous)
                    .stroke(BurrowColor.border.color, lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .padding(.top, 12)
            BurrowButton(title: AddInstallCopy.continueToSignIn, style: .primary) {
                if let install = model.confirm() { onContinue(install) }
            }
            .padding(.top, 16)
            Button {
                model.changeAddress()
                focused = true
            } label: {
                Text(AddInstallCopy.changeAddress)
                    .font(BurrowFont.secondary(.semibold))
                    .foregroundColor(BurrowColor.onSurface.color)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .hoverEffect()
            .padding(.top, 8)
        }
    }

    private func submit() {
        Task { await model.submit() }
    }
}
