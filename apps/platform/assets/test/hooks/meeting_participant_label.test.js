import { describe, it, expect, afterEach } from "vitest"
import MeetingRoom from "../../js/hooks/meeting_room.js"
import MeetingClient from "../../js/hooks/meeting_client.js"
import { participantLabel, readParticipantNames } from "../../js/hooks/lib/participant_label.js"

/**
 * Participant labels on the transcript pane and quick-meet tiles
 * (task 01a1117f stage 5).
 *
 * A legacy voice worker joins LiveKit as `agent-AJ_…` with no name. Core
 * folds it onto Burrow and renders `data-participant-names` on the hook
 * element. The label order is: LiveKit name, then that map, then identity.
 */

const NAMES = JSON.stringify({
  "agent-AJ_x": "Burrow",
  "agent:01a1-burrow": "Burrow",
})

afterEach(() => {
  delete globalThis.document
})

describe("participantLabel", () => {
  it("a legacy unnamed agent-AJ_ participant in the map is labelled Burrow", () => {
    expect(participantLabel({ identity: "agent-AJ_x", name: "" }, JSON.parse(NAMES))).toBe("Burrow")
    expect(participantLabel({ identity: "agent-AJ_x" }, JSON.parse(NAMES))).toBe("Burrow")
  })

  it("a named participant keeps its own name, even when the map disagrees", () => {
    expect(participantLabel({ identity: "agent-AJ_x", name: "Other" }, JSON.parse(NAMES))).toBe("Other")
    expect(participantLabel({ identity: "user:1", name: "Marlowe" }, JSON.parse(NAMES))).toBe("Marlowe")
  })

  it("an unmapped zzz: participant keeps the identity fallback", () => {
    expect(participantLabel({ identity: "zzz:stranger" }, JSON.parse(NAMES))).toBe("zzz:stranger")
  })

  it("a missing or malformed attribute reads as an empty map", () => {
    for (const raw of [undefined, "", "not json", "[1,2]", "null", "7"]) {
      const el = { dataset: raw === undefined ? {} : { participantNames: raw } }
      expect(readParticipantNames(el)).toEqual({})
    }
    expect(readParticipantNames(null)).toEqual({})
  })
})

describe("MeetingRoom._onTranscription labels", () => {
  function harness(names = NAMES) {
    const dispatched = []
    globalThis.document = {
      dispatchEvent(event) {
        dispatched.push(event)
        return true
      },
    }
    const hook = Object.create(MeetingRoom)
    hook.el = { dataset: names === null ? {} : { participantNames: names } }
    return { hook, dispatched }
  }

  const seg = (text) => [{ id: `s-${text}`, text, final: true, startTime: 1 }]

  it("labels a legacy agent-AJ_ caption Burrow and keeps its identity", () => {
    const { hook, dispatched } = harness()
    hook._onTranscription(seg("hello"), { identity: "agent-AJ_x" })
    expect(dispatched[0].type).toBe("meeting:caption")
    expect(dispatched[0].detail.speaker).toBe("Burrow")
    expect(dispatched[0].detail.identity).toBe("agent-AJ_x")
  })

  it("a named participant keeps its name; an unmapped one keeps its identity", () => {
    const { hook, dispatched } = harness()
    hook._onTranscription(seg("a"), { identity: "user:1", name: "Marlowe" })
    hook._onTranscription(seg("b"), { identity: "zzz:stranger" })
    expect(dispatched.map((e) => e.detail.speaker)).toEqual(["Marlowe", "zzz:stranger"])
  })

  it("re-reads the attribute on every event (no caching)", () => {
    const { hook, dispatched } = harness(null)
    hook._onTranscription(seg("a"), { identity: "agent-AJ_x" })
    hook.el.dataset.participantNames = NAMES
    hook._onTranscription(seg("b"), { identity: "agent-AJ_x" })
    expect(dispatched.map((e) => e.detail.speaker)).toEqual(["agent-AJ_x", "Burrow"])
  })

  it("no participant at all still reads Unknown", () => {
    const { hook, dispatched } = harness()
    hook._onTranscription(seg("a"), undefined)
    expect(dispatched[0].detail.speaker).toBe("Unknown")
  })
})

describe("MeetingClient._ensureTile labels (quick-meet)", () => {
  function node() {
    return {
      dataset: {},
      children: [],
      className: "",
      textContent: "",
      appendChild(child) {
        this.children.push(child)
        return child
      },
    }
  }

  function harness(names = NAMES) {
    globalThis.document = { createElement: () => node() }
    const grid = node()
    const hook = Object.create(MeetingClient)
    hook.el = { dataset: { participantNames: names } }
    hook._tiles = new Map()
    hook._grid = () => grid
    return { hook, grid }
  }

  const tileName = (tile) => tile.children.find((c) => c.className === "meeting-tile-name").textContent

  it("names a legacy unnamed agent-AJ_ tile Burrow, a human by name, an unmapped one by identity", () => {
    const { hook, grid } = harness()
    hook._ensureTile({ identity: "agent-AJ_x", name: "", isLocal: false })
    hook._ensureTile({ identity: "user:1", name: "Marlowe", isLocal: false })
    hook._ensureTile({ identity: "zzz:stranger", isLocal: false })
    expect(grid.children.map(tileName)).toEqual(["Burrow", "Marlowe", "zzz:stranger"])
    expect(grid.children.map((t) => t.dataset.participant)).toEqual([
      "agent-AJ_x",
      "user:1",
      "zzz:stranger",
    ])
  })
})
