/**
 * Mounts the install switcher hook on dead views.
 *
 * `phx-hook` only runs inside a LiveView, but the Console Glass gaming pages
 * (/play, /games/*) are controller-rendered and still carry the brand's
 * install switcher (`#gaming-install-switch`). This runs the same
 * `NativeInstallSwitch` hook object on every switch button that is not inside
 * a LiveView root, with the hook's only input, `this.el`. A page is never
 * patched without a LiveView, so `updated()` never needs to run here.
 */
import NativeInstallSwitch from "../hooks/native_install_switch.js"

const SELECTOR = "[phx-hook='NativeInstallSwitch']"

export function installDeadViewInstallSwitch(doc = globalThis.document, hook = NativeInstallSwitch) {
  const mounted = []
  for (const el of doc?.querySelectorAll?.(SELECTOR) || []) {
    if (el.closest?.("[data-phx-session]")) continue
    if (el.dataset.deadViewHook === "mounted") continue
    el.dataset.deadViewHook = "mounted"
    const instance = Object.assign(Object.create(hook), { el })
    instance.mounted()
    mounted.push(instance)
  }
  return mounted
}
