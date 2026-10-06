import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Share Extension's principal class: hosts the SwiftUI sheet and turns
/// the shared item into a `SharePayload`.
///
/// Auth is the bearer in the shared Keychain for the install selected in
/// the app (InstallStore, App Group). The extension never touches web-view
/// cookies.
final class ShareViewController: UIViewController {
    private var model: ShareSheetModel!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SuiteColor.surface.uiColor
        // iPad presents a share extension as a form sheet; ask for the
        // standard form-sheet size. iPhone ignores it.
        preferredContentSize = CGSize(width: SuiteLayout.sheetWidth, height: 620)

        model = ShareSheetModel(install: InstallStore.shared.selectedInstall)
        let sheet = ShareSheetView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onDone: { [weak self] in self?.finish() }
        )
        let host = UIHostingController(rootView: sheet)
        host.view.backgroundColor = SuiteColor.surface.uiColor
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        model.start()
        if model.phase != .notSignedIn {
            loadPayload()
        }
    }

    private func loadPayload() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        ShareItemLoader.load(from: providers) { [weak self] payload in
            DispatchQueue.main.async { self?.model.payload = payload }
        }
    }

    private func cancel() {
        ShareItemLoader.cleanUp()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func finish() {
        ShareItemLoader.cleanUp()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// Picks the one item to send, in this order: an image, a PDF, any other
/// file, a web URL, plain text.
enum ShareItemLoader {
    static var workDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("suite-share", isDirectory: true)
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    static func load(from providers: [NSItemProvider], completion: @escaping (SharePayload?) -> Void) {
        func first(_ type: UTType) -> NSItemProvider? {
            providers.first { $0.hasItemConformingToTypeIdentifier(type.identifier) }
        }

        if let provider = first(.image) {
            loadFile(provider, type: .image) { part in completion(part.map { .image(convertHEICIfNeeded($0)) }) }
        } else if let provider = first(.pdf) {
            loadFile(provider, type: .pdf) { part in completion(part.map { .pdf($0) }) }
        } else if let provider = first(.fileURL) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let url = item as? URL, let part = copyIn(url, suggestedName: url.lastPathComponent) else {
                    return completion(nil)
                }
                completion(part.mimeType == "application/pdf" ? .pdf(part) : .file(part))
            }
        } else if let provider = first(.url) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                completion((item as? URL).map { .url($0) })
            }
        } else if let provider = first(.plainText) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                completion((item as? String).map { .text($0) })
            }
        } else {
            completion(nil)
        }
    }

    /// The system's file is deleted when this callback returns, so it is
    /// copied (on disk, not into memory) into the extension's own temp dir.
    private static func loadFile(
        _ provider: NSItemProvider, type: UTType,
        completion: @escaping (MultipartForm.FilePart?) -> Void
    ) {
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true } ?? type.identifier
        provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
            if let url,
                let part = copyIn(
                    url,
                    suggestedName: provider.suggestedName.map { name in
                        URL(fileURLWithPath: name).pathExtension.isEmpty
                            ? name + "." + (UTType(identifier)?.preferredFilenameExtension ?? url.pathExtension)
                            : name
                    } ?? url.lastPathComponent)
            {
                return completion(part)
            }
            // Some sources (a screenshot's markup editor) only offer an
            // in-memory image.
            guard type == .image else { return completion(nil) }
            provider.loadItem(forTypeIdentifier: identifier) { item, _ in
                if let url = item as? URL { return completion(copyIn(url, suggestedName: url.lastPathComponent)) }
                let data = (item as? Data) ?? (item as? UIImage)?.jpegData(compressionQuality: 0.9)
                guard let data else { return completion(nil) }
                let target = uniqueURL(named: "Image.jpg")
                completion(
                    (try? data.write(to: target)) == nil
                        ? nil
                        : MultipartForm.FilePart(filename: "Image.jpg", mimeType: "image/jpeg", url: target))
            }
        }
    }

    static func copyIn(_ source: URL, suggestedName: String) -> MultipartForm.FilePart? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = suggestedName.isEmpty ? source.lastPathComponent : suggestedName
        let target = uniqueURL(named: name)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return nil
        }
        return MultipartForm.FilePart(filename: name, mimeType: mimeType(for: target), url: target)
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Browsers outside Safari cannot show HEIC, so an iPhone photo is
    /// re-encoded as JPEG. ImageIO reads and writes through the files, so
    /// the full decoded bitmap is the only large allocation.
    static func convertHEICIfNeeded(_ part: MultipartForm.FilePart) -> MultipartForm.FilePart {
        guard let type = UTType(filenameExtension: part.url.pathExtension), type.conforms(to: .heic) || type.conforms(to: .heif),
            let source = CGImageSourceCreateWithURL(part.url as CFURL, nil)
        else { return part }
        let name = URL(fileURLWithPath: part.filename).deletingPathExtension().lastPathComponent + ".jpg"
        let target = uniqueURL(named: name)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return part
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return part }
        try? FileManager.default.removeItem(at: part.url)
        return MultipartForm.FilePart(filename: name, mimeType: "image/jpeg", url: target)
    }

    private static func uniqueURL(named name: String) -> URL {
        let dir = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}
