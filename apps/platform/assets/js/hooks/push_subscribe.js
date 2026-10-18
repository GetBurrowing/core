function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

// How fast an answer to Notification.requestPermission() has to come back
// before we conclude the user was never asked.
//
// Chrome refuses the request outright in a private window, and every browser
// refuses it when notifications are switched off for all sites. In both cases
// the promise settles in the same task, typically under 5ms. No dialog is
// ever painted. A human who is shown a dialog has to see it and move to the
// Block button; the floor for a simple visual reaction is around 200ms before
// any pointer movement, and in practice it is far longer.
//
// 100ms sits an order of magnitude above the automatic path and well below
// any human one, so a loaded main thread cannot push an automatic refusal
// past it and no real choice can fall under it. Getting this wrong in the
// safe direction (over the threshold) just shows today's site-settings copy.
//
// Timing, not private-browsing detection: every reliable private-mode probe
// is a fingerprinting trick that browsers actively break, and the private
// window is only one of the two causes anyway.
const AUTO_DENY_THRESHOLD_MS = 100;

// The Burrow iOS app (task 01a10882) runs this page inside a Capacitor web
// view. WKWebView has no usable Push API there, and the app delivers through
// APNs instead, so on the native platform the hook hands the whole job to
// the app's one native plugin, SuiteNative, and never touches pushManager.
export function nativePushPlugin(win = globalThis.window) {
  const cap = win?.Capacitor;
  if (!cap?.isNativePlatform?.()) return null;
  // The plugin is `BurrowNative` in newer app builds and `SuiteNative` in
  // older ones (task 01a14ba9); installed apps of both kinds coexist.
  return cap.Plugins?.BurrowNative || cap.Plugins?.SuiteNative || null;
}

// Which native shell is running ("android" / "ios"), or null. It rides
// ALONGSIDE the state on every native `push_permission_state` (like
// `auto_denied` does in the browser), never as a sixth state value. The
// server needs it for one reason: inside the Android app "denied" is not a
// browser block. Burrow Android can still show its explainer (and, after one
// denial, Android's prompt; after two, its notification settings), so the
// /inbox row offers the re-ask there instead of browser address-bar steps
// (task 01a10d8e). iOS renders exactly as before.
export function nativePlatform(win = globalThis.window) {
  const platform = win?.Capacitor?.getPlatform?.();
  return typeof platform === "string" && platform !== "web" ? platform : null;
}

function nativeStatePayload(state) {
  const platform = nativePlatform();
  return platform ? { state, native_platform: platform } : { state };
}

const PushSubscribe = {
  mounted() {
    // Every exit path below reports a state. Returning silently leaves the
    // server's :push_permission assign at "unknown" forever, which renders
    // neither the opt-in banner nor an unsupported notice.
    const nativePush = nativePushPlugin();
    if (nativePush) {
      this.mountNative(nativePush);
      return;
    }

    const vapidMeta = document.querySelector("meta[name='vapid-public-key']");
    if (!vapidMeta) {
      this.pushEvent("push_unsupported", {});
      return;
    }

    const vapidPublicKey = vapidMeta.getAttribute("content");
    if (!vapidPublicKey) {
      this.pushEvent("push_unsupported", {});
      return;
    }

    this.vapidPublicKey = vapidPublicKey;

    // Check current permission state
    if (!("Notification" in window) || !("serviceWorker" in navigator)) {
      this.pushEvent("push_unsupported", {});
      return;
    }

    if (Notification.permission === "granted") {
      // Already granted — subscribe silently
      this.autoSubscribe();
      this.pushEvent("push_permission_state", { state: "granted" });
    } else if (Notification.permission === "denied") {
      this.pushEvent("push_permission_state", { state: "denied" });
    } else {
      // Default state, on every browser: ask, and only from a user gesture.
      // Safari on macOS rejects a permission request that no gesture drove,
      // and Chrome's quiet notification UI can suppress one outright. Both
      // land in autoSubscribe's catch, where the user learns nothing. Report
      // "prompt" instead so the opt-in banner renders; the click on it comes
      // back as the request_push_permission event handled below.
      this.pushEvent("push_permission_state", { state: "prompt" });
    }

    // Listen for the user clicking the enable button
    this.handleEvent("request_push_permission", () => {
      this.requestPermission();
    });
  },

  // Native branch. The honesty rule from task 019ffe52 applies unchanged:
  // "granted" is reported ONLY when the app's device registration POST to
  // /api/app/devices succeeded. enablePush() resolves {registered: true}
  // only in that case; an OS-level grant whose POST failed comes back as a
  // rejection (or registered: false) and is reported as a failed
  // registration, which leaves the server's :push_permission alone.
  mountNative(plugin) {
    this.nativePush = plugin;

    Promise.resolve(plugin.pushState?.())
      .then(result => {
        const state = result?.state;
        if (state === "granted") {
          // Already allowed in iOS Settings: re-register silently so a
          // rotated APNs token reaches the server. No prompt is shown.
          this.enableNativePush();
        } else if (state === "denied") {
          this.pushEvent("push_permission_state", nativeStatePayload("denied"));
        } else if (state === "prompt") {
          // iOS has never asked on this device: ask now, without waiting for
          // the banner. The browser branch waits for a click, but the
          // banner's dismissal is stored per USER, not per device, so a
          // person who dismissed it on a desktop never sees it in the app.
          // Waiting for that click would lock a new device out of push for
          // good: iOS never prompts, and the app never appears in iOS
          // Settings > Notifications. iOS shows its system prompt at most
          // once per install, so this cannot nag. enableNativePush keeps the
          // honesty rule: "granted" only on registered: true.
          this.enableNativePush();
        } else {
          this.pushEvent("push_permission_state", nativeStatePayload("prompt"));
        }
      })
      .catch(() => {
        // pushState itself failed, so we don't know iOS's state. Report
        // "prompt" and let the banner's click drive enablePush.
        this.pushEvent("push_permission_state", nativeStatePayload("prompt"));
      });

    this.handleEvent("request_push_permission", () => {
      this.enableNativePush();
    });
  },

  enableNativePush() {
    return Promise.resolve()
      .then(() => this.nativePush.enablePush())
      .then(result => {
        if (result?.registered === true) {
          this.pushEvent("push_permission_state", nativeStatePayload("granted"));
        } else if (result?.state === "denied") {
          this.pushEvent("push_permission_state", nativeStatePayload("denied"));
        } else if (result?.state === "prompt") {
          this.pushEvent("push_permission_state", nativeStatePayload("prompt"));
        } else {
          this.pushEvent("push_subscribe_failed", {
            name: "NativeRegistrationFailed",
            message: result?.error || "device registration was not stored"
          });
        }
      })
      .catch(err => {
        this.pushEvent("push_subscribe_failed", {
          name: err?.code || err?.name || "NativeRegistrationFailed",
          message: err?.message || String(err)
        });
      });
  },

  requestPermission() {
    const askedAt = performance.now();

    Notification.requestPermission().then(permission => {
      const elapsedMs = performance.now() - askedAt;

      if (permission === "granted") {
        this.autoSubscribe();
        this.pushEvent("push_permission_state", { state: "granted" });
      } else if (permission === "denied") {
        // `auto_denied` rides ALONGSIDE the state; it is not a sixth value of
        // it. The server keeps its own assign for it and the blocked row uses
        // it to pick copy. Telling someone in a private window to change
        // site settings sends them to a screen where nothing is wrong.
        this.pushEvent("push_permission_state", {
          state: "denied",
          auto_denied: elapsedMs < AUTO_DENY_THRESHOLD_MS
        });
      } else {
        // Dismissed without choosing, so permission is still "default".
        // Report it as "prompt" to keep the banner up and stay inside the
        // five wire values the server and the banner key on.
        this.pushEvent("push_permission_state", { state: "prompt" });
      }
    });
  },

  autoSubscribe() {
    const hook = this;
    navigator.serviceWorker?.ready.then(reg => {
      reg.pushManager.getSubscription().then(sub => {
        if (sub) {
          hook.sendSubscription(sub);
          return;
        }

        reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(hook.vapidPublicKey)
        }).then(sub => {
          hook.sendSubscription(sub);
        }).catch(err => {
          // Report the failure so it lands in the server log. Permission is
          // already granted at this point, so this is not a denial and must
          // not move push_permission.
          hook.pushEvent("push_subscribe_failed", {
            name: err?.name || "UnknownError",
            message: err?.message || String(err)
          });
        });
      });
    });
  },

  sendSubscription(sub) {
    const subJson = sub.toJSON();
    this.pushEvent("push_subscribed", {
      endpoint: subJson.endpoint,
      keys: {
        p256dh: subJson.keys.p256dh,
        auth: subJson.keys.auth
      }
    });
  }
};

export default PushSubscribe;
