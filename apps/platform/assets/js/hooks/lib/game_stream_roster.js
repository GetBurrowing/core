/**
 * The multiplayer roster of a `game_stream` canvas (task 01a0dbd6 stage 4,
 * design canvas 01a0e954-b12f). Pure, so the words and the you-marker are
 * tested without a browser; the hook (`../game_stream.js`) only applies what
 * these functions return.
 *
 * Inputs:
 *   - `roster`, from `normalizeRoster/1` of core's roster
 *     (`Platform.GameStream.Session` `roster/1`): `slots` (slot to
 *     `{peerId, name}`), `spectators` (a count), `names` (the spectators'
 *     names, for hover or tap), `maxPlayers`, and `multi` (the host declares
 *     `game_stream_multi`; a v1 host shows none of this);
 *   - `peerId`, the peer this LiveView owns;
 *   - `mine`, this peer's `Map(src -> slot)` (`normalizeSlots/1`).
 *
 * The words are the design canvas's. The server renders the same words for
 * the first frame (`Platform.Chat.Canvas.Kinds.GameStream`), and the ExUnit
 * render tests pin them to the same strings these tests pin.
 *
 * Per the design, slots carry NO per-player hue: your own chips are the
 * primary fill, everyone else's are neutral, and an open slot is dashed.
 */

export const YOU = "you"
export const OTHER = "other"
export const OPEN = "open"

function nonNegInt(v) {
  const n = Number(v)
  return Number.isInteger(n) && n >= 0 ? n : null
}

/** "P1" for slot 0. */
export function slotLabel(slot) {
  return `P${slot + 1}`
}

/** core's roster message (string or integer slot keys) as a plain shape. */
export function normalizeRoster(raw) {
  const r = raw || {}
  const slots = new Map()
  for (const [k, v] of Object.entries(r.slots || {})) {
    const slot = nonNegInt(k)
    if (slot == null || !v) continue
    slots.set(slot, { peerId: v.peer_id == null ? null : v.peer_id, name: typeof v.name === "string" ? v.name : null })
  }
  const highest = slots.size ? Math.max(...slots.keys()) + 1 : 1
  const max = nonNegInt(r.max_players)
  return {
    multi: r.multi === true,
    maxPlayers: max && max > 0 ? Math.max(max, highest) : highest,
    slots,
    spectators: nonNegInt(r.spectators) || 0,
    names: Array.isArray(r.names) ? r.names.filter(n => typeof n === "string" && n !== "") : [],
  }
}

/** core's `{src: slot}` for this peer as a Map. */
export function normalizeSlots(raw) {
  const out = new Map()
  const entries = raw instanceof Map ? raw.entries() : Object.entries(raw || {})
  for (const [k, v] of entries) {
    const src = nonNegInt(k)
    const slot = nonNegInt(v)
    if (src != null && slot != null) out.set(src, slot)
  }
  return out
}

/**
 * `mine` with every slot the roster no longer gives this peer dropped (a
 * take-over moved it). The roster is the truth about who holds a slot; the
 * src a slot belongs to only comes from core's replies, so nothing is added.
 */
export function reconcileSlots(mine, roster, peerId) {
  const out = new Map()
  for (const [src, slot] of mine) {
    const holder = roster.slots.get(slot)
    if (holder && holder.peerId === peerId) out.set(src, slot)
  }
  return out
}

/** This peer's slots, ascending. */
export function mySlotList(mine) {
  return Array.from(new Set(mine.values())).sort((a, b) => a - b)
}

/** The lowest free slot, or null when all are taken. */
export function nextFree(roster) {
  for (let s = 0; s < roster.maxPlayers; s++) if (!roster.slots.has(s)) return s
  return null
}

/** One chip per slot: `{slot, label, state, name, title}`. */
export function chips(roster, peerId) {
  const out = []
  for (let slot = 0; slot < roster.maxPlayers; slot++) {
    const label = slotLabel(slot)
    const holder = roster.slots.get(slot)
    if (!holder) {
      out.push({ slot, label, state: OPEN, name: "open", title: `Join as player ${slot + 1}` })
    } else if (peerId != null && holder.peerId === peerId) {
      out.push({ slot, label, state: YOU, name: "You", title: `${label} (you)` })
    } else {
      const name = holder.name || "Player"
      out.push({ slot, label, state: OTHER, name, title: `${label} ${name}` })
    }
  }
  return out
}

/** "2 watching". */
export function watchingText(roster) {
  return `${roster.spectators} watching`
}

/** The spectators' names, shown on hover (and listed in the phone sheet). */
export function watchingTitle(roster) {
  return roster.names.join(", ")
}

function playerPeers(roster) {
  return new Set(Array.from(roster.slots.values(), h => h.peerId))
}

/** Everyone attached: each player peer once, plus every spectator. */
export function peopleCount(roster) {
  return playerPeers(roster).size + roster.spectators
}

/** The End session line in the overflow menu. */
export function endLine(roster) {
  const n = peopleCount(roster)
  return n === 1 ? "Ends the session for 1 person" : `Ends the session for ${n} people`
}

/** Overflow items: one per slot someone ELSE holds. */
export function takeOverItems(roster, peerId) {
  const out = []
  for (const [slot, holder] of Array.from(roster.slots).sort((a, b) => a[0] - b[0])) {
    if (peerId != null && holder.peerId === peerId) continue
    const label = holder.name ? `Take over ${slotLabel(slot)} from ${holder.name}` : `Take over ${slotLabel(slot)}`
    out.push({ slot, label })
  }
  return out
}

/** The one-line confirm for a take-over item. */
export function confirmLine(item) {
  return `${item.label}?`
}

/**
 * The footer's watching row for a spectator, or null for a player: `{line,
 * join}` where `join` is `{slot, label}` or null when every slot is taken.
 * `displaced` (`{slot, by}`) is set after someone took this peer's slot.
 */
export function watchView({ roster, mine, displaced }) {
  if (mine.size > 0) return null
  const free = nextFree(roster)
  let line
  if (displaced) line = `${displaced.by || "Someone"} took over ${slotLabel(displaced.slot)}. You are watching.`
  else if (free == null) line = `All ${roster.maxPlayers} player slots are taken. You are watching.`
  else line = "Watching"
  return { line, join: free == null ? null : { slot: free, label: `Join as player ${free + 1}` } }
}

function listLabels(slots) {
  const labels = slots.map(slotLabel)
  if (labels.length <= 1) return labels.join("")
  return `${labels.slice(0, -1).join(", ")} and ${labels[labels.length - 1]}`
}

/** The phone's one-line roster: "You are P2 · 2 others playing · 2 watching". */
export function phoneLine({ roster, peerId, mine }) {
  const slots = mySlotList(mine)
  const players = playerPeers(roster)
  const watching = `${roster.spectators} watching`
  if (slots.length > 0) {
    const others = Array.from(players).filter(p => p !== peerId).length
    return `You are ${listLabels(slots)} · ${others} ${others === 1 ? "other" : "others"} playing · ${watching}`
  }
  return `You are watching · ${players.size} playing · ${watching}`
}

/**
 * The footer's pad rows for a player: one per detected pad (`{src, pad}`),
 * "Pad 1 → P2", or for a pad with no slot "Pad 2: press any button to join
 * as P3" (or "Pad 2: all player slots are taken").
 */
export function padRows({ pads, mine, roster }) {
  const free = nextFree(roster)
  return pads.map(({ src }) => {
    const n = src + 1
    if (mine.has(src)) return { src, slot: mine.get(src), text: `Pad ${n} → ${slotLabel(mine.get(src))}` }
    if (free == null) return { src, slot: null, text: `Pad ${n}: all player slots are taken` }
    return { src, slot: null, text: `Pad ${n}: press any button to join as ${slotLabel(free)}` }
  })
}

/** The phone sheet's spectator line: "2 watching: Ann, Bob". */
export function sheetWatchingText(roster) {
  const names = watchingTitle(roster)
  return names ? `${watchingText(roster)}: ${names}` : watchingText(roster)
}
