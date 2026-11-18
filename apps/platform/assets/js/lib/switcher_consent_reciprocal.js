/**
 * B's consent page (`/switcher/connect`, a dead view): when the person
 * answers, Allow or Not now, remember the install that asked (A) so B's own
 * switcher lists A back. See `rememberReciprocal` in install_switch_store.js.
 *
 * The origin is the one B's server validated and rendered into the form's
 * `data-reciprocal-origin`; the name is A's public display name. Nothing is
 * written on page load, only on an answer.
 */
import { rememberReciprocal } from "./install_switch_store.js"

export function installConsentReciprocal(doc = globalThis.document, win = globalThis.window) {
  const form = doc?.getElementById?.("switcher-consent-form")
  const origin = form?.getAttribute?.("data-reciprocal-origin")
  if (!form || !origin) return false

  let session = null
  try {
    session = win.sessionStorage || null // client-state:allow (fixed key, see install_switch_store.js)
  } catch {
    session = null
  }

  const remember = () =>
    rememberReciprocal(
      session,
      { origin, name: form.getAttribute("data-reciprocal-name") },
      win.location.origin
    )

  form.addEventListener("submit", remember)
  form.querySelector?.("[data-role='switcher-consent-cancel']")?.addEventListener?.("click", remember)
  return true
}
