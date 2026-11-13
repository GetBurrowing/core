/**
 * Mounts the install switcher hook on dead views (`#gaming-install-switch`
 * on /play and /games/*). See `dead_view_hooks.js`.
 */
import NativeInstallSwitch from "../hooks/native_install_switch.js"
import { installDeadViewHook } from "./dead_view_hooks.js"

export function installDeadViewInstallSwitch(doc = globalThis.document, hook = NativeInstallSwitch) {
  return installDeadViewHook(doc, "NativeInstallSwitch", hook)
}
