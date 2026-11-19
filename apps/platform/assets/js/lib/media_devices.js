// media_devices — the shared camera / microphone / speaker layer
// (task 01a1f4c5 stage 1). Pure module: no DOM rendering. Every surface that
// lets a person pick a device (the meeting room, the quickmeet panes, the
// lobby, the top bar, the Voice tab) reads and writes through here, so they
// cannot disagree about which device is in use or what was remembered.
//
// ## What lives here
//
//   * Listing: `listDevices(kind)` wraps livekit's `Room.getLocalDevices(kind,
//     false)` (enumerateDevices, never prompts) and tags each row `virtual` /
//     `default`.
//   * Remembering: the choice is stored through `Suite.ClientState` under the
//     `meeting_devices` namespace, one key per kind, value `{deviceId, label}`.
//     It never reaches the server. Direct localStorage is lint-gated.
//   * Resolving: `resolvePreferred` matches the stored choice by deviceId, then
//     by label (Chrome rotates deviceIds across origins and sessions), then
//     falls back to the `default` entry, then the first one.
//   * The one capability check: `supportsOutputSelection()`.
//   * A room registry. The meeting Room is pinned on `window.__livekit_room`,
//     but the Voice tab owns a SECOND Room that is not, so a device panel has
//     to drive whichever room its surface registered here.
//   * Fallback: `handleDevicesChanged(room)` moves a kind whose active device
//     disappeared onto a working one and says so. livekit's own recovery only
//     restarts an UNMUTED track, and only onto `'default'`: a person who was
//     muted when they unplugged stays bound to a dead device, and nothing
//     tells them. This handler does not look at mute state at all.
//
// ## Events (on `window`)
//
//   meeting:devices-changed  {kind}
//   meeting:active-device    {kind, deviceId, label}
//   meeting:device-fallback  {kind, fromLabel, toLabel}

import { Room, supportsAudioOutputSelection } from "livekit-client"
import ClientState from "../client_state.js"

export const NAMESPACE = "meeting_devices"
export const KINDS = Object.freeze(["audioinput", "videoinput", "audiooutput"])

export const DEVICES_CHANGED_EVENT = "meeting:devices-changed"
export const ACTIVE_DEVICE_EVENT = "meeting:active-device"
export const DEVICE_FALLBACK_EVENT = "meeting:device-fallback"

const VIRTUAL_RE = /BlackHole|Loopback|Soundflower|VB-Audio|Virtual|Krisp|Teams Audio|ZoomAudio/i

// Last list seen per kind, so sync callers (`roomDefaults`, the fallback's
// "from" label) can read it without awaiting enumerateDevices again.
const cache = new Map()
// deviceId -> label for every device ever listed in this tab: the device
// that just disappeared is, by definition, no longer in the current list.
const labels = new Map()
const lastActive = new Map()

function isKind(kind) {
  return KINDS.includes(kind)
}

function emit(name, detail) {
  const w = typeof window !== "undefined" ? window : null
  if (!w || typeof w.dispatchEvent !== "function") return
  try {
    w.dispatchEvent(new CustomEvent(name, { detail }))
  } catch (_err) {
    // A page without CustomEvent has no listener to tell.
  }
}

export function decorate(device) {
  const deviceId = device.deviceId
  const label = device.label || ""
  return {
    deviceId,
    kind: device.kind,
    label,
    groupId: device.groupId,
    virtual: VIRTUAL_RE.test(label),
    default: deviceId === "default",
  }
}

async function enumerate(kind) {
  if (Room && typeof Room.getLocalDevices === "function") {
    return Room.getLocalDevices(kind, false)
  }
  const md = typeof navigator !== "undefined" ? navigator.mediaDevices : null
  if (!md || typeof md.enumerateDevices !== "function") return []
  const all = await md.enumerateDevices()
  return all.filter((d) => d.kind === kind)
}

// Devices of `kind` with a label. Before permission is granted every label
// is empty and every deviceId is blank or shared, so those rows say nothing
// a person could choose between: they are dropped.
export async function listDevices(kind) {
  if (!isKind(kind)) return []
  let raw = []
  try {
    raw = (await enumerate(kind)) || []
  } catch (_err) {
    raw = []
  }
  const devices = raw
    .filter((d) => d && d.label && (!d.kind || d.kind === kind))
    .map((d) => decorate({ ...d, kind: d.kind || kind }))
  for (const d of devices) labels.set(d.deviceId, d.label)
  cache.set(kind, devices)
  return devices
}

export function cachedDevices(kind) {
  return cache.get(kind) || []
}

export function labelFor(deviceId) {
  return labels.get(deviceId) || ""
}

// Middle truncation (stage 2): device names differ at the END ("Logitech
// BRIO 2" vs "Logitech BRIO 4K", "Microphone Array (Realtek USB)"), so the
// tail survives and the cut goes in the middle. `maxChars` counts the
// ellipsis. The tail gets the larger half.
export function truncateMiddle(label, maxChars) {
  const text = String(label == null ? "" : label)
  const max = Math.floor(Number(maxChars))
  if (!Number.isFinite(max) || max <= 0 || text.length <= max) return text
  if (max === 1) return "\u2026"
  const keep = max - 1
  const head = Math.floor(keep / 2)
  const tail = keep - head
  return text.slice(0, head).trimEnd() + "\u2026" + text.slice(text.length - tail).trimStart()
}

// ── preference store ───────────────────────────────────────────────────

export function getPreference(kind) {
  if (!isKind(kind)) return null
  const value = ClientState.get(NAMESPACE, kind, null)
  if (!value || typeof value !== "object" || typeof value.deviceId !== "string") return null
  return { deviceId: value.deviceId, label: typeof value.label === "string" ? value.label : "" }
}

export function setPreference(kind, { deviceId, label = "" }) {
  if (!isKind(kind) || typeof deviceId !== "string" || deviceId === "") return
  ClientState.set(NAMESPACE, kind, { deviceId, label })
}

// `{device, substituted}`. `substituted` is true only when a preference was
// stored and neither its deviceId nor its label is present: it is what the
// lobby's "Your usual microphone isn't connected." line reads.
export function resolvePreferred(kind, devices = cachedDevices(kind)) {
  const list = (devices || []).filter((d) => d && (!d.kind || d.kind === kind))
  const pref = getPreference(kind)
  if (pref) {
    const byId = list.find((d) => d.deviceId === pref.deviceId)
    if (byId) return { device: byId, substituted: false }
    if (pref.label) {
      const byLabel = list.find((d) => d.label === pref.label)
      if (byLabel) return { device: byLabel, substituted: false }
    }
  }
  const device = list.find((d) => d.deviceId === "default") || list[0] || null
  return { device, substituted: !!pref }
}

// The deviceId a capture or output should START on, or null for "let the
// browser choose". Only a stored preference produces one: without a choice
// on record the browser default stays exactly what it was before this layer.
export function preferredDeviceId(kind, devices = cachedDevices(kind)) {
  const pref = getPreference(kind)
  if (!pref) return null
  const { device } = resolvePreferred(kind, devices)
  // No list yet (no permission, or not enumerated): the stored id is still
  // the best guess, and a NON-exact constraint never fails on it.
  return device ? device.deviceId : pref.deviceId
}

// The one capability check every surface uses. False in Safari, Firefox and
// WKWebView. livekit's own check dereferences `document`, so anywhere it
// throws the answer is no.
export function supportsOutputSelection() {
  try {
    return supportsAudioOutputSelection() === true
  } catch (_err) {
    return false
  }
}

// Room options carrying the preferred devices. NON-exact deviceIds, so a
// missing device never fails a join: the browser picks another.
export function roomDefaults({ audio = true, video = true, output = true } = {}) {
  const opts = {}
  const mic = audio ? preferredDeviceId("audioinput") : null
  if (mic) opts.audioCaptureDefaults = { deviceId: mic }
  const cam = video ? preferredDeviceId("videoinput") : null
  if (cam) opts.videoCaptureDefaults = { deviceId: cam }
  if (output && supportsOutputSelection()) {
    const out = preferredDeviceId("audiooutput")
    if (out) opts.audioOutput = { deviceId: out }
  }
  return opts
}

// Refresh every kind's cache (best effort, never prompts). Callers await it
// before building a Room so the label match in `preferredDeviceId` has data.
export async function refreshDevices() {
  await Promise.all(KINDS.map((kind) => listDevices(kind)))
}

// The device to move to when `lostId` disappeared: the `default` entry if it
// is not the lost one, else the first remaining. Never `lostId`.
export function fallbackFor(kind, lostId, devices = cachedDevices(kind)) {
  const rest = (devices || []).filter(
    (d) => d && d.deviceId !== lostId && (!d.kind || d.kind === kind),
  )
  return rest.find((d) => d.deviceId === "default") || rest[0] || null
}

// ── room registry ──────────────────────────────────────────────────────

const registry = []

export function registerRoom(room, surface = "meeting") {
  if (!room) return null
  unregisterRoom(room)
  registry.push({ room, surface })
  return room
}

export function unregisterRoom(room) {
  const i = registry.findIndex((entry) => entry.room === room)
  if (i >= 0) registry.splice(i, 1)
}

// The most recently registered room, or the one registered for `surface`.
export function activeRoom(surface) {
  for (let i = registry.length - 1; i >= 0; i--) {
    if (!surface || registry[i].surface === surface) return registry[i].room
  }
  return null
}

// The surface a room was registered for, or null.
export function surfaceOf(room) {
  const entry = registry.find((e) => e.room === room)
  return entry ? entry.surface : null
}

export function registeredRooms() {
  return registry.map((entry) => ({ ...entry }))
}

// ── switching ──────────────────────────────────────────────────────────

// Announce the device a kind is on. Consecutive duplicates are dropped (the
// Room's ActiveDeviceChanged and selectDevice can both report one switch)
// unless `force`.
export function announceActiveDevice(kind, deviceId, { force = false } = {}) {
  if (!isKind(kind)) return
  if (!force && lastActive.get(kind) === deviceId) return
  lastActive.set(kind, deviceId)
  emit(ACTIVE_DEVICE_EVENT, { kind, deviceId: deviceId || null, label: labelFor(deviceId) })
}

// Pick `deviceId` for `kind`. With a registered room it switches live
// (`switchActiveDevice(kind, id, true)`: exact, because the person picked
// THAT device), and persists only if the switch worked. Without a room it
// only persists, and the next Room / preview starts on it.
//
// `{ok: true}` or `{ok: false, error, deviceId}` where `deviceId` is what
// the room is really on after the failure.
export async function selectDevice(kind, deviceId, { room = activeRoom() } = {}) {
  if (!isKind(kind)) return { ok: false, error: new Error(`unknown device kind ${kind}`) }
  if (typeof deviceId !== "string" || deviceId === "") {
    return { ok: false, error: new Error("no deviceId") }
  }
  if (!labels.has(deviceId)) await listDevices(kind)
  const label = labelFor(deviceId)

  if (room && typeof room.switchActiveDevice === "function") {
    try {
      const switched = await room.switchActiveDevice(kind, deviceId, true)
      if (switched === false) throw new Error(`could not switch ${kind} to ${deviceId}`)
    } catch (error) {
      const current =
        typeof room.getActiveDevice === "function" ? room.getActiveDevice(kind) : undefined
      announceActiveDevice(kind, current, { force: true })
      return { ok: false, error, deviceId: current }
    }
  }

  setPreference(kind, { deviceId, label })
  announceActiveDevice(kind, deviceId)
  return { ok: true }
}

// RoomEvent.MediaDevicesChanged: re-list every kind, and move any kind whose
// active device is gone onto `fallbackFor`. Deliberately blind to mute: the
// muted-at-unplug person is the case livekit leaves on a dead device.
export async function handleDevicesChanged(room, { kinds = KINDS } = {}) {
  const moved = []
  for (const kind of kinds) {
    if (kind === "audiooutput" && !supportsOutputSelection()) continue
    const devices = await listDevices(kind)
    emit(DEVICES_CHANGED_EVENT, { kind })
    if (!room || typeof room.getActiveDevice !== "function") continue
    if (devices.length === 0) continue
    const active = room.getActiveDevice(kind)
    if (!active || devices.some((d) => d.deviceId === active)) continue

    const target = fallbackFor(kind, active, devices)
    if (!target) continue
    const fromLabel = labelFor(active)
    try {
      await room.switchActiveDevice(kind, target.deviceId)
    } catch (err) {
      console.warn(`[media_devices] fallback for ${kind} failed`, err && err.message)
      continue
    }
    announceActiveDevice(kind, target.deviceId)
    // `surface` lets a panel ignore a fallback in a room it does not drive
    // (the Voice tab's room is not the meeting's; task 01a1f4c5 stage 4).
    const surface = surfaceOf(room)
    emit(DEVICE_FALLBACK_EVENT, {
      kind,
      fromLabel,
      toLabel: target.label,
      ...(surface ? { surface } : {}),
    })
    moved.push({ kind, from: active, to: target.deviceId })
  }
  return moved
}

// For surfaces with no Room (the lobby, the Voice tab before its first
// press): one `devicechange` subscription for the whole tab. With a Room the
// MeetingClient rides `RoomEvent.MediaDevicesChanged` instead.
let watching = null

export function watchDevices() {
  if (watching) return watching
  const md = typeof navigator !== "undefined" ? navigator.mediaDevices : null
  if (!md || typeof md.addEventListener !== "function") return null
  const onChange = () => {
    // A registered room's own MediaDevicesChanged does the fallback.
    if (activeRoom()) return
    for (const kind of KINDS) {
      listDevices(kind).then(() => emit(DEVICES_CHANGED_EVENT, { kind }))
    }
  }
  md.addEventListener("devicechange", onChange)
  watching = {
    stop() {
      md.removeEventListener("devicechange", onChange)
      watching = null
    },
  }
  return watching
}

// Test-only reset, mirroring client_state.js.
export function __resetForTests() {
  cache.clear()
  labels.clear()
  lastActive.clear()
  registry.length = 0
  if (watching) watching.stop()
}
