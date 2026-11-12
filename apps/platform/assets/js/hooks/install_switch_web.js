/**
 * The web path of the install switcher (task 01a1ccd4 stage 3): what
 * `#native-install-switch` (phone top bar) and `#sidebar-install-switch`
 * (desktop sidebar brand row) do OUTSIDE the Burrow app. Inside the app
 * `native_install_switch.js` keeps its native path and never calls this.
 *
 * Both buttons render from one component (`PlatformWeb.Components.InstallSwitch`)
 * and attach to ONE controller per page, so the phone and desktop switchers
 * share one list, one set of unread answers and one refresh timer: they
 * cannot disagree.
 *
 * Design: stage-1 canvas 01a1cd29-e313 (element inventory + decisions).
 * Each button's dropdown is drawn into its sibling `#<id>-menu`, which the
 * server renders `phx-update="ignore"` so LiveView patches never wipe it.
 * Modals (Add, Manage, Remove, the hop and switching cards) and toasts go in
 * one body-level `#install-switch-overlay`, outside every LiveView.
 *
 * Every string from storage or from another install is written with
 * textContent (via `el()`), never innerHTML. Switching is a top-level
 * navigation to `<origin>/` with nothing in the URL: carry-over sign-in is
 * the target install's own OIDC.
 */

import * as S from "../lib/install_switch_store.js"

const DOT_SELECTOR = "[data-role='install-unread-dot']"
const HOP_DELAY_MS = 700
const TOAST_MS = 3200

const ROW_CLASS =
  "flex w-full min-w-0 flex-1 items-center gap-2.5 rounded-lg px-2 py-1.5 text-left hover:bg-base-content/8 active:bg-base-content/8 focus-visible-ring"
const PILL_CLASS =
  "inline-flex h-[18px] min-w-[18px] shrink-0 items-center justify-center rounded-full bg-primary px-[5px] text-xs font-bold leading-none tabular-nums text-primary-content"
const PRIMARY_BTN =
  "inline-flex items-center justify-center rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content disabled:opacity-60 focus-visible-ring"
const GHOST_BTN =
  "inline-flex items-center justify-center rounded-lg border border-edge px-4 py-2 text-sm font-medium text-base-content hover:bg-base-content/8 focus-visible-ring"

/** Build an element. Strings become text nodes; `text` sets textContent. */
export function el(doc, tag, props = {}, children = []) {
  const node = doc.createElement(tag)
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue
    if (k === "text") node.textContent = String(v)
    else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v)
    else node.setAttribute(k, v === true ? "" : String(v))
  }
  for (const child of children) {
    if (child == null || child === false) continue
    node.appendChild(typeof child === "string" ? doc.createTextNode(child) : child)
  }
  return node
}

function icon(doc, name, cls = "size-4") {
  return el(doc, "span", { class: `${name} ${cls} shrink-0`, "aria-hidden": "true" })
}

function storageOf(win, name) {
  // The switcher's keys (burrow.installs.v1 and friends) are a fixed,
  // cross-stage contract, so they do not go through ClientState's `suite:`
  // namespace; every read and write is try/catch'd in install_switch_store.js.
  try {
    return win[name] || null // client-state:allow
  } catch {
    return null
  }
}

/** Whether `img` loads from `<origin>/branding/current/apple_touch`. */
export function imageProbe(win, origin, timeoutMs = S.FETCH_TIMEOUT_MS) {
  return new Promise(resolve => {
    const Ctor = win.Image
    if (typeof Ctor !== "function") return resolve(false)
    const img = new Ctor()
    let timer = null
    const done = value => {
      clearTimeout(timer)
      img.onload = img.onerror = null
      resolve(value)
    }
    timer = setTimeout(() => done(false), timeoutMs)
    img.referrerPolicy = "no-referrer"
    img.onload = () => done(true)
    img.onerror = () => done(false)
    img.src = origin + "/branding/current/apple_touch"
  })
}

export function createWebSwitch(env = {}) {
  const win = env.win || globalThis.window
  const doc = env.doc || globalThis.document
  const local = env.local !== undefined ? env.local : storageOf(win, "localStorage")
  const session = env.session !== undefined ? env.session : storageOf(win, "sessionStorage")
  const fetchImpl = env.fetch || ((...args) => win.fetch(...args))
  const probe = env.probe || (origin => imageProbe(win, origin))
  const now = env.now || (() => Date.now())

  const ctl = {
    views: new Set(),
    entries: [],
    states: new Map(),
    tokens: new Map(),
    open: null,
    query: "",
    modal: null,
    modalVariant: "phone",
    timer: null,
    started: false
  }

  // ── The current install ────────────────────────────────────────────────

  function firstView() {
    return ctl.views.values().next().value || null
  }

  function current() {
    const origin = win.location.origin
    const view = firstView()
    const name = view?.button.getAttribute("data-install-name") || win.location.host
    const n = parseInt(view?.button.getAttribute("data-current-unread") || "", 10)
    return {
      origin,
      host: win.location.host,
      name,
      current: true,
      unread: Number.isInteger(n) && n >= 0 ? n : null
    }
  }

  function others() {
    const here = win.location.origin
    return ctl.entries.filter(e => e.origin !== here)
  }

  function rows() {
    return [current(), ...others()]
  }

  function syncStates() {
    const live = new Set()
    for (const entry of others()) {
      live.add(entry.origin)
      const prev = ctl.states.get(entry.origin)
      if (!entry.key) ctl.states.set(entry.origin, S.initialState(entry))
      else if (!prev || prev.status === "reconnect") ctl.states.set(entry.origin, S.initialState(entry))
    }
    for (const origin of [...ctl.states.keys()]) if (!live.has(origin)) ctl.states.delete(origin)
  }

  function reload() {
    ctl.entries = S.readList(local)
    syncStates()
  }

  function dotOn() {
    return S.othersHaveUnread(ctl.entries, ctl.states, win.location.origin)
  }

  // ── Unread ─────────────────────────────────────────────────────────────

  function apply(origin, result) {
    const next = S.applyResult(ctl.states.get(origin), result)
    if (result.kind === "ok" && next.as_of === result.as_of) {
      if (!S.patchEntry(local, origin, { unread: next.unread, as_of: next.as_of })) return
    } else if (result.kind === "reconnect") {
      if (!S.patchEntry(local, origin, { key: null, unread: null, as_of: null })) return
    } else if (result.kind === "rejected") {
      if (!S.patchEntry(local, origin, { unread: null, as_of: null })) return
    }
    ctl.entries = S.readList(local)
    if (!ctl.entries.some(e => e.origin === origin)) return
    ctl.states.set(origin, next)
  }

  function refresh(onlyOrigin) {
    reload()
    const targets = others().filter(e => e.key && (!onlyOrigin || e.origin === onlyOrigin))
    paint()
    return S.runPool(targets, async entry => {
      const token = {}
      ctl.tokens.set(entry.origin, token)
      const result = await S.fetchUnread(entry, { fetch: fetchImpl })
      if (ctl.tokens.get(entry.origin) !== token) return
      apply(entry.origin, result)
      paint()
    })
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────

  const onVisibility = () => {
    if (doc.visibilityState === "visible") refresh()
  }

  const onTick = () => {
    if (doc.visibilityState === "visible") refresh()
  }

  const onKey = event => {
    if (event.key !== "Escape") return
    if (ctl.modal && ctl.modal.kind !== "hop" && ctl.modal.kind !== "switching") closeModal()
    else if (ctl.open) close()
  }

  const onPointer = event => {
    const view = ctl.open
    if (!view) return
    const t = event.target
    if (view.menu?.contains?.(t) || view.button.contains?.(t)) return
    if (overlayHost(false)?.contains?.(t)) return
    close()
  }

  const onStorage = event => {
    if (event.key && event.key !== S.STORAGE_KEY) return
    reload()
    paint()
  }

  function start() {
    if (ctl.started) return
    ctl.started = true
    doc.addEventListener("visibilitychange", onVisibility)
    doc.addEventListener("keydown", onKey)
    doc.addEventListener("pointerdown", onPointer)
    win.addEventListener("storage", onStorage)
    ctl.timer = setInterval(onTick, S.REFRESH_MS)
    showPendingToast()
    refresh()
  }

  function stop() {
    if (!ctl.started) return
    ctl.started = false
    doc.removeEventListener("visibilitychange", onVisibility)
    doc.removeEventListener("keydown", onKey)
    doc.removeEventListener("pointerdown", onPointer)
    win.removeEventListener("storage", onStorage)
    clearInterval(ctl.timer)
    ctl.timer = null
  }

  function attach(button) {
    const menu = doc.getElementById ? doc.getElementById(button.id + "-menu") : null
    const view = {
      button,
      menu,
      variant: button.getAttribute("data-variant") === "sidebar" ? "sidebar" : "phone"
    }
    view.onClick = event => {
      event?.preventDefault?.()
      toggle(view)
    }
    button.addEventListener("click", view.onClick)
    ctl.views.add(view)
    reveal(view)
    paintButton(view)
    start()
    return view
  }

  function detach(view) {
    view.button.removeEventListener("click", view.onClick)
    if (ctl.open === view) ctl.open = null
    view.menu?.replaceChildren?.()
    ctl.views.delete(view)
    if (ctl.views.size === 0) stop()
  }

  function updated(view) {
    reveal(view)
    paintButton(view)
  }

  function reveal(view) {
    view.button.classList.remove("hidden")
    view.button.classList.add("flex")
  }

  // ── Painting ───────────────────────────────────────────────────────────

  function paintButton(view) {
    const on = dotOn()
    const dot = view.button.querySelector(DOT_SELECTOR)
    if (dot) {
      if (on) dot.classList.remove("hidden")
      else dot.classList.add("hidden")
    }
    const name = view.button.getAttribute("data-install-name") || win.location.host
    view.button.setAttribute(
      "aria-label",
      `Switch install, current: ${name}` + (on ? ", other installs have unread" : "")
    )
    view.button.setAttribute("aria-haspopup", "dialog")
    view.button.setAttribute("aria-expanded", ctl.open === view ? "true" : "false")
  }

  function paint() {
    for (const view of ctl.views) paintButton(view)
    if (ctl.open) renderPanel(ctl.open)
    if (ctl.modal?.kind === "manage") renderModal()
  }

  function toggle(view) {
    if (ctl.open === view) close()
    else openPanel(view)
  }

  function openPanel(view) {
    if (ctl.open && ctl.open !== view) ctl.open.menu?.replaceChildren?.()
    ctl.open = view
    ctl.query = ""
    renderPanel(view)
    for (const v of ctl.views) paintButton(v)
    view.menu?.querySelector?.("[data-role='install-switch-find']")?.focus?.()
  }

  function close() {
    const view = ctl.open
    ctl.open = null
    view?.menu?.replaceChildren?.()
    for (const v of ctl.views) paintButton(v)
  }

  function position(view, panel, scrim) {
    const rect = view.button.getBoundingClientRect?.()
    if (!rect) return
    if (view.variant === "sidebar") {
      panel.style.top = `${Math.round(rect.bottom + 6)}px`
      panel.style.left = `${Math.round(rect.left)}px`
    } else {
      const bar = view.button.closest?.("header")?.getBoundingClientRect?.() || rect
      panel.style.top = `${Math.round(bar.bottom + 6)}px`
      if (scrim) scrim.style.top = `${Math.round(bar.bottom)}px`
    }
  }

  function rowStatus(row) {
    if (row.current) return "current"
    return ctl.states.get(row.origin)?.status || "loading"
  }

  function logoTile(row) {
    const initial = (row.name || row.host || "?").trim().charAt(0).toUpperCase() || "?"
    const img = el(doc, "img", {
      src: (row.current ? "" : row.origin) + "/branding/current/apple_touch",
      alt: "",
      referrerpolicy: "no-referrer",
      loading: "lazy",
      class: "absolute inset-0 size-full object-cover",
      onerror: () => img.remove?.()
    })
    return el(
      doc,
      "span",
      {
        class:
          "relative inline-flex size-8 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-edge bg-base-300 text-xs font-semibold text-subtle",
        "aria-hidden": "true"
      },
      [el(doc, "span", { text: initial }), img]
    )
  }

  function buildRow(row) {
    const status = rowStatus(row)
    const state = row.current ? { unread: row.unread } : ctl.states.get(row.origin) || {}
    const faded = status === "stale"
    const sub =
      status === "stale"
        ? "Could not update"
        : status === "unreachable"
          ? "Can't reach. Click to retry."
          : status === "reconnect"
            ? "Unread paused"
            : row.host

    const showCount =
      (status === "current" || S.countsTowardDot(state)) &&
      Number.isInteger(state.unread) &&
      state.unread > 0

    const trailing = []
    if (showCount) {
      trailing.push(
        el(doc, "span", {
          class: PILL_CLASS + (faded ? " opacity-45" : ""),
          "data-role": "install-row-count",
          text: S.formatCount(state.unread)
        })
      )
    }
    if (status === "unreachable") {
      trailing.push(
        el(doc, "span", {
          class: "size-[7px] shrink-0 rounded-full bg-error",
          "data-role": "install-row-unreachable",
          "aria-hidden": "true"
        })
      )
    }
    if (status === "current") {
      trailing.push(icon(doc, "hero-check", "size-4 text-primary"))
    }

    const main = el(
      doc,
      "button",
      {
        type: "button",
        class: ROW_CLASS,
        "data-role": "install-row",
        "data-origin": row.origin,
        "data-status": status,
        "aria-current": row.current ? "true" : null,
        onclick: () => rowClick(row, status)
      },
      [
        logoTile(row),
        el(doc, "span", { class: "flex min-w-0 flex-1 flex-col" + (faded ? " opacity-45" : "") }, [
          el(doc, "span", {
            class: "truncate text-sm font-medium text-base-content",
            "data-role": "install-row-name",
            text: row.name
          }),
          el(doc, "span", {
            class: "truncate text-xs text-subtle",
            "data-role": "install-row-sub",
            text: sub
          })
        ]),
        ...trailing
      ]
    )

    const children = [main]
    if (status === "reconnect") {
      children.push(
        el(doc, "button", {
          type: "button",
          class: "shrink-0 rounded-md px-2 py-1 text-sm font-medium text-primary hover:bg-base-content/8 focus-visible-ring",
          "data-role": "install-row-reconnect",
          text: "Reconnect",
          onclick: () => startHop(row.origin, row.name)
        })
      )
    }
    return el(doc, "li", { class: "flex items-center gap-1", "data-role": "install-row-item" }, children)
  }

  function filteredRows() {
    const all = rows()
    const q = ctl.query.trim().toLowerCase()
    if (!q) return all
    return all.filter(r => r.name.toLowerCase().includes(q) || r.host.toLowerCase().includes(q))
  }

  function renderList(list) {
    list.replaceChildren(...filteredRows().map(buildRow))
  }

  function renderPanel(view) {
    const host = view.menu
    if (!host) return
    const all = rows()
    const phone = view.variant !== "sidebar"
    const list = el(doc, "ul", {
      class: "flex flex-col gap-0.5 overflow-y-auto " + (phone ? "max-h-[21rem]" : "max-h-[26rem]"),
      "data-role": "install-switch-list"
    })
    renderList(list)

    const find =
      all.length >= S.FIND_AT
        ? el(doc, "input", {
            type: "search",
            placeholder: "Find an install",
            "aria-label": "Find an install",
            "data-role": "install-switch-find",
            class:
              "mx-1 mb-1 rounded-lg border border-edge bg-base-100 px-2.5 py-1.5 text-sm text-base-content placeholder:text-subtle focus:outline-none focus:ring-2 focus:ring-primary",
            oninput: event => {
              ctl.query = event?.target?.value ?? ""
              renderList(list)
            }
          })
        : null
    if (find && ctl.query) find.value = ctl.query

    const empty =
      all.length === 1
        ? el(doc, "div", { class: "px-2 py-3", "data-role": "install-switch-empty" }, [
            el(doc, "p", {
              class: "text-sm font-semibold text-base-content",
              text: "Switch between Burrow installs"
            }),
            el(doc, "p", {
              class: "mt-1 text-xs leading-relaxed text-subtle",
              text: "Add another install, like a second team, a client's Burrow or a friend's server, and jump to it from here. Each install keeps its own spaces and sign-in. When one has unread, a dot shows next to this name."
            })
          ])
        : null

    const add = el(
      doc,
      "button",
      {
        type: "button",
        class:
          "mt-1 flex w-full items-center gap-2.5 rounded-lg px-2 py-1.5 text-left text-sm text-base-content hover:bg-base-content/8 focus-visible-ring",
        "data-role": "install-switch-add",
        onclick: () => openAdd(view)
      },
      [
        el(
          doc,
          "span",
          {
            class:
              "inline-flex size-8 shrink-0 items-center justify-center rounded-lg border border-dashed border-edge text-subtle",
            "aria-hidden": "true"
          },
          [icon(doc, "hero-plus")]
        ),
        el(doc, "span", { text: "Add an install" })
      ]
    )

    const manage =
      all.length >= 2
        ? el(doc, "button", {
            type: "button",
            class:
              "w-full rounded-lg px-2 py-1.5 text-left text-sm text-subtle hover:bg-base-content/8 focus-visible-ring",
            "data-role": "install-switch-manage",
            text: "Manage installs",
            onclick: () => openManage(view)
          })
        : null

    const panel = el(
      doc,
      "div",
      {
        role: "dialog",
        "aria-label": "Installs on this browser",
        "data-role": "install-switch-panel",
        "data-variant": view.variant,
        class: phone
          ? "fixed inset-x-2 z-50 flex flex-col rounded-xl border border-edge bg-base-100 p-1.5 shadow-lg"
          : "fixed z-50 flex w-[300px] flex-col rounded-xl border border-edge bg-base-100 p-1.5 shadow-lg"
      },
      [
        el(doc, "div", {
          class: "px-2 pt-1 pb-1.5 text-xs font-medium text-subtle",
          text: "Installs on this browser"
        }),
        find,
        list,
        empty,
        el(doc, "div", { class: "mt-1 border-t border-edge pt-1" }, [add, manage])
      ]
    )

    const scrim = phone
      ? el(doc, "div", {
          class: "fixed inset-x-0 bottom-0 top-0 z-40 bg-scrim",
          "data-role": "install-switch-scrim",
          onclick: () => close()
        })
      : null
    position(view, panel, scrim)

    const focused = doc.activeElement
    const refocus = focused && host.contains?.(focused) && focused.getAttribute?.("data-role") === "install-switch-find"
    host.replaceChildren(...[scrim, panel].filter(Boolean))
    if (refocus) panel.querySelector("[data-role='install-switch-find']")?.focus?.()
  }

  function rowClick(row, status) {
    if (row.current) return close()
    if (status === "unreachable") {
      refresh(row.origin)
      return
    }
    switchTo(row)
  }

  // ── Navigation ─────────────────────────────────────────────────────────

  function switchTo(row) {
    const origin = S.allowedOrigin(row.origin)
    if (!origin) return
    close()
    showModal({ kind: "switching", name: row.name })
    win.location.assign(origin + "/")
  }

  function startHop(origin, label) {
    const target = S.allowedOrigin(origin)
    if (!target) return
    const here = win.location
    try {
      session?.setItem(
        S.PENDING_KEY,
        JSON.stringify({ origin: target, return: S.safeReturnPath(here.pathname + (here.search || "")), at: now() })
      )
    } catch {
      // A browser without sessionStorage cannot finish the add; the
      // connected page says so.
    }
    close()
    showModal({ kind: "hop", origin: target, label: label || S.hostOf(target) })
    setTimeout(() => {
      win.location.assign(`${target}/switcher/connect?origin=${encodeURIComponent(win.location.origin)}`)
    }, HOP_DELAY_MS)
  }

  // ── Modals ─────────────────────────────────────────────────────────────

  function overlayHost(create = true) {
    let host = doc.getElementById?.("install-switch-overlay") || null
    if (!host && create && doc.body) {
      host = el(doc, "div", { id: "install-switch-overlay", "data-role": "install-switch-overlay" })
      doc.body.appendChild(host)
    }
    return host
  }

  function showModal(modal, variant) {
    ctl.modal = modal
    if (variant) ctl.modalVariant = variant
    renderModal()
  }

  function closeModal() {
    ctl.modal = null
    overlayHost(false)?.querySelector?.("[data-role='install-switch-modal']")?.remove?.()
  }

  function openAdd(view) {
    close()
    showModal({ kind: "add", value: "", phase: "idle" }, view.variant)
    overlayHost(false)?.querySelector?.("[data-role='install-switch-address']")?.focus?.()
  }

  function openManage(view) {
    close()
    showModal({ kind: "manage" }, view.variant)
  }

  async function submitAdd() {
    const m = ctl.modal
    if (!m || m.kind !== "add" || m.phase === "checking") return
    const origin = S.originFromInput(m.value)
    if (!origin || origin === win.location.origin) {
      m.phase = "notfound"
      return renderModal()
    }
    m.phase = "checking"
    renderModal()
    const found = await probe(origin)
    if (ctl.modal !== m) return
    if (!found) {
      m.phase = "notfound"
      return renderModal()
    }
    startHop(origin)
  }

  function removeInstall(origin) {
    const entry = S.removeEntry(local, origin)
    ctl.states.delete(origin)
    ctl.tokens.delete(origin)
    reload()
    if (entry?.key) revokeRemote(entry)
    if (entry) showToast(`Removed ${entry.name}`)
    ctl.modal = others().length ? { kind: "manage" } : null
    if (ctl.modal) renderModal()
    else closeModal()
    paint()
  }

  // Best effort, never awaited: the entry is already gone locally.
  function revokeRemote(entry) {
    try {
      Promise.resolve(
        fetchImpl(entry.origin + "/api/switcher/key", {
          method: "DELETE",
          mode: "cors",
          credentials: "omit",
          referrerPolicy: "no-referrer",
          redirect: "error",
          keepalive: true,
          headers: { Authorization: "Bearer " + entry.key }
        })
      ).catch(() => {})
    } catch {
      // unreachable install: nothing to do
    }
  }

  function modalFrame(children, { sheet = false, label }) {
    const card = el(
      doc,
      "div",
      {
        role: "dialog",
        "aria-modal": "true",
        "aria-label": label,
        class: sheet
          ? "relative w-full rounded-t-2xl border border-edge bg-base-100 p-5 pb-8 shadow-xl"
          : "relative w-full max-w-md rounded-2xl border border-edge bg-base-100 p-5 shadow-xl"
      },
      children
    )
    return el(
      doc,
      "div",
      {
        class: "fixed inset-0 z-[60] flex justify-center " + (sheet ? "items-end" : "items-center p-4"),
        "data-role": "install-switch-modal",
        "data-kind": ctl.modal?.kind
      },
      [
        el(doc, "div", {
          class: "absolute inset-0 bg-scrim",
          "data-role": "install-switch-modal-scrim",
          onclick: () => {
            if (ctl.modal && ctl.modal.kind !== "hop" && ctl.modal.kind !== "switching") closeModal()
          }
        }),
        card
      ]
    )
  }

  function title(text, role) {
    return el(doc, "h2", { class: "text-base font-semibold text-base-content", "data-role": role, text })
  }

  function body(text, role) {
    return el(doc, "p", { class: "mt-2 text-sm leading-relaxed text-subtle", "data-role": role, text })
  }

  function spinner() {
    return el(doc, "span", {
      class: "inline-block size-5 animate-spin rounded-full border-2 border-primary border-t-transparent",
      "aria-hidden": "true"
    })
  }

  function buildModal() {
    const m = ctl.modal
    const sheet = ctl.modalVariant !== "sidebar"
    const here = current()

    if (m.kind === "add") {
      const checking = m.phase === "checking"
      const input = el(doc, "input", {
        id: "install-switch-address",
        type: "text",
        inputmode: "url",
        autocomplete: "url",
        autocapitalize: "off",
        spellcheck: "false",
        placeholder: "burrow.yourteam.com",
        "data-role": "install-switch-address",
        class:
          "mt-1 w-full rounded-lg border border-edge bg-base-100 px-3 py-2 text-sm text-base-content placeholder:text-subtle focus:outline-none focus:ring-2 focus:ring-primary",
        oninput: event => {
          m.value = event?.target?.value ?? ""
        },
        onkeydown: event => {
          if (event.key === "Enter") {
            event.preventDefault?.()
            submitAdd()
          }
        }
      })
      input.value = m.value
      const children = [
        title("Add an install", "install-switch-add-title"),
        body(
          "Enter the address your team uses for Burrow. We'll open it so you can sign in there, then bring you back.",
          "install-switch-add-body"
        ),
        el(doc, "label", { for: "install-switch-address", class: "mt-4 block text-xs font-medium text-subtle", text: "Address" }),
        input,
        m.phase === "notfound"
          ? el(doc, "p", {
              class: "mt-2 text-sm text-error",
              "data-role": "install-switch-notfound",
              text: "Couldn't find Burrow at this address. Check the spelling, or ask your admin for the link."
            })
          : null,
        el(doc, "div", { class: "mt-5 flex justify-end gap-2" }, [
          el(doc, "button", { type: "button", class: GHOST_BTN, text: "Cancel", onclick: () => closeModal() }),
          el(
            doc,
            "button",
            {
              type: "button",
              class: PRIMARY_BTN + " gap-2",
              "data-role": "install-switch-check",
              disabled: checking,
              onclick: () => submitAdd()
            },
            checking ? [spinnerSmall(), "Checking"] : ["Check and add"]
          )
        ])
      ]
      return modalFrame(children, { sheet, label: "Add an install" })
    }

    if (m.kind === "hop") {
      const host = S.hostOf(m.origin)
      return modalFrame(
        [
          el(doc, "div", { class: "flex items-center gap-3" }, [spinner(), title(`Opening ${m.label}`, "install-switch-hop-title")]),
          body(
            `${host} needs to say it's OK to show its unread here. If you're not signed in there yet, it will ask you to sign in first, with its own sign-in.`,
            "install-switch-hop-body"
          ),
          body(`You'll come back to ${here.name} when that's done.`, "install-switch-hop-back")
        ],
        { sheet: false, label: `Opening ${m.label}` }
      )
    }

    if (m.kind === "switching") {
      return modalFrame(
        [
          el(doc, "div", { class: "flex items-center gap-3" }, [spinner(), title(`Opening ${m.name}`, "install-switch-switching-title")]),
          body("Already signed in with the same account? You go straight in.", "install-switch-switching-body")
        ],
        { sheet: false, label: `Opening ${m.name}` }
      )
    }

    if (m.kind === "manage") {
      const items = rows().map(row => {
        const status = rowStatus(row)
        const actions = []
        if (row.current) {
          actions.push(
            el(doc, "span", {
              class: "shrink-0 rounded-md border border-edge px-1.5 py-0.5 text-xs text-subtle",
              text: "This install"
            })
          )
        } else {
          if (status === "reconnect") {
            actions.push(
              el(doc, "button", {
                type: "button",
                class: "shrink-0 rounded-md px-2 py-1 text-sm font-medium text-primary hover:bg-base-content/8 focus-visible-ring",
                "data-role": "install-manage-reconnect",
                text: "Reconnect",
                onclick: () => startHop(row.origin, row.name)
              })
            )
          }
          actions.push(
            el(doc, "button", {
              type: "button",
              class: "shrink-0 rounded-md px-2 py-1 text-sm font-medium text-error hover:bg-base-content/8 focus-visible-ring",
              "data-role": "install-manage-remove",
              "data-origin": row.origin,
              text: "Remove",
              onclick: () => showModal({ kind: "remove", origin: row.origin, name: row.name })
            })
          )
        }
        return el(doc, "li", { class: "flex items-center gap-2.5 py-2", "data-role": "install-manage-row", "data-origin": row.origin }, [
          logoTile(row),
          el(doc, "span", { class: "flex min-w-0 flex-1 flex-col" }, [
            el(doc, "span", { class: "truncate text-sm font-medium text-base-content", "data-role": "install-row-name", text: row.name }),
            el(doc, "span", { class: "truncate text-xs text-subtle", text: row.host })
          ]),
          ...actions
        ])
      })
      return modalFrame(
        [
          title("Manage installs", "install-manage-title"),
          body(
            "These installs are saved in this browser only. Removing one doesn't sign you out of it or delete anything there.",
            "install-manage-body"
          ),
          el(doc, "ul", { class: "mt-3 max-h-[50vh] divide-y divide-edge overflow-y-auto" }, items),
          el(doc, "div", { class: "mt-4 flex justify-end" }, [
            el(doc, "button", { type: "button", class: PRIMARY_BTN, "data-role": "install-manage-done", text: "Done", onclick: () => closeModal() })
          ])
        ],
        { sheet, label: "Manage installs" }
      )
    }

    if (m.kind === "remove") {
      return modalFrame(
        [
          title(`Remove ${m.name} from this switcher?`, "install-remove-title"),
          body(
            `It stops showing here, and ${here.name} stops getting its unread count. You stay signed in to ${m.name}, and nothing there is deleted. You can add it again any time.`,
            "install-remove-body"
          ),
          el(doc, "div", { class: "mt-5 flex justify-end gap-2" }, [
            el(doc, "button", { type: "button", class: GHOST_BTN, text: "Cancel", onclick: () => showModal({ kind: "manage" }) }),
            el(doc, "button", {
              type: "button",
              class:
                "inline-flex items-center justify-center rounded-lg bg-error px-4 py-2 text-sm font-medium text-error-content focus-visible-ring",
              "data-role": "install-remove-confirm",
              text: "Remove",
              onclick: () => removeInstall(m.origin)
            })
          ])
        ],
        { sheet, label: "Remove install" }
      )
    }
    return null
  }

  function spinnerSmall() {
    return el(doc, "span", {
      class: "inline-block size-4 animate-spin rounded-full border-2 border-primary-content border-t-transparent",
      "aria-hidden": "true"
    })
  }

  function renderModal() {
    const host = overlayHost(true)
    if (!host || !ctl.modal) return
    host.querySelector?.("[data-role='install-switch-modal']")?.remove?.()
    const node = buildModal()
    if (node) host.appendChild(node)
  }

  // ── Toasts ─────────────────────────────────────────────────────────────

  function showToast(text) {
    const host = overlayHost(true)
    if (!host) return
    host.querySelector?.("[data-role='install-switch-toast']")?.remove?.()
    const toast = el(doc, "div", {
      role: "status",
      "data-role": "install-switch-toast",
      class:
        "fixed bottom-24 left-1/2 z-[70] -translate-x-1/2 rounded-full border border-edge bg-base-300 px-4 py-2 text-sm text-base-content shadow-lg lg:bottom-6",
      text
    })
    host.appendChild(toast)
    setTimeout(() => toast.remove?.(), TOAST_MS)
  }

  function showPendingToast() {
    let text = null
    try {
      text = session?.getItem(S.TOAST_KEY)
      session?.removeItem(S.TOAST_KEY)
    } catch {
      text = null
    }
    if (typeof text === "string" && text) showToast(text.slice(0, 200))
  }

  return {
    attach,
    detach,
    updated,
    refresh,
    stop,
    // test seams
    _ctl: ctl,
    _submitAdd: submitAdd,
    _removeInstall: removeInstall
  }
}

let shared = null

/** The page's one web controller (both switchers attach to it). */
export function webSwitch(env) {
  if (!shared) shared = createWebSwitch(env)
  return shared
}

export function __resetWebSwitchForTests() {
  shared?.stop()
  shared = null
}

/**
 * Mount the web path for a NativeInstallSwitch hook. Returns null (and does
 * nothing) on a Capacitor native platform: an app build without
 * `installBadges` keeps today's hidden button.
 */
export function mountWebSwitch(hook, env) {
  const win = env?.win || globalThis.window
  if (win?.Capacitor?.isNativePlatform?.()) return null
  const controller = webSwitch(env)
  const view = controller.attach(hook.el)
  return {
    updated: () => controller.updated(view),
    destroyed: () => controller.detach(view)
  }
}
