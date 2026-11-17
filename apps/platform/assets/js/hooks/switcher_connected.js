/**
 * SwitcherConnected — install A's `/switcher/connected` page (task 01a1ccd4
 * stage 3). Install B's consent hop (stage 2) sends the browser here with
 * `#key=...&name=...&host=...` (no `key` when the person chose Cancel). The
 * fragment never reaches A's server.
 *
 * The hook accepts the answer only for the hop THIS browser started: the
 * switcher wrote `{origin, return, at}` to sessionStorage before leaving, and
 * the fragment's `host` must be that origin's host. So a link someone sends
 * cannot plant an entry. It saves `{origin, name, host, key, added_at}` to
 * `burrow.installs.v1`, strips the fragment with `history.replaceState`, and
 * returns to the page the person started from, where the switcher shows the
 * "Added <B>" toast.
 */

import * as S from "../lib/install_switch_store.js"

function storageOf(win, name) {
  try {
    return win[name] || null // client-state:allow (fixed key, see install_switch_store.js)
  } catch {
    return null
  }
}

/** Validate the fragment against the pending hop and save the entry. */
export function completeConnect({ hash, session, local, now = Date.now() }) {
  let pending = null
  try {
    pending = JSON.parse(session?.getItem(S.PENDING_KEY) || "null")
  } catch {
    pending = null
  }
  try {
    session?.removeItem(S.PENDING_KEY)
  } catch {
    // nothing to clear
  }

  const origin = S.allowedOrigin(pending?.origin)
  if (!origin) return { ok: false, reason: "no_pending" }
  if (typeof pending.at !== "number" || now - pending.at > S.PENDING_TTL_MS || pending.at > now + 60000) {
    return { ok: false, reason: "expired" }
  }

  const params = new URLSearchParams(String(hash || "").replace(/^#/, ""))
  if (params.get("host") !== S.hostOf(origin)) return { ok: false, reason: "host_mismatch" }

  const key = params.get("key")
  if (key !== null && !S.validBadgeKey(key)) return { ok: false, reason: "bad_key" }

  const entry = S.upsertEntry(local, {
    origin,
    name: params.get("name"),
    host: S.hostOf(origin),
    key,
    added_at: new Date(now).toISOString()
  })
  if (!entry) return { ok: false, reason: "not_saved" }

  return {
    ok: true,
    entry,
    toast: entry.key ? `Added ${entry.name}` : `Added ${entry.name} without its unread`,
    returnTo: S.safeReturnPath(pending.return)
  }
}

const SwitcherConnected = {
  mounted() {
    const win = window
    const session = storageOf(win, "sessionStorage")
    const local = storageOf(win, "localStorage")
    const hash = win.location.hash

    // The key must not stay in the address bar or the history entry.
    try {
      win.history.replaceState(null, "", win.location.pathname)
    } catch {
      // older browsers: the page navigates away below anyway
    }

    const result = completeConnect({ hash, session, local })
    const working = this.el.querySelector("[data-role='connected-working']")
    const invalid = this.el.querySelector("[data-role='connected-invalid']")

    if (!result.ok) {
      this.el.setAttribute("data-state", "invalid")
      working?.classList.add("hidden")
      invalid?.classList.remove("hidden")
      return
    }

    this.el.setAttribute("data-state", "added")
    try {
      session?.setItem(S.TOAST_KEY, result.toast)
    } catch {
      // no toast, still added
    }
    win.location.replace(result.returnTo)
  }
}

export default SwitcherConnected
