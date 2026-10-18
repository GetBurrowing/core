import { describe, it, expect } from "vitest"
import {
  OPEN,
  OTHER,
  YOU,
  chips,
  confirmLine,
  endLine,
  mySlotList,
  nextFree,
  normalizeRoster,
  normalizeSlots,
  padRows,
  peopleCount,
  phoneLine,
  reconcileSlots,
  sheetWatchingText,
  slotLabel,
  takeOverItems,
  watchView,
  watchingText,
  watchingTitle,
} from "../js/hooks/lib/game_stream_roster.js"

/**
 * The multiplayer roster (task 01a0dbd6 stage 4, design canvas
 * 01a0e954-b12f). The strings here are the design's, and the ExUnit render
 * tests in test/platform/chat/canvas/kinds_game_stream_test.exs pin the
 * server's first frame to the same ones.
 */

// core's roster as it arrives over the socket: JSON, so slot keys are strings.
function raw({ slots = {}, spectators = 0, names = [], max = 4, multi = true } = {}) {
  return { slots, spectators, names, max_players: max, multi }
}

const SAM = { peer_id: "p-sam", name: "Sam", user_id: "u1" }
const ALEX = { peer_id: "p-alex", name: "Alex", user_id: "u2" }

describe("normalizeRoster", () => {
  it("reads string slot keys, the caps and the multi flag", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX }, spectators: 2, names: ["Ann", "", "Bo"] }))
    expect(r.multi).toBe(true)
    expect(r.maxPlayers).toBe(4)
    expect(Array.from(r.slots.keys())).toEqual([0, 1])
    expect(r.slots.get(1)).toEqual({ peerId: "p-alex", name: "Alex" })
    expect(r.spectators).toBe(2)
    expect(r.names).toEqual(["Ann", "Bo"])
  })

  it("a v1 host, or nothing at all, is not multi", () => {
    expect(normalizeRoster(raw({ multi: false })).multi).toBe(false)
    expect(normalizeRoster(null)).toMatchObject({ multi: false, maxPlayers: 1, spectators: 0 })
  })
})

describe("chips: the you-marker and no per-player hue", () => {
  it("your chip is YOU, others are OTHER with their name, free slots are OPEN", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX } }))
    expect(chips(r, "p-alex")).toEqual([
      { slot: 0, label: "P1", state: OTHER, name: "Sam", title: "P1 Sam" },
      { slot: 1, label: "P2", state: YOU, name: "You", title: "P2 (you)" },
      { slot: 2, label: "P3", state: OPEN, name: "open", title: "Join as player 3" },
      { slot: 3, label: "P4", state: OPEN, name: "open", title: "Join as player 4" },
    ])
  })

  it("two pads in one browser: both slots are marked yours", () => {
    const r = normalizeRoster(raw({ slots: { 0: ALEX, 1: ALEX } }))
    expect(chips(r, "p-alex").map(c => c.state)).toEqual([YOU, YOU, OPEN, OPEN])
  })

  it("a spectator (no peer yet) sees nobody as itself; a nameless player is Player", () => {
    const r = normalizeRoster(raw({ slots: { 0: { peer_id: "x", name: null } } }))
    expect(chips(r, null)[0]).toMatchObject({ state: OTHER, name: "Player" })
  })

  it("slot labels are P1-P4", () => {
    expect([0, 1, 2, 3].map(slotLabel)).toEqual(["P1", "P2", "P3", "P4"])
  })
})

describe("spectator count: a number, names on hover or tap", () => {
  it("reads '2 watching', with the names as the title and in the sheet", () => {
    const r = normalizeRoster(raw({ spectators: 2, names: ["Ann", "Bo"] }))
    expect(watchingText(r)).toBe("2 watching")
    expect(watchingTitle(r)).toBe("Ann, Bo")
    expect(sheetWatchingText(r)).toBe("2 watching: Ann, Bo")
    expect(sheetWatchingText(normalizeRoster(raw({ spectators: 1 })))).toBe("1 watching")
  })
})

describe("watchView: opening watches", () => {
  const none = new Map()

  it("a spectator with a free slot: 'Watching' and 'Join as player N' for the next free slot", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM } }))
    expect(watchView({ roster: r, mine: none, displaced: null })).toEqual({
      line: "Watching",
      join: { slot: 1, label: "Join as player 2" },
    })
  })

  it("slots full: the design's line and NO Join", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX }, max: 2 }))
    expect(watchView({ roster: r, mine: none, displaced: null })).toEqual({
      line: "All 2 player slots are taken. You are watching.",
      join: null,
    })
    const four = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX, 2: SAM, 3: ALEX } }))
    expect(watchView({ roster: four, mine: none, displaced: null }).line).toBe(
      "All 4 player slots are taken. You are watching.",
    )
  })

  it("displaced: who took which slot, and Join when a slot is free", () => {
    const r = normalizeRoster(raw({ slots: { 0: ALEX } }))
    expect(watchView({ roster: r, mine: none, displaced: { slot: 0, by: "Alex" } })).toEqual({
      line: "Alex took over P1. You are watching.",
      join: { slot: 1, label: "Join as player 2" },
    })
    const full = normalizeRoster(raw({ slots: { 0: ALEX }, max: 1 }))
    expect(watchView({ roster: full, mine: none, displaced: { slot: 0, by: "Alex" } }).join).toBe(null)
  })

  it("a player has no watching row", () => {
    const r = normalizeRoster(raw({ slots: { 1: ALEX } }))
    expect(watchView({ roster: r, mine: new Map([[0, 1]]), displaced: null })).toBe(null)
  })
})

describe("overflow: take over and End session", () => {
  it("one item per slot someone ELSE holds, and a one-line confirm", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX, 2: { peer_id: "p3", name: null } } }))
    const items = takeOverItems(r, "p-alex")
    expect(items).toEqual([
      { slot: 0, label: "Take over P1 from Sam" },
      { slot: 2, label: "Take over P3" },
    ])
    expect(confirmLine(items[0])).toBe("Take over P1 from Sam?")
  })

  it("a spectator may take over any held slot", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM } }))
    expect(takeOverItems(r, "p-spectator")).toEqual([{ slot: 0, label: "Take over P1 from Sam" }])
  })

  it("'Ends the session for N people': each player once, plus every spectator", () => {
    const r = normalizeRoster(raw({ slots: { 0: ALEX, 1: ALEX, 2: SAM }, spectators: 1 }))
    expect(peopleCount(r)).toBe(3)
    expect(endLine(r)).toBe("Ends the session for 3 people")
    expect(endLine(normalizeRoster(raw({ slots: { 0: ALEX } })))).toBe("Ends the session for 1 person")
  })
})

describe("phone line", () => {
  it("'You are P2 · N others playing · N watching'", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX, 2: { peer_id: "p3", name: "C" } }, spectators: 2 }))
    expect(phoneLine({ roster: r, peerId: "p-alex", mine: new Map([[0, 1]]) })).toBe(
      "You are P2 · 2 others playing · 2 watching",
    )
  })

  it("singular other, two slots of your own, and a spectator's line", () => {
    const r = normalizeRoster(raw({ slots: { 0: ALEX, 1: ALEX, 2: SAM }, spectators: 1 }))
    const mine = new Map([
      [0, 0],
      [1, 1],
    ])
    expect(phoneLine({ roster: r, peerId: "p-alex", mine })).toBe("You are P1 and P2 · 1 other playing · 1 watching")
    expect(phoneLine({ roster: r, peerId: "p-spec", mine: new Map() })).toBe("You are watching · 2 playing · 1 watching")
  })
})

describe("pad rows: each pad claims its own slot", () => {
  it("'Pad 1 → P2' for a slotted pad, 'press any button to join as P3' for one without", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX } }))
    const rows = padRows({ pads: [{ src: 0 }, { src: 1 }], mine: new Map([[0, 1]]), roster: r })
    expect(rows.map(x => x.text)).toEqual(["Pad 1 → P2", "Pad 2: press any button to join as P3"])
  })

  it("no free slot for the second pad", () => {
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX }, max: 2 }))
    const rows = padRows({ pads: [{ src: 0 }, { src: 1 }], mine: new Map([[0, 1]]), roster: r })
    expect(rows[1].text).toBe("Pad 2: all player slots are taken")
  })
})

describe("slots: core's {src: slot} and reconciling with the roster", () => {
  it("normalizeSlots reads JSON keys", () => {
    expect(normalizeSlots({ 0: 1, 1: 2, x: 3 })).toEqual(
      new Map([
        [0, 1],
        [1, 2],
      ]),
    )
    expect(normalizeSlots(null).size).toBe(0)
  })

  it("a slot the roster gives someone else is dropped (a take-over); nothing is added", () => {
    const mine = new Map([
      [0, 0],
      [1, 1],
    ])
    const r = normalizeRoster(raw({ slots: { 0: SAM, 1: ALEX, 2: ALEX } }))
    expect(reconcileSlots(mine, r, "p-alex")).toEqual(new Map([[1, 1]]))
    expect(mySlotList(new Map([[1, 2], [0, 0]]))).toEqual([0, 2])
    expect(nextFree(r)).toBe(3)
  })
})
