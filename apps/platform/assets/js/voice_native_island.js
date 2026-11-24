// Entry point of the `voice_native` esbuild profile: the Voice tab's
// on-device half, fetched by voice_tab.js only inside the iOS app.
import VoiceTabNative from "./hooks/voice_tab_native_runtime"
window.__burrowVoiceNative = VoiceTabNative
