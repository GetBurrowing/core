#if DEBUG
    import UIKit
    import WebKit

    /// DEBUG only (task 01a20618): the chat sometimes scrolls past its last
    /// message into blank space and the composer disappears until a force
    /// quit, with no known trigger. This probe records GEOMETRY ONLY, never a
    /// name, contact or message text, into `Library/Caches/chat-geometry.log`
    /// so the file can be copied off the device with
    /// `xcrun devicectl device copy from --domain-type appDataContainer`.
    ///
    /// A line is written for every keyboard show/hide/frame change, size
    /// transition, trait change, app foreground/background, URL change and
    /// notification open (native events), for every visualViewport/window
    /// resize, focus change, visibility change, LiveView navigation and
    /// change of `data-keyboard-open` / `--keyboard-inset` (web events, from a
    /// document-start script), and every `snapshotInterval` while active.
    /// Each line carries both halves: the native geometry and the web one.
    /// Paths are reduced to their first segment plus a hash.
    final class ChatGeometryProbe: NSObject {
        static let fileName = "chat-geometry.log"
        static let messageName = "burrowGeometryProbe"
        static let snapshotInterval: TimeInterval = 10
        /// Rotated to `<name>.1` past this size.
        static let maxBytes: UInt64 = 4_000_000

        private weak var controller: UIViewController?
        private weak var webView: WKWebView?
        private var observers: [NSObjectProtocol] = []
        private var timer: Timer?
        private var seq = 0
        private var lastKeyboardEnd: CGRect = .null
        private var lastLayout = ""
        private let writer = DispatchQueue(label: "burrow.chat-geometry-probe")
        private let url: URL?

        init(controller: UIViewController, webView: WKWebView) {
            self.controller = controller
            self.webView = webView
            url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Self.fileName)
            super.init()
            webView.isInspectable = true
            let controller = webView.configuration.userContentController
            controller.add(ProbeMessageHandler(self), name: Self.messageName)
            controller.addUserScript(
                WKUserScript(source: Self.documentScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            observe()
            startTimer()
            note("probe-start")
        }

        deinit {
            timer?.invalidate()
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        // MARK: Native events

        private func observe() {
            let center = NotificationCenter.default
            let keyboard: [(Notification.Name, String)] = [
                (UIResponder.keyboardWillShowNotification, "kb-will-show"),
                (UIResponder.keyboardDidShowNotification, "kb-did-show"),
                (UIResponder.keyboardWillHideNotification, "kb-will-hide"),
                (UIResponder.keyboardDidHideNotification, "kb-did-hide"),
                (UIResponder.keyboardDidChangeFrameNotification, "kb-did-change-frame"),
            ]
            for (name, label) in keyboard {
                observers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                        if let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { self?.lastKeyboardEnd = end }
                        self?.note(label)
                    })
            }
            let app: [(Notification.Name, String)] = [
                (UIApplication.didBecomeActiveNotification, "app-did-become-active"),
                (UIApplication.willResignActiveNotification, "app-will-resign-active"),
                (UIApplication.didEnterBackgroundNotification, "app-did-enter-background"),
                (UIApplication.willEnterForegroundNotification, "app-will-enter-foreground"),
            ]
            for (name, label) in app {
                observers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        self?.note(label)
                        if name == UIApplication.didBecomeActiveNotification { self?.startTimer() }
                        if name == UIApplication.didEnterBackgroundNotification { self?.stopTimer() }
                    })
            }
        }

        private func startTimer() {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: Self.snapshotInterval, repeats: true) { [weak self] _ in
                self?.note("periodic")
            }
        }

        private func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        /// The shell's layout pass: logged only when the web view's geometry changed.
        func layoutPass() {
            let layout = layoutKey()
            guard layout != lastLayout else { return }
            lastLayout = layout
            note("layout")
        }

        func willTransition(to size: CGSize) { note("will-transition to=\(Self.size(size))") }
        func didTransition() { note("did-transition") }
        func traitsChanged(_ traits: UITraitCollection) {
            note("traits h=\(traits.horizontalSizeClass.rawValue) v=\(traits.verticalSizeClass.rawValue)")
        }
        func urlChanged(_ url: URL?) { note("url \(Self.describe(path: url?.path))") }
        func notificationOpen(_ url: URL?) { note("notification-open \(Self.describe(path: url?.path))") }

        /// One native line, then the web snapshot read for the same `seq`.
        func note(_ event: String) {
            seq += 1
            let id = seq
            let native = nativeSnapshot()
            guard let webView else {
                write("n#\(id) \(event) native{\(native)} web{none}")
                return
            }
            webView.evaluateJavaScript("window.__burrowGeom ? window.__burrowGeom() : 'no-script'") { [weak self] value, error in
                let web = (value as? String) ?? (error.map { "error=\(($0 as NSError).code)" } ?? "nil")
                self?.write("n#\(id) \(event) native{\(native)} web{\(web)}")
            }
        }

        /// A web event from the document script.
        fileprivate func web(_ body: Any) {
            guard let dict = body as? [String: Any], let event = dict["ev"] as? String else { return }
            seq += 1
            let snap = (dict["snap"] as? String) ?? "nil"
            write("w#\(seq) \(Self.clip(event)) native{\(nativeSnapshot())} web{\(Self.clip(snap, 3000))}")
        }

        // MARK: Snapshots

        private func layoutKey() -> String {
            guard let webView else { return "none" }
            let frame = webView.convert(webView.bounds, to: nil)
            return "\(Self.rect(frame)) safe=\(Self.insets(webView.safeAreaInsets))"
        }

        private func nativeSnapshot() -> String {
            guard let webView, let controller else { return "none" }
            let window = webView.window
            let scroll = webView.scrollView
            var parts = [
                "state=\(UIApplication.shared.applicationState.rawValue)",
                "window=\(window.map { Self.size($0.bounds.size) } ?? "nil")",
                "orient=\(window?.windowScene?.interfaceOrientation.rawValue ?? -1)",
                "wv=\(window != nil ? Self.rect(webView.convert(webView.bounds, to: nil)) : "detached")",
                "offset=\(Self.point(scroll.contentOffset))",
                "inset=\(Self.insets(scroll.contentInset))",
                "adjInset=\(Self.insets(scroll.adjustedContentInset))",
                "contentSize=\(Self.size(scroll.contentSize))",
                "vcSafe=\(Self.insets(controller.view.safeAreaInsets))",
                "wvSafe=\(Self.insets(webView.safeAreaInsets))",
                "kbEnd=\(lastKeyboardEnd.isNull ? "none" : Self.rect(lastKeyboardEnd))",
            ]
            if #available(iOS 18, *), let shell = controller.duoShell as? UITabBarController {
                parts.append("tabHidden=\(shell.isTabBarHidden)")
                parts.append("tabBar=\(Self.rect(shell.tabBar.convert(shell.tabBar.bounds, to: nil)))")
            }
            return parts.joined(separator: " ")
        }

        // MARK: File

        private func write(_ line: String) {
            WebLoadLog.event("chat-geometry \(line)")
            guard let url else { return }
            let stamp = Self.stamp.string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            writer.async {
                let manager = FileManager.default
                if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > Self.maxBytes {
                    let old = url.appendingPathExtension("1")
                    try? manager.removeItem(at: old)
                    try? manager.moveItem(at: url, to: old)
                }
                if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }

        private static let stamp: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        // MARK: Formatting

        private static func rect(_ r: CGRect) -> String {
            "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded()))x\(Int(r.height.rounded()))"
        }
        private static func size(_ s: CGSize) -> String { "\(Int(s.width.rounded()))x\(Int(s.height.rounded()))" }
        private static func point(_ p: CGPoint) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }
        private static func insets(_ i: UIEdgeInsets) -> String {
            "\(Int(i.top.rounded())),\(Int(i.left.rounded())),\(Int(i.bottom.rounded())),\(Int(i.right.rounded()))"
        }
        private static func clip(_ s: String, _ limit: Int = 80) -> String { String(s.prefix(limit)) }

        /// `/chat/<id>` -> `chat#<hash>`: the section and a stable hash, so two
        /// chats can be told apart without logging an id or a name.
        static func describe(path: String?) -> String {
            guard let path else { return "none" }
            let first = path.split(separator: "/").first.map(String.init) ?? ""
            var hash: UInt32 = 5381
            for byte in path.utf8 { hash = (hash &* 33) ^ UInt32(byte) }
            return "\(first)#\(String(hash, radix: 16))"
        }

        /// Document-start: the web half of the snapshot and the web events.
        /// Geometry only: numbers, the keyboard attribute and variables, and the
        /// focused element's tag.
        static let documentScript = """
            (function () {
              if (window.__burrowGeom) return;
              var post = function (ev) {
                try { window.webkit.messageHandlers.\(messageName).postMessage({ ev: ev, snap: window.__burrowGeom() }); } catch (e) {}
              };
              var n = function (x) { return typeof x === "number" ? Math.round(x * 10) / 10 : "na"; };
              var rect = function (el) {
                if (!el) return "none";
                var b = el.getBoundingClientRect();
                return n(b.top) + "," + n(b.bottom) + "," + n(b.height);
              };
              var hash = function (s) {
                var h = 5381;
                for (var i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
                return h.toString(16);
              };
              window.__burrowGeom = function () {
                var d = document.documentElement, vv = window.visualViewport;
                var sc = document.getElementById("chat-message-scroller");
                var dock = document.getElementById("chat-dock");
                var zone = document.getElementById("chat-drop-zone");
                var ae = document.activeElement;
                var css = function (el, name) { return el ? (getComputedStyle(el).getPropertyValue(name) || "").trim() : "na"; };
                var units = "na";
                if (document.body) {
                  var probe = document.createElement("div");
                  probe.style.cssText = "position:fixed;left:-9px;top:0;width:1px;visibility:hidden;pointer-events:none";
                  document.body.appendChild(probe);
                  var unit = function (u) { probe.style.height = "100" + u; return n(probe.getBoundingClientRect().height); };
                  units = unit("vh") + "/" + unit("dvh") + "/" + unit("svh") + "/" + unit("lvh");
                  probe.remove();
                }
                // The dock's tall descendants: tag, data-role, two class tokens,
                // height and any inline height/max-height. Code names only.
                var tree = "none";
                if (dock) {
                  var tall = [];
                  var all = dock.querySelectorAll("*");
                  for (var i = 0; i < all.length && i < 400; i++) {
                    var el = all[i], b = el.getBoundingClientRect();
                    if (b.height < 60) continue;
                    var cls = (el.getAttribute("class") || "").split(/\\s+/).filter(Boolean).slice(0, 2).join(".");
                    var role = el.getAttribute("data-role") || "";
                    tall.push(n(b.height) + ":" + el.tagName.toLowerCase() + (role ? "[" + role + "]" : "") + (cls ? "." + cls : "") +
                      (el.style.height ? " h=" + el.style.height : "") + (el.style.maxHeight ? " mh=" + el.style.maxHeight : "") +
                      " pos=" + getComputedStyle(el).position);
                  }
                  tree = tall.slice(0, 10).join(" | ");
                }
                // The first message row starting inside the timeline: its index
                // and a hash of its DOM id, so "the same message is still in
                // view" can be read across a fold or rotation. No content.
                var anchor = "none";
                if (sc) {
                  var top = sc.getBoundingClientRect().top;
                  var rows = sc.querySelectorAll("[data-participant-id]");
                  for (var r = 0; r < rows.length; r++) {
                    var rb = rows[r].getBoundingClientRect();
                    if (rb.top >= top) { anchor = r + "/" + rows.length + "#" + hash(rows[r].id || "") + "@" + n(rb.top - top); break; }
                  }
                }
                var draft = "na";
                var input = dock && dock.querySelector("textarea, [contenteditable='true']");
                if (input) draft = ((input.value != null ? input.value : input.textContent) || "").length > 0 ? "nonempty" : "empty";
                var parts = [
                  "anchor=" + anchor,
                  "draft=" + draft,
                  "dockTree=" + tree,
                  "path=" + (location.pathname.split("/")[1] || "") + "#" + hash(location.pathname),
                  "units(vh/dvh/svh/lvh)=" + units,
                  "html=" + rect(d) + " body=" + rect(document.body),
                  "shell=" + rect(document.querySelector(".app-shell-root")) + " main=" + rect(document.querySelector("main")),
                  "inner=" + innerWidth + "x" + innerHeight,
                  "vv=" + (vv ? n(vv.width) + "x" + n(vv.height) + " vvTop=" + n(vv.offsetTop) + " vvPageTop=" + n(vv.pageTop) + " vvScale=" + n(vv.scale) : "none"),
                  "scrollY=" + n(window.scrollY),
                  "docScrollH=" + (document.scrollingElement ? document.scrollingElement.scrollHeight : "na"),
                  "kbOpen=" + (d ? d.hasAttribute("data-keyboard-open") : "na"),
                  "kbInset=" + (d ? d.style.getPropertyValue("--keyboard-inset") || "unset" : "na"),
                  "vvH=" + (d ? d.style.getPropertyValue("--visual-viewport-h") || "unset" : "na"),
                  "dockH=" + (d ? d.style.getPropertyValue("--chat-dock-h") || "unset" : "na"),
                  "ntbH=" + css(d, "--native-tab-bar-height"),
                  "duoOpen=" + (d ? d.hasAttribute("\(NativeNavBarDocument.duoOpenAttribute)") : "na"),
                  "dock=" + rect(dock),
                  "zone=" + rect(zone),
                  "phoneChrome=" + css(zone, "--phone-chrome-bottom"),
                  "scroller=" + rect(sc),
                  "scrollTop=" + (sc ? n(sc.scrollTop) : "na"),
                  "scrollH=" + (sc ? sc.scrollHeight : "na"),
                  "clientH=" + (sc ? sc.clientHeight : "na"),
                  "scPadB=" + (sc ? getComputedStyle(sc).paddingBottom : "na"),
                  "focus=" + (ae ? ae.tagName + (dock && dock.contains(ae) ? "@dock" : "") : "none"),
                  "vis=" + document.visibilityState
                ];
                return parts.join(" ");
              };
              var last = 0, pending = null;
              var throttled = function (ev) {
                var now = Date.now();
                if (now - last > 400) { last = now; post(ev); return; }
                if (!pending) pending = setTimeout(function () { pending = null; last = Date.now(); post(ev); }, 400);
              };
              var vv = window.visualViewport;
              if (vv) {
                vv.addEventListener("resize", function () { post("vv-resize"); });
                vv.addEventListener("scroll", function () { throttled("vv-scroll"); });
              }
              window.addEventListener("resize", function () { post("win-resize"); });
              window.addEventListener("orientationchange", function () { post("orientationchange"); });
              window.addEventListener("pageshow", function (e) { post("pageshow persisted=" + e.persisted); });
              window.addEventListener("pagehide", function () { post("pagehide"); });
              window.addEventListener("burrowNativeDuoPosture", function () { post("duo-posture"); });
              window.addEventListener("phx:page-loading-stop", function () { post("phx-nav"); });
              document.addEventListener("visibilitychange", function () { post("visibility"); });
              document.addEventListener("focusin", function (e) { post("focusin " + (e.target && e.target.tagName)); });
              document.addEventListener("focusout", function (e) { post("focusout " + (e.target && e.target.tagName)); });
              var watch = function () {
                var d = document.documentElement, seen = "";
                var key = function () { return d.hasAttribute("data-keyboard-open") + "|" + d.style.getPropertyValue("--keyboard-inset"); };
                seen = key();
                new MutationObserver(function () {
                  var k = key();
                  if (k !== seen) { seen = k; post("kb-state"); }
                }).observe(d, { attributes: true, attributeFilter: ["data-keyboard-open", "style"] });
                post("dom-ready");
              };
              if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch);
              else watch();
            })();
            """
    }

    /// Weak so the content controller does not retain the probe.
    private final class ProbeMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var probe: ChatGeometryProbe?
        init(_ probe: ChatGeometryProbe) { self.probe = probe }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            probe?.web(message.body)
        }
    }
#endif
