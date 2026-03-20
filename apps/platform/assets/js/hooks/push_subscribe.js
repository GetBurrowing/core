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

function isIOSSafari() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;
}

const PushSubscribe = {
  mounted() {
    const vapidMeta = document.querySelector("meta[name='vapid-public-key']");
    if (!vapidMeta) return;

    const vapidPublicKey = vapidMeta.getAttribute("content");
    if (!vapidPublicKey) return;

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
      // Default state — need to ask
      if (isIOSSafari()) {
        // iOS requires user gesture — show the prompt button
        this.pushEvent("push_permission_state", { state: "prompt" });
      } else {
        // Desktop browsers can auto-prompt
        this.autoSubscribe();
      }
    }

    // Listen for the user clicking the enable button
    this.handleEvent("request_push_permission", () => {
      this.requestPermission();
    });
  },

  requestPermission() {
    Notification.requestPermission().then(permission => {
      if (permission === "granted") {
        this.autoSubscribe();
        this.pushEvent("push_permission_state", { state: "granted" });
      } else {
        this.pushEvent("push_permission_state", { state: permission });
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
          console.warn("Push subscription failed", err);
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
