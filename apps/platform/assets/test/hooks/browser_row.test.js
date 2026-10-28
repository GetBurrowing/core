import {describe, it, expect, vi, beforeEach, afterEach} from "vitest"
import BrowserRow from "../../js/hooks/browser_row"
import BrowserScope from "../../js/hooks/browser_scope"

function target(dataset = {}) {
  const listeners = new Map()
  return {
    dataset,
    addEventListener(type, fn, opts) { listeners.set(type + (opts === true ? ':capture' : ''), fn) },
    removeEventListener(type, fn, opts) { const key = type + (opts === true ? ':capture' : ''); if (listeners.get(key) === fn) listeners.delete(key) },
    fire(type, attrs = {}, capture = false) {
      const event = {target: {closest: () => false}, preventDefault: vi.fn(), stopPropagation: vi.fn(), ...attrs}
      listeners.get(type + (capture ? ':capture' : ''))?.(event)
      return event
    },
  }
}
let doc
beforeEach(() => { vi.useFakeTimers(); doc = target(); vi.stubGlobal('document', doc); vi.stubGlobal('navigator', {}) })
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals() })
function mount() {
  const el = target({longPressEvent: 'browser_open_actions', longPressKind: 'canvas', longPressId: 'c1'})
  const hook = Object.assign(Object.create(BrowserRow), {el, pushEvent: vi.fn()})
  hook.mounted()
  return {el, hook}
}
const touch = (x,y) => ({touches: [{clientX:x, clientY:y}]})
describe('BrowserRow uses RowLongPress', () => {
  it('450ms opens actions and only the release click is swallowed', () => {
    const {el, hook} = mount()
    el.fire('touchstart', touch(10,10)); vi.advanceTimersByTime(449)
    expect(hook.pushEvent).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(hook.pushEvent).toHaveBeenCalledWith('browser_open_actions', {kind:'canvas',id:'c1'})
    el.fire('touchend')
    expect(doc.fire('click',{},true).preventDefault).toHaveBeenCalled()
    expect(doc.fire('click',{},true).preventDefault).not.toHaveBeenCalled()
    hook.destroyed()
  })
  it('more than 10px cancels, native scroll listeners remain passive', () => {
    const {el,hook} = mount()
    el.fire('touchstart',touch(0,0)); el.fire('touchmove',touch(0,11)); vi.advanceTimersByTime(500)
    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(doc.fire('click',{},true).preventDefault).not.toHaveBeenCalled()
    hook.destroyed()
  })
  it('right-click and Shift-F10 open once without swallowing the next action click', () => {
    const {el,hook} = mount()
    expect(el.fire('contextmenu').preventDefault).toHaveBeenCalled()
    el.fire('keydown',{key:'F10',shiftKey:true})
    expect(hook.pushEvent).toHaveBeenCalledTimes(2)
    expect(doc.fire('click',{},true).preventDefault).not.toHaveBeenCalled()
    hook.destroyed()
  })
  it('inputs and buttons own their gestures; editing leaves native context menus alone', () => {
    const {el,hook} = mount()
    el.fire('touchstart',{...touch(0,0), target:{closest:()=>true}}); vi.advanceTimersByTime(500)
    expect(hook.pushEvent).not.toHaveBeenCalled()
    el.dataset.editing='true'
    expect(el.fire('contextmenu').preventDefault).not.toHaveBeenCalled()
    hook.destroyed()
  })
  it('a release with no click does not consume a subsequent real tap', () => {
    const {el,hook}=mount()
    el.fire('touchstart',touch(0,0));vi.advanceTimersByTime(450);el.fire('touchend');vi.advanceTimersByTime(251)
    expect(doc.fire('click',{},true).preventDefault).not.toHaveBeenCalled()
    hook.destroyed()
  })
})
describe('BrowserScope', () => {
  it('scrolls an eligible source into view, rings exactly 1.5s, and does not renew on patches', () => {
    const row={dataset:{itemId:'c1',kind:'canvas'},scrollIntoView:vi.fn(),classList:{add:vi.fn(),remove:vi.fn()}}
    const hook=Object.assign(Object.create(BrowserScope),{el:{dataset:{highlight:'c1'},querySelectorAll:sel=>sel==='[data-item-id]'?[row]:[]}})
    hook.mounted()
    expect(row.scrollIntoView).toHaveBeenCalledWith({block:'nearest',behavior:'instant'})
    expect(row.classList.add).toHaveBeenCalledWith('browser-source-ring')
    vi.advanceTimersByTime(1499);expect(row.classList.remove).not.toHaveBeenCalled()
    hook.updated();vi.advanceTimersByTime(1)
    expect(row.classList.remove).toHaveBeenCalledWith('browser-source-ring')
    hook.updated();expect(row.scrollIntoView).toHaveBeenCalledTimes(1)
    hook.destroyed()
  })
  it('ignores missing and non-canvas sources', () => {
    const row={dataset:{itemId:'c1',kind:'file'},scrollIntoView:vi.fn()}
    const hook=Object.assign(Object.create(BrowserScope),{el:{dataset:{highlight:'c1'},querySelectorAll:sel=>sel==='[data-item-id]'?[row]:[]}})
    hook.mounted();expect(row.scrollIntoView).not.toHaveBeenCalled();hook.destroyed()
  })
})
