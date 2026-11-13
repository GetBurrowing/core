/**
 * Mounts the phone tab bar's hooks on dead views: the gaming shell renders
 * the workspace's `bottom_rail/1` on /play and /games/*. `TabPill` places the
 * sliding pill and `NativeTabBar` bridges the iOS app's native bar (it is
 * inert outside a native build that has one). See `dead_view_hooks.js`.
 */
import TabPill from "../hooks/tab_pill.js"
import NativeTabBar from "../hooks/native_tab_bar.js"
import { installDeadViewHook } from "./dead_view_hooks.js"

export function installDeadViewTabBar(doc = globalThis.document, hooks = { TabPill, NativeTabBar }) {
  return Object.entries(hooks).flatMap(([name, hook]) => installDeadViewHook(doc, name, hook))
}
