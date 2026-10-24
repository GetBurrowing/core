import { describe, it, expect, afterEach } from "vitest"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import MeetingRoom from "../../js/hooks/meeting_room.js"
import MeetingClient from "../../js/hooks/meeting_client.js"
import {
  isCompanionIdentity,
  participantLabel,
  personIdentity,
  personLabel,
  readParticipantNames,
} from "../../js/hooks/lib/participant_label.js"
import { normalizeIdentities } from "../../js/hooks/lib/active_speakers_debounce.js"

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
    expect(participantLabel({ identity: "user:1", name: "Robin" }, JSON.parse(NAMES))).toBe("Robin")
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
    hook._onTranscription(seg("a"), { identity: "user:1", name: "Robin" })
    hook._onTranscription(seg("b"), { identity: "zzz:stranger" })
    expect(dispatched.map((e) => e.detail.speaker)).toEqual(["Robin", "zzz:stranger"])
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
    hook._ensureTile({ identity: "user:1", name: "Robin", isLocal: false })
    hook._ensureTile({ identity: "zzz:stranger", isLocal: false })
    expect(grid.children.map(tileName)).toEqual(["Burrow", "Robin", "zzz:stranger"])
    expect(grid.children.map((t) => t.dataset.participant)).toEqual([
      "agent-AJ_x",
      "user:1",
      "zzz:stranger",
    ])
  })
})

/**
 * The companion identity table (task 01a13ca2 stage 2).
 *
 * `personIdentity` / `isCompanionIdentity` are the JS twins of
 * `Platform.Meetings.person_identity/1` / `companion_identity?/1`. This
 * test READS the one shared fixture the server suite reads
 * (apps/platform/test/support/fixtures/companion_identities_v1.json), so a
 * prefix rename in one runtime cannot pass while the others still use the
 * old string. It never passes on zero cases: a missing file throws and an
 * empty list fails the count.
 */
const FIXTURE_PATH = fileURLToPath(
  new URL("../../../test/support/fixtures/companion_identities_v1.json", import.meta.url),
)

function loadCompanionFixture() {
  // No try/catch: a missing or unparsable file must fail loudly.
  const fixture = JSON.parse(readFileSync(FIXTURE_PATH, "utf8"))
  return Array.isArray(fixture.cases) ? fixture.cases : []
}

describe("personIdentity / isCompanionIdentity — the shared companion fixture", () => {
  const cases = loadCompanionFixture()

  it("the fixture exists and has cases (never passes on an empty table)", () => {
    expect(cases.length).toBeGreaterThan(0)
  })

  it("every fixture case: person fold and companion predicate agree with the server table", () => {
    expect(cases.length).toBeGreaterThan(0)
    const failures = []
    for (const c of cases) {
      const person = personIdentity(c.identity)
      const companion = isCompanionIdentity(c.identity)
      if (person !== c.person || companion !== c.companion) {
        failures.push({ note: c.note, identity: c.identity, person, companion })
      }
    }
    expect(failures).toEqual([])
  })

  it("covers the stage table: companion, user, agent, guest, agent-AJ_, empty, null", () => {
    const by = (pred) => cases.some(pred)
    expect(by((c) => c.companion === true)).toBe(true)
    expect(by((c) => typeof c.identity === "string" && c.identity.startsWith("user:"))).toBe(true)
    expect(by((c) => typeof c.identity === "string" && c.identity.startsWith("agent:"))).toBe(true)
    expect(by((c) => typeof c.identity === "string" && c.identity.startsWith("guest:"))).toBe(true)
    expect(by((c) => typeof c.identity === "string" && c.identity.startsWith("agent-AJ_"))).toBe(true)
    expect(by((c) => c.identity === "")).toBe(true)
    expect(by((c) => c.identity === null)).toBe(true)
  })

  it("undefined passes through like null, and a non-string is never a companion", () => {
    expect(personIdentity(undefined)).toBe(undefined)
    expect(isCompanionIdentity(undefined)).toBe(false)
    expect(isCompanionIdentity(42)).toBe(false)
  })

  it("a nameless companion is labelled as its person, never video:", () => {
    expect(participantLabel({ identity: "video:user:A" }, { "user:A": "Ada" })).toBe("Ada")
    expect(participantLabel({ identity: "video:user:A" }, {})).toBe("user:A")
    expect(participantLabel({ identity: "video:user:A", name: "Ada" }, {})).toBe("Ada")
  })

  it("the active_speakers payload folds and dedupes a companion onto its person", () => {
    expect(normalizeIdentities(["video:user:A", "user:B", "user:A"])).toEqual(["user:A", "user:B"])
    // No companion: unchanged (sorted, empties dropped).
    expect(normalizeIdentities(["user:B", "", "agent:x"])).toEqual(["agent:x", "user:B"])
  })
})

// Task 01a13ca2 stage 5: the screen-share sharer is attributed by NAME on
// both surfaces. A share published by a nameless companion connection must
// read as its person's name, found through the person's other connection.
describe("personLabel — the sharer's name", () => {
  const room = (...conns) => ({
    localParticipant: conns[0] || null,
    remoteParticipants: new Map(conns.slice(1).map((p) => [p.identity, p])),
  })
  const me = { identity: "user:ME", name: "Mia" }

  it("a named connection keeps its own name", () => {
    expect(personLabel({ identity: "user:W", name: "Wes" }, room(me), {})).toBe("Wes")
  })

  it("a nameless video:user:X share reads as the name X joined with", () => {
    const person = { identity: "user:X", name: "Xavier" }
    const share = { identity: "video:user:X", name: "" }
    expect(personLabel(share, room(me, person, share), {})).toBe("Xavier")
  })

  it("the person's connection may be the LOCAL participant", () => {
    const share = { identity: "video:user:ME", name: "  " }
    expect(personLabel(share, room(me, share), {})).toBe("Mia")
  })

  it("never borrows a name from a DIFFERENT person", () => {
    const other = { identity: "user:Y", name: "Yara" }
    const share = { identity: "video:user:X", name: "" }
    expect(personLabel(share, room(me, other, share), {})).toBe("user:X")
  })

  it("falls back to the server map, then the person identity, never video:", () => {
    const share = { identity: "video:user:X", name: "" }
    expect(personLabel(share, room(me, share), { "user:X": "Xavier" })).toBe("Xavier")
    expect(personLabel(share, null, {})).toBe("user:X")
    expect(personLabel(share, undefined, undefined)).not.toContain("video:")
  })

  it("no participant is an empty label", () => {
    expect(personLabel(null, room(me), {})).toBe("")
  })
})
