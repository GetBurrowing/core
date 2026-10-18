// Burrow personal-context donations (task 01a111bb).
//
// The server pushes `native_donate` (PlatformWeb.NativeDonation) after a
// person sends a message, creates a task, approves or rejects a plan, or
// starts a meeting from the web view. The payload is ids only: a kind plus
// recipient, task, project or meeting ids, never text. Inside the Burrow app
// (Capacitor) this forwards it to the native SuiteNative.donate plugin, which
// donates a recipients-only intent so Siri learns who the person works with.
//
// In a plain browser there is no native platform and this does nothing. The
// detection mirrors hooks/push_subscribe.js `nativePushPlugin/1`.
export function nativeDonatePlugin(win = globalThis.window) {
  const cap = win?.Capacitor;
  if (!cap?.isNativePlatform?.()) return null;
  // `BurrowNative` in newer app builds, `SuiteNative` in older ones (task
  // 01a14ba9): read either, Burrow first.
  const plugin = cap.Plugins?.BurrowNative || cap.Plugins?.SuiteNative;
  return typeof plugin?.donate === "function" ? plugin : null;
}

export function installNativeDonations(win = globalThis.window) {
  if (!win?.addEventListener) return;

  win.addEventListener("phx:native_donate", (event) => {
    const plugin = nativeDonatePlugin(win);
    if (!plugin) return;

    try {
      // A rejected promise from an older app build without `donate` must not
      // surface as an unhandled rejection in the page.
      const result = plugin.donate(event.detail);
      if (result && typeof result.catch === "function") result.catch(() => {});
    } catch (_error) {
      // Donation is best effort; it never affects the page.
    }
  });
}
