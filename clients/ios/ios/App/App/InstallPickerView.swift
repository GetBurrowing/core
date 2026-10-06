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
    static let notSuite = "Couldn't find Burrow at this address. Check the spelling, or ask your admin for the link."
    static let rowUnreachable = "Can't reach. Tap to retry."
    static func cantReach(_ host: String) -> String { "Can't reach \(host)" }
    static let tryAgain = "Try again"
    static let chooseAnother = "Choose another install"
    static let remove = "Remove"
}

/// Probes an install: `/health` must answer `{"status":"ok"}` and
/// `/manifest.json` must be a web app manifest. Both, or it is not Suite.
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
        // (measured on suite.example.com, 2026-10-04).
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
    @Published var cantReachHost: String?
    @Published var continuing = false

    private let store: InstallStore

    init(store: InstallStore) {
        self.store = store
        reload()
    }

    func reload() {
        installs = store.installs
        selectedHost = store.selectedHost
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
    /// filled when the address is not a Suite install.
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
            SuiteColor.surface.color.ignoresSafeArea()
            if let host = model.cantReachHost {
                CantReachView(host: host) {
                    Task { await model.continueWithSelection(onContinue) }
                } chooseAnother: {
                    model.cantReachHost = nil
                }
            } else {
                list
            }
        }
        .suiteFormSheet(regular: sizeClass == .regular)
        .onAppear { model.refreshAll() }
        .sheet(isPresented: $showingAdd) {
            AddInstallView(model: model) { showingAdd = false }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(InstallCopy.title)
                        .font(SuiteFont.title())
                        .tracking(-0.3)
                        .foregroundColor(SuiteColor.onSurface.color)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    Text(InstallCopy.subtitle)
                        .font(SuiteFont.secondary())
                        .foregroundColor(SuiteColor.muted.color)
                        .padding(.bottom, 24)
                    rows
                }
                .padding(.horizontal, 16)
            }
            VStack(spacing: 8) {
                SuiteButton(title: InstallCopy.addButton, style: .outlined) { showingAdd = true }
                SuiteButton(title: InstallCopy.continueButton, style: .primary, busy: model.continuing) {
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
                    unreachable: model.reachability[install.host] == .unreachable
                )
                .contentShape(Rectangle())
                .hoverEffect()
                .onTapGesture { model.select(install.host) }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(SuiteColor.surface.color)
                .listRowSeparatorTint(SuiteColor.border.color)
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
        .clipShape(RoundedRectangle(cornerRadius: SuiteRadius.box, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SuiteRadius.box, style: .continuous)
                .stroke(SuiteColor.border.color, lineWidth: 1)
        )
    }
}

struct InstallRow: View {
    let install: Install
    let icon: UIImage?
    let selected: Bool
    let unreachable: Bool

    var body: some View {
        HStack(spacing: 12) {
            InstallIcon(install: install, image: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(install.displayName)
                    .font(SuiteFont.body(.semibold))
                    .foregroundColor(SuiteColor.onSurface.color)
                    .lineLimit(1)
                if unreachable {
                    // The status replaces the host line so it never takes
                    // width from the name (canvas self-critique).
                    HStack(spacing: 6) {
                        Circle().fill(SuiteColor.destructive.color).frame(width: 8, height: 8)
                        Text(InstallCopy.rowUnreachable)
                            .font(SuiteFont.caption())
                            .foregroundColor(SuiteColor.onSurface.color)
                            .lineLimit(1)
                    }
                } else {
                    Text(install.host)
                        .font(SuiteFont.caption())
                        .foregroundColor(SuiteColor.muted.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            SelectionMark(selected: selected)
        }
        .frame(height: 64)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct InstallIcon: View {
    let install: Install
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                .fill(SuiteColor.surfaceMuted.color)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(install.displayName.prefix(1)).uppercased())
                    .font(SuiteFont.body(.heavy))
                    .foregroundColor(SuiteColor.onSurface.color)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                .stroke(SuiteColor.border.color, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

struct SelectionMark: View {
    let selected: Bool

    var body: some View {
        if selected {
            ZStack {
                Circle().fill(SuiteColor.primary.color)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(SuiteColor.onPrimary.color)
            }
            .frame(width: 24, height: 24)
        } else {
            Circle()
                .stroke(SuiteColor.border.color, lineWidth: 2)
                .frame(width: 24, height: 24)
        }
    }
}

struct SuiteButton: View {
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
                    Text(title).font(SuiteFont.body(.bold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                    .fill(style == .primary ? SuiteColor.primary.color : SuiteColor.surface.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                    .stroke(style == .outlined ? SuiteColor.border.color : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous))
        .hoverEffect()
        .disabled(busy)
    }

    private var foreground: Color {
        style == .primary ? SuiteColor.onPrimary.color : SuiteColor.onSurface.color
    }
}

struct AddInstallView: View {
    @ObservedObject var model: InstallPickerModel
    let close: () -> Void
    @State private var address = ""
    @State private var checking = false
    @State private var failed = false
    @FocusState private var focused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            SuiteColor.surface.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(InstallCopy.addTitle)
                    .font(SuiteFont.title())
                    .tracking(-0.3)
                    .foregroundColor(SuiteColor.onSurface.color)
                    .padding(.top, 32)
                    .padding(.bottom, 4)
                Text(InstallCopy.addSubtitle)
                    .font(SuiteFont.secondary())
                    .foregroundColor(SuiteColor.muted.color)
                    .padding(.bottom, 12)
                Text(InstallCopy.addressLabel)
                    .font(SuiteFont.caption())
                    .foregroundColor(SuiteColor.muted.color)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                HStack(spacing: 2) {
                    Text("https://")
                        .font(SuiteFont.input())
                        .foregroundColor(SuiteColor.muted.color)
                    TextField("suite.example.com", text: $address)
                        .font(SuiteFont.input())
                        .foregroundColor(SuiteColor.onSurface.color)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(check)
                        .accessibilityLabel(InstallCopy.addressLabel)
                        .accessibilityIdentifier("install-address")
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                        .stroke(SuiteColor.border.color, lineWidth: 1)
                )
                if failed {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(SuiteColor.destructive.color)
                            .accessibilityHidden(true)
                        Text(InstallCopy.notSuite)
                            .font(SuiteFont.caption())
                            .foregroundColor(SuiteColor.onSurface.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }
                Spacer()
                SuiteButton(title: checking ? InstallCopy.checking : InstallCopy.checkAndAdd, style: .primary, busy: checking, action: check)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
            // The system already presents this as a sheet; in regular width
            // keep its column to form-sheet width.
            .frame(maxWidth: sizeClass == .regular ? SuiteLayout.sheetWidth : .infinity)
        }
        .onAppear { focused = true }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        failed = false
        Task {
            let ok = await model.add(address)
            checking = false
            if ok { close() } else { failed = true }
        }
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
                .foregroundColor(SuiteColor.destructive.color)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            Text(InstallCopy.cantReach(host))
                .font(SuiteFont.title())
                .multilineTextAlignment(.center)
                .foregroundColor(SuiteColor.onSurface.color)
            Spacer()
            VStack(spacing: 8) {
                SuiteButton(title: InstallCopy.tryAgain, style: .primary, action: tryAgain)
                SuiteButton(title: InstallCopy.chooseAnother, style: .outlined, action: chooseAnother)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
    }
}
