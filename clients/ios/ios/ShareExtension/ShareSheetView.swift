import SwiftUI

/// The share sheet (canvas 01a10887, "Share sheet" wireframe). Nav bar:
/// Cancel, title, and Send as a small FILLED primary button at field radius
/// (cyan text on white would be 1.8:1). Below: preview card, Space row,
/// optional agent row, message field.
///
/// iPad: the system presents the extension as a form sheet; the content is
/// the iPhone layout in a column no wider than `SuiteLayout.sheetWidth`.
/// Send sits in the top bar, so the keyboard never covers it. Hardware
/// keyboard: Return sends (once a space is chosen), Escape cancels.
struct ShareSheetView: View {
    @ObservedObject var model: ShareSheetModel
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Rectangle().fill(SuiteColor.border.color).frame(height: 1)
            if model.phase == .notSignedIn {
                notSignedIn
            } else {
                ZStack {
                    form
                    if case .sent(let name) = model.phase {
                        sentOverlay(name)
                    }
                }
            }
        }
        .frame(maxWidth: SuiteLayout.sheetWidth)
        .frame(maxWidth: .infinity)
        .background(SuiteColor.surface.color.ignoresSafeArea())
        .foregroundColor(SuiteColor.onSurface.color)
    }

    // MARK: Nav bar

    private var navBar: some View {
        ZStack {
            Text("Share to Burrow").font(SuiteFont.body(.semibold))
            HStack {
                Button("Cancel", action: onCancel)
                    .font(SuiteFont.body())
                    .foregroundColor(SuiteColor.onSurface.color)
                    .keyboardShortcut(.cancelAction)
                    .hoverEffect()
                    .disabled(model.fieldsLocked)
                Spacer()
                if model.phase != .notSignedIn {
                    sendButton
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var sendButton: some View {
        Button {
            model.send(onSent: onDone)
        } label: {
            ZStack {
                Text("Send").opacity(model.phase == .sending ? 0 : 1)
                if model.phase == .sending {
                    ProgressView().tint(SuiteColor.onPrimary.color)
                }
            }
            .font(SuiteFont.secondary(.bold))
            .foregroundColor(SuiteColor.onPrimary.color)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: SuiteRadius.field).fill(SuiteColor.primary.color))
            .opacity(model.canSend || model.phase == .sending ? 1 : 0.4)
        }
        // Return sends only while Send is enabled (a space chosen, not
        // already sending): a disabled button's shortcut does nothing.
        .keyboardShortcut(.defaultAction)
        .hoverEffect()
        .disabled(!model.canSend)
        .accessibilityLabel("Send")
    }

    // MARK: Not signed in

    private var notSignedIn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ShareSheetModel.notSignedInText)
                .font(SuiteFont.body())
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onCancel) {
                Text("Close")
                    .font(SuiteFont.body(.bold))
                    .foregroundColor(SuiteColor.onPrimary.color)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: SuiteRadius.field).fill(SuiteColor.primary.color))
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let banner = model.banner {
                    bannerView(banner)
                        .padding(.bottom, 16)
                }
                PreviewCard(payload: model.payload)
                    .padding(.bottom, 16)

                label("Space")
                spaceRow

                if let space = model.selectedSpace, !space.agents.isEmpty {
                    label("Address an agent (optional)")
                    agentRow(space)
                }

                label("Message")
                messageField
            }
            .padding(16)
            .disabled(model.fieldsLocked)
            .opacity(model.fieldsLocked ? 0.5 : 1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(SuiteFont.caption())
            .foregroundColor(SuiteColor.muted.color)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SuiteRadius.field).stroke(SuiteColor.border.color, lineWidth: 1))
    }

    @ViewBuilder
    private var spaceRow: some View {
        if model.phase == .loadingSpaces {
            field {
                Text("Loading spaces").font(SuiteFont.body()).foregroundColor(SuiteColor.muted.color)
                Spacer()
                ProgressView().tint(SuiteColor.onSurface.color)
            }
        } else if model.banner == .spacesFailed && model.spaces.isEmpty {
            Button(action: model.loadSpaces) {
                field {
                    Text("Try again").font(SuiteFont.body(.semibold))
                    Spacer()
                }
            }
        } else {
            Menu {
                ForEach(model.spaces) { space in
                    Button(space.name) { model.selectedSpaceID = space.id }
                }
            } label: {
                field {
                    Text(model.selectedSpace?.name ?? "Choose a space")
                        .font(SuiteFont.body(model.selectedSpace == nil ? .regular : .semibold))
                        .foregroundColor(model.selectedSpace == nil ? SuiteColor.muted.color : SuiteColor.onSurface.color)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(SuiteColor.muted.color)
                }
            }
        }
    }

    @ViewBuilder
    private func agentRow(_ space: SuiteSpace) -> some View {
        if let agent = model.selectedAgent {
            field {
                Button {
                    model.selectedAgentID = nil
                } label: {
                    HStack(spacing: 6) {
                        Text("@\(agent.name)")
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }
                    .font(SuiteFont.caption(.semibold))
                    .foregroundColor(SuiteColor.onSurface.color)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 16).fill(SuiteColor.surfaceMuted.color))
                }
                .accessibilityLabel("Remove @\(agent.name)")
                Spacer()
            }
        } else {
            Menu {
                ForEach(space.agents) { agent in
                    Button(agent.name) { model.selectedAgentID = agent.id }
                }
            } label: {
                field {
                    Text("No agent").font(SuiteFont.body()).foregroundColor(SuiteColor.muted.color)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(SuiteColor.muted.color)
                }
            }
        }
    }

    private var messageField: some View {
        TextField("Add a message", text: $model.message, axis: .vertical)
            .font(SuiteFont.input())
            .lineLimit(3...8)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: SuiteRadius.field).stroke(SuiteColor.border.color, lineWidth: 1))
    }

    private func bannerView(_ banner: ShareSheetModel.Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(SuiteColor.destructive.color)
            // Error copy is base-content beside the error-tone icon: error
            // red fails AA as text (canvas, palette).
            Text(banner.text)
                .font(SuiteFont.secondary())
                .foregroundColor(SuiteColor.onSurface.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: SuiteRadius.field).fill(SuiteColor.surfaceMuted.color))
        .accessibilityElement(children: .combine)
    }

    private func sentOverlay(_ spaceName: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
            Text("Sent to \(spaceName)")
                .font(SuiteFont.body(.semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundColor(SuiteColor.onSurface.color)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SuiteColor.surface.color.opacity(0.94))
        .accessibilityElement(children: .combine)
    }
}

/// The shared item: a thumbnail for an image, a glyph for anything else,
/// the name, and what it is.
struct PreviewCard: View {
    let payload: SharePayload?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: SuiteRadius.field).fill(SuiteColor.surfaceMuted.color))
                .clipShape(RoundedRectangle(cornerRadius: SuiteRadius.field))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SuiteFont.body(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(SuiteFont.caption())
                    .foregroundColor(SuiteColor.muted.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: SuiteRadius.box).stroke(SuiteColor.border.color, lineWidth: 1))
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch payload {
        case .image(let part):
            if let image = UIImage(contentsOfFile: part.url.path)?.preparingThumbnail(of: CGSize(width: 192, height: 192)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                glyph("photo")
            }
        case .pdf: glyph("doc.richtext")
        case .file: glyph("doc")
        case .url: glyph("link")
        case .text: glyph("text.alignleft")
        case nil: ProgressView().tint(SuiteColor.onSurface.color)
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(SuiteColor.onSurface.color)
    }

    private var title: String {
        switch payload {
        case .image(let part), .pdf(let part), .file(let part): return part.filename
        case .url(let url): return url.host ?? url.absoluteString
        case .text(let text): return text
        case nil: return "Preparing"
        }
    }

    private var subtitle: String {
        switch payload {
        case .image(let part), .pdf(let part), .file(let part):
            let kind: String
            switch payload {
            case .image: kind = "Image"
            case .pdf: kind = "PDF"
            default: kind = "File"
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: part.url.path)[.size] as? NSNumber)??.int64Value ?? 0
            return "\(kind), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .decimal))"
        case .url(let url): return url.absoluteString
        case .text: return "Text"
        case nil: return ""
        }
    }
}
