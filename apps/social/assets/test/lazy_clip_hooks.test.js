import {describe, it, expect, vi} from "vitest"
import {lazyClipHook} from "../js/hooks/lazy_clip_hooks.js"
const flush = async () => { await Promise.resolve(); await Promise.resolve() }
const context = () => ({el: {dataset: {}, querySelector: vi.fn(() => null)}})
describe("lazy player hook lifecycle", () => {
  it("loads on mount, binds helpers and reads the latest DOM state", async () => {
    let resolve
    const loader = vi.fn(() => new Promise(r => {resolve = r}))
    const hook = lazyClipHook("Player", loader), ctx = context()
    expect(loader).not.toHaveBeenCalled()
    hook.mounted.call(ctx); ctx.el.dataset.audio = "mute"; hook.updated.call(ctx)
    const impl = {helper() {return this.el.dataset.audio}, mounted: vi.fn(function () {this.value = this.helper()}), updated: vi.fn(), destroyed: vi.fn()}
    resolve({Player: impl}); await flush()
    expect(ctx.value).toBe("mute"); expect(impl.mounted).toHaveBeenCalledTimes(1)
    hook.updated.call(ctx); expect(impl.updated).toHaveBeenCalledTimes(1)
    hook.destroyed.call(ctx); expect(impl.destroyed).toHaveBeenCalledTimes(1)
  })
  it("does not mount after destruction while loading", async () => {
    let resolve
    const hook = lazyClipHook("Player", () => new Promise(r => {resolve = r})), ctx = context()
    hook.mounted.call(ctx); hook.destroyed.call(ctx)
    const mounted = vi.fn(); resolve({Player: {mounted}}); await flush()
    expect(mounted).not.toHaveBeenCalled()
  })
  it("shows the existing media error if the asset fails", async () => {
    const status = {hidden: true}, video = {setAttribute: vi.fn()}
    const ctx = {el: {querySelector: vi.fn(s => s === "video" ? video : status)}}
    const hook = lazyClipHook("Player", () => Promise.reject(new Error("asset unavailable")))
    hook.mounted.call(ctx); await flush()
    expect(status.hidden).toBe(false); expect(video.setAttribute).toHaveBeenCalledWith("hidden", "")
  })
})
