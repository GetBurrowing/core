import test from "node:test"
import assert from "node:assert/strict"
import SocialTicker, {TickerMotion} from "../js/hooks/social_ticker.js"

test("automatic motion advances slowly and wraps in source order", () => {
  const motion = new TickerMotion()
  assert.equal(motion.advance(0, 0, 200, 100), 0)
  assert.equal(motion.advance(40, 0, 200, 100), 0.96)
  assert.ok(Math.abs(motion.advance(80, 199.5, 200, 100) - 0.46) < 0.0001)
})

test("Wikipedia motion goes in the opposite direction at two thirds speed and wraps", () => {
  const motion = new TickerMotion()
  assert.equal(motion.advance(0, 0, 200, 100, -0.016), 0)
  assert.ok(Math.abs(motion.advance(40, 0, 200, 100, -0.016) - 199.36) < 0.0001)
  motion.toggle()
  assert.equal(motion.advance(80, 100, 200, 100, -0.016), 100)
})

test("one control pauses both tracks, including when only Wikipedia overflows", () => {
  const oldWindow = globalThis.window, oldDocument = globalThis.document, oldResize = globalThis.ResizeObserver
  const handlers = new Map(), frames = new Map()
  let id = 0
  const target = {addEventListener() {}, removeEventListener() {}}
  globalThis.window = {...target, matchMedia: () => ({...target, matches: false}),
    requestAnimationFrame: fn => {frames.set(++id, fn); return id}, cancelAnimationFrame: n => frames.delete(n)}
  let scrolled = 0, focused = 0
  globalThis.document = {...target, hidden: false,
    querySelector: selector => selector === "[data-role='studio-trends-heading']" ?
      {focus: () => focused++, scrollIntoView: () => scrolled++} : null}
  globalThis.ResizeObserver = undefined
  const viewport = {scrollLeft: 0, clientWidth: 100, contains: () => false}
  const wiki = {scrollLeft: 0, clientWidth: 100, contains: target => Boolean(target)}
  const button = {setAttribute() {}}, wikiCopy = {}, copy = {}
  let accountWidth = 80
  const refs = {"[data-ticker-viewport]": viewport, "[data-ticker-original]": {getBoundingClientRect: () => ({width: accountWidth})},
    "[data-ticker-copy]": copy, "[data-ticker-toggle]": button, "[data-wiki-viewport]": wiki,
    "[data-wiki-original]": {getBoundingClientRect: () => ({width: 200})}, "[data-wiki-copy]": wikiCopy}
  const el = {...target, dataset: {scopeKey: "a"}, querySelector: key => refs[key],
    addEventListener: (name, fn) => handlers.set(name, fn), contains: () => true}
  const events = new Map()
  const hook = Object.assign(Object.create(SocialTicker), {el, handleEvent: (name, fn) => events.set(name, fn)})
  const step = at => { const [key, fn] = frames.entries().next().value; frames.delete(key); fn(at) }
  try {
    hook.mounted()
    events.get("social:focus_trends")()
    assert.equal(scrolled, 1)
    assert.equal(focused, 1)
    let stopped = 0
    handlers.get("click")({ctrlKey: true, target: {closest: selector => selector.includes("ticker-wiki-entry") ? {} : null},
      stopPropagation: () => stopped++})
    assert.equal(stopped, 0, "modified button activation reaches LiveView")
    assert.equal(button.disabled, false)
    assert.equal(wikiCopy.hidden, false)
    step(0); step(40)
    assert.ok(wiki.scrollLeft > 199 && wiki.scrollLeft < 200)
    assert.equal(viewport.scrollLeft, 0)
    handlers.get("click")({target: {closest: selector => selector === "[data-ticker-toggle]"}})
    assert.equal(frames.size, 0)
    assert.equal(button.textContent, "Play")
    handlers.get("click")({target: {closest: selector => selector === "[data-ticker-toggle]"}})
    assert.equal(frames.size, 1)
    accountWidth = 200
    hook._reconcile()
    step(80); step(120); step(160)
    assert.ok(viewport.scrollLeft > 0)
    assert.ok(wiki.scrollLeft < 199.36)
    hook._interact("focus", true)
    assert.equal(frames.size, 0)
    hook._interact("focus", false)
    hook._motion.setReduced(true); hook._reconcile()
    assert.equal(frames.size, 0)
    assert.equal(wikiCopy.hidden, true)
  } finally {
    hook.destroyed()
    globalThis.window = oldWindow; globalThis.document = oldDocument; globalThis.ResizeObserver = oldResize
  }
})

test("explicit pause survives hover, focus and touch ending", () => {
  const motion = new TickerMotion()
  motion.toggle()
  for (const kind of ["hover", "focus", "touch", "manual"]) {
    motion.interact(kind, true)
    motion.interact(kind, false)
  }
  assert.equal(motion.running, false)
  assert.equal(motion.advance(100, 42, 200, 100), 42)
  motion.toggle()
  assert.equal(motion.running, true)
})

test("each interaction pauses motion without cancelling a different active interaction", () => {
  const motion = new TickerMotion()
  motion.interact("hover", true)
  motion.interact("focus", true)
  motion.interact("hover", false)
  assert.equal(motion.running, false)
  motion.interact("focus", false)
  assert.equal(motion.running, true)
})

test("reduced motion cannot be overridden by Play, and static content remains manually positioned", () => {
  const motion = new TickerMotion()
  motion.setReduced(true)
  motion.toggle()
  motion.toggle()
  assert.equal(motion.running, false)
  assert.equal(motion.advance(400, 70, 200, 100), 70)
  motion.setReduced(false)
  assert.equal(motion.running, true)
  assert.equal(motion.advance(500, 70, 80, 100), 70)
})

test("resume discards elapsed paused time rather than jumping across entries", () => {
  const motion = new TickerMotion()
  motion.advance(0, 0, 200, 100)
  motion.interact("touch", true)
  motion.advance(100, 12, 200, 100)
  motion.interact("touch", false)
  assert.equal(motion.advance(10_000, 12, 200, 100), 12)
  assert.equal(motion.advance(10_040, 12, 200, 100), 12.96)
})

test("hook cancels animation and listeners when destroyed", () => {
  const oldWindow = globalThis.window
  const oldDocument = globalThis.document
  const oldResize = globalThis.ResizeObserver
  const frames = new Map()
  const listeners = new Set()
  let seq = 0
  const target = () => ({
    addEventListener: (_type, handler) => listeners.add(handler),
    removeEventListener: (_type, handler) => listeners.delete(handler),
  })
  const media = {...target(), matches: false}
  globalThis.window = {...target(), requestAnimationFrame: fn => {frames.set(++seq, fn); return seq},
    cancelAnimationFrame: id => frames.delete(id), matchMedia: () => media}
  globalThis.document = {...target(), hidden: false}
  let disconnected = false
  globalThis.ResizeObserver = class { observe() {} disconnect() { disconnected = true } }
  const viewport = {scrollLeft: 0, clientWidth: 100}
  const original = {getBoundingClientRect: () => ({width: 200})}
  const button = {textContent: "Pause", disabled: false, setAttribute() {}}
  const copy = {hidden: false}
  const refs = {"[data-ticker-viewport]": viewport, "[data-ticker-original]": original,
    "[data-ticker-toggle]": button, "[data-ticker-copy]": copy}
  const el = {...target(), dataset: {scopeKey: "A"}, querySelector: key => refs[key],
    contains: () => false}
  try {
    const hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    assert.equal(frames.size, 1)
    assert.ok(listeners.size > 0)
    delete el.dataset.tickerReady
    hook.updated()
    assert.equal(el.dataset.tickerReady, "true")
    hook.destroyed()
    assert.equal(frames.size, 0)
    assert.equal(listeners.size, 0)
    assert.equal(disconnected, true)
  } finally {
    globalThis.window = oldWindow
    globalThis.document = oldDocument
    globalThis.ResizeObserver = oldResize
  }
})

test("hook accumulates fractional frames with integer scroll offsets and adopts manual position", () => {
  const oldWindow = globalThis.window
  const oldDocument = globalThis.document
  const oldResize = globalThis.ResizeObserver
  const frames = new Map()
  let seq = 0
  const target = {addEventListener() {}, removeEventListener() {}}
  globalThis.window = {...target, requestAnimationFrame: fn => {frames.set(++seq, fn); return seq},
    cancelAnimationFrame: id => frames.delete(id), matchMedia: () => ({...target, matches: false})}
  globalThis.document = {...target, hidden: false}
  globalThis.ResizeObserver = undefined
  let position = 0
  const viewport = {clientWidth: 400,
    get scrollLeft() { return position },
    set scrollLeft(value) { position = Math.round(value) }}
  const refs = {"[data-ticker-viewport]": viewport,
    "[data-ticker-original]": {getBoundingClientRect: () => ({width: 3806})},
    "[data-ticker-toggle]": {setAttribute() {}}, "[data-ticker-copy]": {}}
  const el = {...target, dataset: {scopeKey: "A"}, querySelector: key => refs[key], contains: () => false}
  const step = at => {
    const [id, callback] = frames.entries().next().value
    frames.delete(id)
    callback(at)
  }
  let hook
  try {
    hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    for (let n = 0; n <= 300; n++) step(n * 16)
    assert.equal(viewport.scrollLeft, 115)
    viewport.scrollLeft = 900
    step(4816)
    assert.equal(viewport.scrollLeft, 900)
    for (let n = 302; n <= 400; n++) step(n * 16)
    assert.ok(viewport.scrollLeft > 930)
    viewport.scrollLeft = 3805
    for (let n = 401; n <= 410; n++) step(n * 16)
    assert.ok(viewport.scrollLeft < 4, "wraps at the original copy width")
    el.dataset.scopeKey = "B"
    hook.updated()
    step(6576)
    assert.equal(viewport.scrollLeft, 0, "new scope starts at its first entry")
  } finally {
    hook?.destroyed()
    globalThis.window = oldWindow
    globalThis.document = oldDocument
    globalThis.ResizeObserver = oldResize
  }
})

test("explicit Pause survives remount and scope changes; Play persists and reduced motion still wins", async () => {
  const oldWindow = globalThis.window
  const oldDocument = globalThis.document
  const oldResize = globalThis.ResizeObserver
  const saved = new Map()
  const frames = new Map()
  let seq = 0
  const target = () => ({addEventListener() {}, removeEventListener() {}})
  const storage = {getItem: key => saved.get(key) ?? null, setItem: (key, value) => saved.set(key, value)}
  const media = {...target(), matches: false}
  globalThis.window = {...target(), sessionStorage: storage,
    requestAnimationFrame: fn => {frames.set(++seq, fn); return seq},
    cancelAnimationFrame: id => frames.delete(id), matchMedia: () => media}
  globalThis.document = {...target(), hidden: false}
  globalThis.ResizeObserver = undefined
  const mounted = []
  const mount = (implementation = SocialTicker) => {
    const handlers = new Map()
    const refs = {"[data-ticker-viewport]": {clientWidth: 400, scrollLeft: 0},
      "[data-ticker-original]": {getBoundingClientRect: () => ({width: 3806})},
      "[data-ticker-toggle]": {setAttribute() {}}, "[data-ticker-copy]": {}}
    const el = {...target(), addEventListener: (name, fn) => handlers.set(name, fn),
      dataset: {scopeKey: "A"}, querySelector: key => refs[key], contains: () => false}
    const hook = Object.assign(Object.create(implementation), {el})
    hook.mounted()
    mounted.push(hook)
    return {hook, click: () => handlers.get("click")({target: {closest: () => true}}), refs}
  }
  try {
    const first = mount()
    first.click()
    assert.equal(first.hook._motion.paused, true)
    first.hook.destroyed()
    const reloaded = await import("../js/hooks/social_ticker.js?session-reload")
    const second = mount(reloaded.default)
    assert.equal(second.hook._motion.paused, true, "navigation/reload remount keeps Pause")
    assert.equal(second.refs["[data-ticker-toggle]"].textContent, "Play")
    second.hook.el.dataset.scopeKey = "B"
    second.hook.updated()
    second.hook._interact("hover", true)
    second.hook._interact("hover", false)
    assert.equal(second.hook._motion.running, false, "brand/temporary interaction cannot clear Pause")
    second.click()
    second.hook.destroyed()
    media.matches = true
    const third = mount()
    assert.equal(third.hook._motion.paused, false, "Play was persisted")
    assert.equal(third.hook._motion.running, false, "Play respects reduced motion")
  } finally {
    for (const hook of mounted) if (!hook._destroyed) hook.destroyed()
    globalThis.window = oldWindow
    globalThis.document = oldDocument
    globalThis.ResizeObserver = oldResize
  }
})

test("entry clicks stay in place for ordinary and keyboard activation but preserve modified links", () => {
  const oldWindow = globalThis.window
  const oldDocument = globalThis.document
  const oldResize = globalThis.ResizeObserver
  const handlers = new Map()
  const target = {addEventListener() {}, removeEventListener() {}}
  globalThis.window = {...target, matchMedia: () => ({...target, matches: true})}
  globalThis.document = {...target, hidden: false}
  globalThis.ResizeObserver = undefined
  const entry = {}
  const refs = {"[data-ticker-viewport]": {scrollLeft: 0, clientWidth: 400},
    "[data-ticker-original]": {getBoundingClientRect: () => ({width: 3806})},
    "[data-ticker-toggle]": {setAttribute() {}}, "[data-ticker-copy]": {}}
  const el = {...target, dataset: {scopeKey: "A"}, querySelector: key => refs[key],
    contains: item => item === entry, addEventListener: (name, fn) => handlers.set(name, fn)}
  let hook
  try {
    hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    for (const modifiers of [{button: 0, detail: 1}, {button: 0, detail: 0},
      {button: 0, ctrlKey: true}, {button: 0, metaKey: true}, {button: 0, shiftKey: true},
      {button: 0, altKey: true}, {button: 1}]) {
      let prevented = false
      let stopped = false
      const event = {...modifiers,
        target: {closest: selector => selector === "[data-ticker-toggle]" ? null : entry},
        preventDefault: () => {prevented = true}, stopPropagation: () => {stopped = true}}
      handlers.get("click")(event)
      const ordinary = !modifiers.ctrlKey && !modifiers.metaKey && !modifiers.shiftKey && !modifiers.altKey && modifiers.button === 0
      assert.equal(prevented, ordinary, "only ordinary/keyboard clicks suppress browser navigation")
      assert.equal(stopped, !ordinary, "only modified clicks bypass LiveView's window click handler")
    }
  } finally {
    hook?.destroyed()
    globalThis.window = oldWindow
    globalThis.document = oldDocument
    globalThis.ResizeObserver = oldResize
  }
})

test("focused Pause/Play resumes without blurring, while viewport and entry focus pause", () => {
  const oldWindow = globalThis.window
  const oldDocument = globalThis.document
  const oldResize = globalThis.ResizeObserver
  const handlers = new Map()
  const windowHandlers = new Map()
  const timers = []
  let focusVisible = true
  let id = 0
  const target = {addEventListener() {}, removeEventListener() {}}
  const button = {setAttribute() {}}
  const entry = {matches: selector => selector === ":focus-visible" && focusVisible}
  const viewport = {scrollLeft: 0, clientWidth: 400, matches: selector => selector === ":focus-visible" && focusVisible, contains: item => item === viewport || item === entry}
  const refs = {"[data-ticker-viewport]": viewport,
    "[data-ticker-original]": {getBoundingClientRect: () => ({width: 3806})},
    "[data-ticker-toggle]": button, "[data-ticker-copy]": {}}
  globalThis.window = {...target, addEventListener: (name, fn) => windowHandlers.set(name, fn),
    setTimeout: fn => {timers.push(fn); return timers.length}, clearTimeout() {}, matchMedia: () => ({...target, matches: false}),
    requestAnimationFrame: () => ++id, cancelAnimationFrame() {},
    sessionStorage: {getItem: () => "false", setItem() {}}}
  globalThis.document = {...target, hidden: false, activeElement: button}
  globalThis.ResizeObserver = undefined
  const el = {...target, dataset: {scopeKey: "A"}, querySelector: key => refs[key],
    contains: item => item === button || viewport.contains(item), addEventListener: (name, fn) => handlers.set(name, fn)}
  const click = () => handlers.get("click")({target: {closest: selector => selector === "[data-ticker-toggle]" ? button : null}})
  let hook
  try {
    hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    assert.equal(hook._motion.running, true, "control focus at mount is not a temporary pause")
    hook.destroyed()
    document.activeElement = entry
    hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    assert.equal(hook._motion.running, false, "keyboard-visible entry focus at mount pauses")
    document.activeElement = button
    handlers.get("focusout")({target: entry, relatedTarget: button})
    handlers.get("focusin")({target: button})
    click()
    assert.equal(hook._motion.paused, true)
    click()
    assert.equal(hook._motion.running, true, "Play keeps focus and runs")
    assert.equal(document.activeElement, button)
    handlers.get("focusout")({target: button, relatedTarget: entry})
    handlers.get("focusin")({target: entry})
    assert.equal(hook._motion.running, false)
    handlers.get("focusout")({target: entry, relatedTarget: viewport})
    assert.equal(hook._motion.running, false)
    handlers.get("focusout")({target: viewport, relatedTarget: button})
    handlers.get("focusin")({target: button})
    assert.equal(hook._motion.running, true)
    focusVisible = false
    document.activeElement = entry
    handlers.get("focusin")({target: entry})
    assert.equal(hook._motion.running, true, "pointer focus left on an entry cannot hold the strip")
    handlers.get("keydown")?.({target: entry, key: "Enter"})
    assert.equal(hook._motion.running, false, "keyboard interaction pauses without a new focus event")
    focusVisible = true
    handlers.get("focusin")({target: entry})
    assert.equal(hook._motion.running, false, "keyboard focus still holds the strip")
    handlers.get("pointerdown")()
    focusVisible = false
    windowHandlers.get("pointerup")()
    assert.equal(hook._motion.running, false, "manual interaction delay still applies")
    timers.pop()()
    assert.equal(hook._motion.running, true, "pointer release clears a prior keyboard-focus pause without a focus event")
    hook._interact("hover", true)
    handlers.get("focusin")({target: button})
    assert.equal(hook._motion.running, false, "control focus cannot clear other pauses")
  } finally {
    hook?.destroyed()
    globalThis.window = oldWindow
    globalThis.document = oldDocument
    globalThis.ResizeObserver = oldResize
  }
})

test("touch compatibility hover cannot trap motion; real mouse hover still pauses", () => {
  const oldWindow = globalThis.window
  const oldDocument = globalThis.document
  const oldResize = globalThis.ResizeObserver
  const handlers = new Map()
  const windowHandlers = new Map()
  const timers = []
  const frames = new Map()
  let seq = 0
  let at = 0
  let mouseCapable = false
  let cssHover = false
  const target = {addEventListener() {}, removeEventListener() {}}
  globalThis.window = {...target, addEventListener: (name, fn) => windowHandlers.set(name, fn),
    matchMedia: query => ({...target, matches: query === "(hover: hover) and (pointer: fine)" && mouseCapable}),
    requestAnimationFrame: fn => {frames.set(++seq, fn); return seq}, cancelAnimationFrame: id => frames.delete(id),
    setTimeout: fn => {timers.push(fn); return timers.length}, clearTimeout() {},
    sessionStorage: {getItem: () => "false", setItem() {}}}
  globalThis.document = {...target, hidden: false}
  globalThis.ResizeObserver = undefined
  const viewport = {scrollLeft: 0, clientWidth: 400, contains: () => false}
  const refs = {"[data-ticker-viewport]": viewport,
    "[data-ticker-original]": {getBoundingClientRect: () => ({width: 800})},
    "[data-ticker-toggle]": {setAttribute() {}}, "[data-ticker-copy]": {}}
  const el = {...target, dataset: {scopeKey: "A"}, querySelector: key => refs[key], contains: () => false,
    matches: selector => selector === ":hover" && cssHover, addEventListener: (name, fn) => handlers.set(name, fn)}
  const emit = (name, pointerType) => handlers.get(name)?.({pointerType})
  const compatHover = () => {cssHover = true; for (let n = 0; n < 7; n++) emit("mouseenter", "mouse")}
  const step = () => {
    const [id, callback] = frames.entries().next().value
    frames.delete(id)
    at += 16
    callback(at)
  }
  const release = pointerType => {windowHandlers.get("pointerup")({pointerType}); timers.pop()()}
  let hook
  try {
    hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    assert.equal(hook._motion.running, true, "sticky CSS hover on a touch device is not mouse hover")
    for (let n = 0; n < 60; n++) step()
    for (const action of ["tap", "drag", "cancel"]) {
      emit("pointerenter", "touch")
      emit("pointerdown", "touch")
      assert.equal(hook._motion.running, false, "held touch pauses")
      if (action === "drag") viewport.scrollLeft += 100
      windowHandlers.get(action === "cancel" ? "pointercancel" : "pointerup")?.({pointerType: "touch"})
      compatHover()
      timers.pop()?.()
      assert.equal(hook._touching, false, `${action} clears the held pointer`)
      assert.equal(hook._motion.interactions.has("touch"), false, `${action} clears the touch pause`)
      assert.equal(hook._motion.running, true, `${action} resumes despite compatibility mouseenter`)
      const before = viewport.scrollLeft
      for (let n = 0; n < 150; n++) step()
      assert.ok(viewport.scrollLeft > before + 40, `${action} resumes actual frame movement`)
    }
    emit("pointerenter", "mouse")
    assert.equal(hook._motion.running, false, "actual mouse hover pauses")
    emit("pointerleave", "touch")
    assert.equal(hook._motion.running, false, "touch leave cannot clear a mouse hover pause")
    emit("pointerleave", "mouse")
    assert.equal(hook._motion.running, true)
    emit("pointerenter", "pen")
    assert.equal(hook._motion.running, true, "pen proximity is not mouse hover")
    hook._motion.toggle()
    emit("pointerdown", "touch")
    compatHover()
    release("touch")
    assert.equal(hook._motion.running, false, "touch cannot clear explicit Pause")
    hook.destroyed()
    hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    assert.equal(hook._motion.running, true, "sticky touch hover cannot pause a remounted strip")
    hook.destroyed()
    mouseCapable = true
    hook = Object.assign(Object.create(SocialTicker), {el})
    hook.mounted()
    assert.equal(hook._motion.running, false, "desktop hover at mount still pauses")
    emit("pointerdown", "touch")
    compatHover()
    release("touch")
    assert.equal(hook._motion.running, true, "hybrid touch clears a stale mouse-hover pause")
  } finally {
    hook?.destroyed()
    globalThis.window = oldWindow
    globalThis.document = oldDocument
    globalThis.ResizeObserver = oldResize
  }
})

test("stationary details pause motion, focus the heading and return to the details button", () => {
  let focused = null
  let panel = {querySelector: () => ({focus: () => {focused = "heading"}})}
  const button = {focus: () => {focused = "button"}}
  const hook = Object.assign(Object.create(SocialTicker), {
    _motion: new TickerMotion(), _reconcile() {},
    el: {querySelector: selector => selector === "[data-role='ticker-video-details']" ? panel : button}
  })
  hook._detailsEvent({open: true, account_id: "synthetic-account"})
  assert.equal(hook._motion.running, false)
  assert.equal(focused, "heading")
  hook._motion.interact("focus", false)
  assert.equal(hook._motion.running, false, "moving focus out of viewport cannot resume an open panel")
  panel = null
  hook._detailsEvent({open: false, account_id: "synthetic-account"})
  assert.equal(focused, "button")
  assert.equal(hook._motion.interactions.has("details"), false)
  hook._motion.paused = true
  hook._detailsEvent({open: true, account_id: "synthetic-account"})
  hook._detailsEvent({open: false, account_id: "synthetic-account"})
  assert.equal(hook._motion.running, false, "closing preserves the explicit Pause preference")
})
