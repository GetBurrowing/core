import {describe, it, expect, vi} from "vitest"
import Hook, {previewWindow} from "../js/hooks/closing_video_preview.js"
describe("rendered join preview", () => {
  it("starts two content seconds before the immutable seam", () => {
    expect(previewWindow(42,46)).toEqual({start:40,seam:42,total:46,fraction:42/46})
    expect(previewWindow(1,5).start).toBe(0)
    for (const [a,b] of [[null,4],[0,4],[5,4],[NaN,8],[4,Infinity]]) expect(previewWindow(a,b)).toBeNull()
  })
  it("uses one existing file and removes listeners on destruction", () => {
    const listeners = new Map(), video = {currentTime:0,duration:6.2,readyState:1,addEventListener:vi.fn((n,f)=>listeners.set(n,f)),removeEventListener:vi.fn()}
    const progress = {}, marker={style:{}}, status={hidden:true}
    const ctx={el:{dataset:{seam:"5",total:"6.2"},querySelector: s=>s==="video"?video:s.includes("playhead")?progress:s.includes("error")?status:marker}}
    Hook.mounted.call(ctx)
    expect(video.currentTime).toBe(3)
    expect(marker.style.left).toBe(`${5/6.2*100}%`)
    video.currentTime=5.5;listeners.get("timeupdate")();expect(progress.value).toBe(5.5/6.2)
    ctx.el.dataset.audio="mute";Hook.updated.call(ctx);expect(video.muted).toBe(true)
    ctx.el.dataset.audio="keep";Hook.updated.call(ctx);expect(video.muted).toBe(false)
    listeners.get("error")();expect(video.hidden).toBe(true);expect(status.hidden).toBe(false)
    Hook.destroyed.call(ctx);expect(video.removeEventListener).toHaveBeenCalledTimes(3)
  })
})
