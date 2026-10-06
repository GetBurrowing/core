import type { CapacitorConfig } from "@capacitor/cli";

// No server.url: the shell boots the bundled www/index.html, and
// MainActivity then loads the install the person picked. A static
// server.url would pin every tester to one install (same reason as
// clients/ios/capacitor.config.ts).
const config: CapacitorConfig = {
  appId: "com.koboai.burrow",
  appName: "Burrow",
  webDir: "www",
  // Capacitor's native Logger prints plugin call data and URLs; nothing in
  // this app may reach Logcat that could carry a token or a login code.
  loggingBehavior: "none",
  android: {
    allowMixedContent: false,
  },
};

export default config;
