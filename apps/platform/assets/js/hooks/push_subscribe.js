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

const PushSubscribe = {
  mounted() {
    const vapidMeta = document.querySelector("meta[name='vapid-public-key']");
    if (!vapidMeta) return;

    const vapidPublicKey = vapidMeta.getAttribute("content");
    if (!vapidPublicKey) return;

    const hook = this;

    navigator.serviceWorker?.ready.then(reg => {
      reg.pushManager.getSubscription().then(sub => {
        if (sub) {
          hook.pushSubscription(sub);
          return;
        }

        reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(vapidPublicKey)
        }).then(sub => {
          hook.pushSubscription(sub);
        }).catch(err => {
          console.warn("Push subscription failed", err);
        });
      });
    });
  },

  pushSubscription(sub) {
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
