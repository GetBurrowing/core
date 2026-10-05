import type { CapacitorConfig } from "@capacitor/cli";

// No server.url: the shell boots the bundled www/index.html, and
// SuiteBridgeViewController then loads the install the person picked.
// A static server.url would pin every tester to one install.
const config: CapacitorConfig = {
  appId: "com.kobo-ai.burrow",
  appName: "Burrow",
  webDir: "www",
  ios: {
    contentInset: "never",
    scheme: "Suite",
    // Capacitor's bridge would otherwise make its own CAPNotificationRouter
    // the UNUserNotificationCenter delegate, replacing NotificationRouter.shared
    // (AppDelegate), so Reply, Open and a tap would never reach the shell.
    handleApplicationNotifications: false,
  },
};

export default config;
