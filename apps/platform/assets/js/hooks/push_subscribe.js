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

const PushSubscribe = {
  mounted() {
    // Every exit path below reports a state. Returning silently leaves the
    // server's :push_permission assign at "unknown" forever, which renders
    // neither the opt-in banner nor an unsupported notice.
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
