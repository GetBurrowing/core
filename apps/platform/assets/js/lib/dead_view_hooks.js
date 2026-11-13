/**
 * Mounts a LiveView hook on dead views.
 *
 * `phx-hook` only runs inside a LiveView, but the Console Glass gaming pages
 * (/play, /games/*) are controller-rendered and still carry components that
 * have one: the brand's install switcher (`NativeInstallSwitch`) and the
 * workspace's phone tab bar (`TabPill` on `#bottom-nav`, `NativeTabBar` on
 * its `#native-tab-bridge`). This runs the named hook object on every
 * element that names it and is not inside a LiveView root, with the hook's
 * only input, `this.el`. A page is never patched without a LiveView, so
 * `updated()` never needs to run here.
 */
export function installDeadViewHook(doc, name, hook) {
  const mounted = []
  for (const el of doc?.querySelectorAll?.(`[phx-hook='${name}']`) || []) {
    if (el.closest?.("[data-phx-session]")) continue
    if (el.dataset.deadViewHook === "mounted") continue
    el.dataset.deadViewHook = "mounted"
    const instance = Object.assign(Object.create(hook), { el })
    instance.mounted()
    mounted.push(instance)
  }
  return mounted
}
