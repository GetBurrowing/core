import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

/**
 * CONTRACT SOURCE SCAN, web side (task 01a20dc5 stage 3). The on-device
 * Voice path is two clients agreeing on a few strings: the plugin's jsName
 * (`BurrowVoice`), its methods and its listener events. This reads the
 * Swift plugin and, since task 01a21e4a stage 4, the Android (Kotlin) one,
 * and fails when the web calls a method or listens for an event EITHER plugin
 * does not declare, or when the two plugins' sets differ. The iOS mirror is
 * clients/ios/ios/App/AppTests/BurrowVoiceContractTests.swift, which reads
 * these JS files from the iOS CI run. It lives here for Android because the
 * Android build rig syncs only clients/android, so a JVM test cannot read the
 * web code; the Kotlin side pins its own lists in BurrowVoiceMethodsTest.kt.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../../..")
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8")

const pluginSwift = read("clients/ios/ios/App/App/Plugins/BurrowVoicePlugin.swift")
const pluginKotlin = read("clients/android/android/app/src/main/java/com/koboai/burrow/voice/BurrowVoicePlugin.kt")
// The hook is two files: voice_tab.js (in app.js) and its on-device half,
// voice_tab_native_runtime.js (the voice_native island).
const hookJs =
  read("apps/platform/assets/js/hooks/voice_tab.js") + read("apps/platform/assets/js/hooks/voice_tab_native_runtime.js")
const libJs = read("apps/platform/assets/js/lib/on_device_voice.js")

const all = (src, re) => Array.from(src.matchAll(re), (m) => m[1])

const swiftMethods = new Set(all(pluginSwift, /CAPPluginMethod\(name: "(\w+)", returnType: CAPPluginReturnPromise\)/g))
const swiftEvents = new Set(
  JSON.parse(pluginSwift.match(/static let events = (\[[^\]]*\])/)[1]),
)
// Kotlin: `@PluginMethod fun <name>(` and `val EVENTS = listOf("a", "b")`.
const kotlinMethods = new Set(all(pluginKotlin, /@PluginMethod\s+fun\s+(\w+)\s*\(/g))
const kotlinEvents = new Set(all(pluginKotlin.match(/val EVENTS = listOf\(([^)]*)\)/)[1], /"(\w+)"/g))

// Every way the web reaches the plugin: `plugin.x(`, `cap.plugin.x(`,
// `this._native.x(` and `this._nativeCall("x"`.
const usedMethods = new Set([
  ...all(hookJs + libJs, /\bplugin\.(\w+)\(/g),
  ...all(hookJs, /this\._native\.(\w+)\(/g),
  ...all(hookJs, /_nativeCall\("(\w+)"/g),
])
const usedEvents = new Set(all(hookJs, /\bon\("(\w+)"/g))

describe("on-device voice contract: BurrowVoicePlugin.swift vs the web", () => {
  it("the web looks the plugin up by its jsName", () => {
    const jsName = pluginSwift.match(/jsName = "(\w+)"/)[1]
    expect(jsName).toBe("BurrowVoice")
    expect(libJs).toContain(`cap.Plugins && cap.Plugins.${jsName}`)
  })

  it("the scan found the calls it is meant to check", () => {
    for (const m of [
      "capabilities", "prepare", "start", "stop", "cancel", "speak", "stopSpeaking", "openSettings", "voices",
      // Pocket TTS (task 01a20fdd stage 3).
      "speakPart", "prepareModel",
    ]) {
      expect(usedMethods, m).toContain(m)
    }
    for (const e of ["partial", "ended", "speech", "route", "model"]) expect(usedEvents, e).toContain(e)
  })

  it("every method the web calls is a promise method the plugin registers, with an @objc body", () => {
    for (const m of usedMethods) {
      if (m === "addListener") continue // Capacitor's own, on every plugin
      expect(swiftMethods, `${m} is not registered`).toContain(m)
      expect(pluginSwift).toMatch(new RegExp(`@objc func ${m}\\(_ call: CAPPluginCall\\)`))
    }
  })

  it("every event the web listens for is one the plugin sends", () => {
    for (const e of usedEvents) expect(swiftEvents, `${e} is not sent`).toContain(e)
  })

  it("the capabilities keys the web reads are the ones the plugin resolves", () => {
    for (const key of ["onDeviceSpeech", "reason", "locale", "testBuild", "micPermission"]) {
      expect(pluginSwift).toContain(`"${key}":`)
      expect(libJs).toContain(`caps.${key}`)
    }
    // start() resolves {started, reason}; stop() resolves {text}.
    expect(pluginSwift).toContain('["started": false, "reason": reason]')
    expect(pluginSwift).toContain('["started": true')
    expect(hookJs).toContain("result.started !== true")
    expect(pluginSwift).toContain('return ["text": text]')
    expect(hookJs).toContain("r.text")
  })
})

describe("on-device voice contract: BurrowVoicePlugin.kt (Android) vs the web and the Swift plugin", () => {
  it("the Android plugin is BurrowVoice too", () => {
    expect(pluginKotlin).toMatch(/@CapacitorPlugin\(\s*name = "BurrowVoice"/)
  })

  it("the scan found the Kotlin declarations", () => {
    expect(kotlinMethods.size).toBeGreaterThanOrEqual(11)
    expect(kotlinEvents.size).toBeGreaterThanOrEqual(6)
  })

  it("every method the web calls is a @PluginMethod of the Android plugin", () => {
    for (const m of usedMethods) {
      if (m === "addListener") continue // Capacitor's own, on every plugin
      expect(kotlinMethods, `${m} is not a @PluginMethod in BurrowVoicePlugin.kt`).toContain(m)
    }
  })

  it("every event the web listens for is one the Android plugin sends", () => {
    for (const e of usedEvents) {
      expect(kotlinEvents, `${e} is not in EVENTS`).toContain(e)
      expect(pluginKotlin).toContain(`emit("${e}"`)
    }
  })

  it("the Kotlin and Swift plugins declare the same methods and events", () => {
    expect([...kotlinMethods].sort()).toEqual([...swiftMethods].sort())
    expect([...kotlinEvents].sort()).toEqual([...swiftEvents].sort())
  })

  it("the capabilities keys the web reads are ones the Android plugin resolves", () => {
    for (const key of ["onDeviceSpeech", "reason", "locale", "testBuild", "micPermission"]) {
      expect(pluginKotlin).toContain(`.put("${key}"`)
    }
    expect(pluginKotlin).toContain('.put("started", false).put("reason", reason)')
    expect(pluginKotlin).toContain('.put("started", true)')
    expect(pluginKotlin).toContain('JSObject().put("text", text)')
  })
})
