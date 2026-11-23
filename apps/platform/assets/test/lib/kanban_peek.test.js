import { describe, it, expect, vi } from "vitest"
import { leadPadding, cutLane, installKanbanPeek, LEAD_VAR, DEFAULTS } from "../../js/lib/kanban_peek.js"
import { DUO_ATTR, DUO_OPEN_ATTR } from "../../js/lib/duo_more_page.js"
import { DUO_POSTURE_EVENT } from "../../js/hooks/native_back.js"
import KanbanDragDrop from "../../js/hooks/kanban_drag_drop.js"

/**
 * Kanban peek on the open iPhone Duo (task 01a20937 stage 2). vitest runs in
 * plain node, so window, document and the board are fakes, as in
 * duo_more_page.test.js. Seven lanes is the board's real column count.
 */

const LANES = 7
const peek = (w) => cutLane(w, leadPadding(w, { lanes: LANES }), { lanes: LANES })

describe("leadPadding", () => {
  it("669 (portrait): base lead, the third lane shows 53px", () => {
    expect(leadPadding(669, { lanes: LANES })).toBe(16)
    expect(peek(669)).toEqual({ index: 2, shown: 53, hidden: 235 })
  })

  it("951 (landscape): base lead, the fourth lane shows 35px", () => {
    expect(leadPadding(951, { lanes: LANES })).toBe(16)
    expect(peek(951)).toEqual({ index: 3, shown: 35, hidden: 253 })
  })

  it("930: a 14px sliver with the base lead, so the lead widens until the last full lane hangs 32px over the edge", () => {
    expect(cutLane(930, 16, { lanes: LANES }).shown).toBe(14)
    const lead = leadPadding(930, { lanes: LANES })
    expect(lead).toBeGreaterThan(16)
    const cut = cutLane(930, lead, { lanes: LANES })
    expect(cut.shown).toBeGreaterThanOrEqual(DEFAULTS.minPeek)
    expect(cut.hidden).toBeGreaterThanOrEqual(DEFAULTS.minPeek)
    expect(lead).toBe(16 + 12 + 14 + 32)
  })

  it("every width from 640 to 1024 leaves a lane at least 32px shown and 32px hidden, or keeps the base lead with most of a lane shown", () => {
    for (let w = 640; w <= 1024; w++) {
      const lead = leadPadding(w, { lanes: LANES })
      const cut = cutLane(w, lead, { lanes: LANES })
      expect(cut, `width ${w}`).not.toBeNull()
      expect(cut.shown, `width ${w}`).toBeGreaterThanOrEqual(32)
      if (lead !== 16) expect(cut.hidden, `width ${w}`).toBeGreaterThanOrEqual(32)
    }
  })

  it("all lanes fit: base lead, nothing cut", () => {
    expect(leadPadding(1000, { lanes: 3 })).toBe(16)
    expect(cutLane(1000, 16, { lanes: 3 })).toBeNull()
    // 3 lanes need 16 + 3*288 + 2*12 + 16 = 920.
    expect(leadPadding(920, { lanes: 3 })).toBe(16)
  })

  it("no width, or less than one lane: base lead", () => {
    expect(leadPadding(0, { lanes: LANES })).toBe(16)
    expect(leadPadding(300, { lanes: LANES })).toBe(16)
  })
})

function fakeBoard(width = 930, lanes = LANES) {
  const props = new Map()
  const listeners = []
  const board = {}
  const laneEls = Array.from({ length: lanes }, (_, i) => ({
    getBoundingClientRect: () => {
      const left = 16 + i * 300 - board.scrollLeft
      return { left, right: left + 288, width: 288 }
    },
    scrollIntoView: vi.fn(),
  }))
  return Object.assign(board, {
    getBoundingClientRect: () => ({ left: 0, right: board.clientWidth }),
    clientWidth: width,
    scrollLeft: 0,
    dataset: {},
    style: {
      setProperty: (k, v) => props.set(k, v),
      removeProperty: (k) => props.delete(k),
      getPropertyValue: (k) => props.get(k) ?? "",
    },
    querySelectorAll: () => laneEls,
    addEventListener: (n, fn) => listeners.push({ n, fn }),
    removeEventListener: (n, fn) => {
      const i = listeners.findIndex((l) => l.n === n && l.fn === fn)
      if (i >= 0) listeners.splice(i, 1)
    },
    listeners,
    laneEls,
    props,
  })
}

function fakeEnv({ duo = true, open = true } = {}) {
  const attrs = { [DUO_ATTR]: duo, [DUO_OPEN_ATTR]: open }
  const doc = { documentElement: { hasAttribute: (n) => attrs[n] === true } }
  const listeners = []
  const observers = []
  class RO {
    constructor(cb) {
      this.cb = cb
      this.observed = []
      observers.push(this)
    }
    observe(el) {
      this.observed.push(el)
    }
    disconnect() {
      this.disconnected = true
    }
  }
  const win = {
    ResizeObserver: RO,
    addEventListener: (n, fn) => listeners.push({ n, fn }),
    removeEventListener: (n, fn) => {
      const i = listeners.findIndex((l) => l.n === n && l.fn === fn)
      if (i >= 0) listeners.splice(i, 1)
    },
  }
  const posture = (d, o) => {
    attrs[DUO_ATTR] = d
    attrs[DUO_OPEN_ATTR] = o
    for (const l of listeners.filter((l) => l.n === DUO_POSTURE_EVENT)) l.fn()
  }
  return { attrs, doc, win, listeners, observers, posture }
}

describe("installKanbanPeek", () => {
  it("sets --kanban-lead only with BOTH Duo attributes", () => {
    for (const [duo, open, expected] of [
      [true, true, "74px"],
      [true, false, undefined],
      [false, false, undefined],
      [false, true, undefined],
    ]) {
      const env = fakeEnv({ duo, open })
      const board = fakeBoard(930)
      installKanbanPeek(board, env.win, env.doc)
      expect(board.props.get(LEAD_VAR), `duo=${duo} open=${open}`).toBe(expected)
    }
  })

  it("follows posture: cleared on fold, set again on unfold", () => {
    const env = fakeEnv()
    const board = fakeBoard(930)
    installKanbanPeek(board, env.win, env.doc)
    expect(board.props.get(LEAD_VAR)).toBe("74px")
    env.posture(true, false)
    expect(board.props.has(LEAD_VAR)).toBe(false)
    env.posture(true, true)
    expect(board.props.get(LEAD_VAR)).toBe("74px")
  })

  it("recomputes on resize (rotation 669 -> 951 keeps the base lead; 930 widens it)", () => {
    const env = fakeEnv()
    const board = fakeBoard(669)
    installKanbanPeek(board, env.win, env.doc)
    expect(env.observers[0].observed).toEqual([board])
    expect(board.props.get(LEAD_VAR)).toBe("16px")
    board.clientWidth = 930
    env.observers[0].cb()
    expect(board.props.get(LEAD_VAR)).toBe("74px")
    board.clientWidth = 951
    env.observers[0].cb()
    expect(board.props.get(LEAD_VAR)).toBe("16px")
  })

  it("after a resize the left-most visible lane is put back at the inline start", () => {
    const env = fakeEnv()
    const board = fakeBoard(669)
    installKanbanPeek(board, env.win, env.doc)
    // A 4px sliver of lane 1 is still on screen; lane 2 is the left-most
    // lane that is really visible.
    board.scrollLeft = 600
    board.listeners.find((l) => l.n === "scroll").fn()
    board.clientWidth = 951
    env.observers[0].cb()
    expect(board.laneEls[2].scrollIntoView).toHaveBeenCalledWith({ block: "nearest", inline: "start" })
  })

  it("uninstall removes the variable, the listeners and the observer", () => {
    const env = fakeEnv()
    const board = fakeBoard(930)
    const uninstall = installKanbanPeek(board, env.win, env.doc)
    uninstall()
    expect(board.props.has(LEAD_VAR)).toBe(false)
    expect(env.listeners.length).toBe(0)
    expect(board.listeners.length).toBe(0)
    expect(env.observers[0].disconnected).toBe(true)
  })
})

describe("KanbanDragDrop installs and removes the peek", () => {
  it("mounted() installs it, destroyed() removes it", () => {
    const env = fakeEnv()
    const board = fakeBoard(930)
    const prevWin = globalThis.window
    const prevDoc = globalThis.document
    globalThis.window = env.win
    globalThis.document = env.doc
    try {
      const hook = Object.create(KanbanDragDrop)
      hook.el = board
      hook.mounted()
      expect(board.props.get(LEAD_VAR)).toBe("74px")
      expect(board.listeners.map((l) => l.n)).toContain("dragstart")
      hook.destroyed()
      expect(board.props.has(LEAD_VAR)).toBe(false)
      expect(env.listeners.length).toBe(0)
      expect(board.listeners.length).toBe(0)
    } finally {
      globalThis.window = prevWin
      globalThis.document = prevDoc
    }
  })
})
