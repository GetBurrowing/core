// Opt-in real-browser suite: start a dev server with the fixture in
// test/platform_web/live/chat/mobile_mention_browser_fixture.exs, then run:
// MOBILE_MENTION_URL=http://127.0.0.1:4000 PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs
// node --test test/mobile_mention_geometry_test.mjs
// Connects to agent-owned CDP; creates/closes its own contexts, never shared tabs.
// Resize and visualViewport pan below are SIMULATIONS, not a physical keyboard test.
import test from 'node:test'
import assert from 'node:assert/strict'
import {mkdir, writeFile} from 'node:fs/promises'
import {pathToFileURL} from 'node:url'

const base = process.env.MOBILE_MENTION_URL
const output = process.env.MOBILE_MENTION_ARTIFACTS
const selectors = {
  channel: {field: '#compose_text', box: '#compose-mention-list-wrap', list: '#compose-mention-list', value: '#compose_text_value'},
  thread: {field: '.thread-input', box: '.thread-field-box .mention-list-box', list: '.thread-field-box .mention-list-box', value: '.thread-field-box textarea[hidden]'}
}

async function geometry(page, kind) {
  return page.evaluate(({field, box, list}) => {
    const entry = document.querySelector(field)
    const wrapper = document.querySelector(box)
    const panel = wrapper?.matches('.mention-list-panel') ? wrapper : wrapper?.querySelector('.mention-list-panel')
    // Thread .mention-list-box is itself inside the panel.
    const actualPanel = panel || wrapper?.closest('.mention-list-panel')
    const rect = el => { const r = el.getBoundingClientRect(); return {top:r.top,bottom:r.bottom,left:r.left,right:r.right,height:r.height} }
    const vv = window.visualViewport
    const p = actualPanel.getBoundingClientRect()
    const hit = y => document.elementsFromPoint((p.left+p.right)/2,y).some(el => el===actualPanel || actualPanel.contains(el))
    return {input:rect(entry), panel:rect(actualPanel), focused:document.activeElement===entry,
      panelPainted:hit(p.top+2) && hit(p.bottom-2),
      viewport:{top:vv.offsetTop,bottom:vv.offsetTop+vv.height,left:vv.offsetLeft,right:vv.offsetLeft+vv.width},
      scrollHeight:document.querySelector(list).scrollHeight, listHeight:document.querySelector(list).clientHeight}
  }, selectors[kind])
}

function assertGeometry(g) {
  assert(g.panel.height > 0, 'panel has nonzero visible height')
  assert(g.panel.bottom <= g.input.top + 1, 'panel must be above entry')
  assert(g.panel.top >= g.viewport.top - 1, 'panel top inside visualViewport')
  assert(g.panel.bottom <= g.viewport.bottom + 1, 'panel bottom inside visualViewport')
  assert(g.panel.left >= g.viewport.left - 1 && g.panel.right <= g.viewport.right + 1, 'panel horizontally visible')
  assert(g.panelPainted, 'panel top and bottom are hit-testable, not ancestor-clipped or covered')
  assert(g.input.top >= g.viewport.top - 1 && g.input.bottom <= g.viewport.bottom + 1, 'input inside visualViewport')
  assert(g.focused, 'input retains focus after LiveView patch')
}

async function open(page, kind, theme) {
  await page.goto(base + '/dev/login?as=mobile-mention')
  await page.goto(base + '/chat/mobile-mention')
  await page.waitForFunction(() => window.liveSocket?.isConnected())
  await page.waitForFunction(() => document.documentElement.style.getPropertyValue('--compose-mention-max-h') !== '')
  await page.evaluate(theme => document.documentElement.dataset.theme=theme, theme)
  if (kind === 'thread') {
    await page.locator('#compose_text').fill('channel draft sentinel')
    await page.locator('[aria-label="Reply in thread"]').first().evaluate(el => el.click())
    await page.locator(selectors.thread.field).first().waitFor()
  }
}

async function typeAtCaret(page, kind, text = 'before @ after') {
  const field = page.locator(selectors[kind].field).first()
  await field.fill(text)
  await field.evaluate(el => {
    const range = document.createRange()
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    let node
    while ((node = walker.nextNode()) && !node.textContent.includes('@')) {}
    if (!node) throw new Error('mention trigger text node missing')
    range.setStart(node, node.textContent.indexOf('@') + 1)
    range.collapse(true)
    const selection = getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
    el.dispatchEvent(new Event('input', {bubbles:true}))
  })
  await page.locator(selectors[kind].list).waitFor({state:'visible'})
  await page.waitForTimeout(300)
  return field
}

// Same event path as e2e/tests/chat_notification_viewport.spec.ts: render the
// real prompt rather than synthesizing banner DOM or requiring push credentials.
async function showNotificationPrompt(page) {
  await page.evaluate(() => window.liveSocket.main.pushHookEvent(
    document.querySelector('#push-subscribe'), null,
    'push_permission_state', {state:'prompt'}, () => {}
  ))
  await page.locator('[data-role="chat-notification-banner"]').waitFor({state:'attached'})
  await page.waitForTimeout(100)
}

test('actual mobile mention geometry, focus, caret, rotation and mutation controls', {skip: !base, timeout:180000}, async () => {
  const module = process.env.PLAYWRIGHT_MODULE || new URL('../../../../e2e/node_modules/playwright/index.mjs', import.meta.url).href
  const {chromium} = await import(module.startsWith('/') ? pathToFileURL(module).href : module)
  const browser = await chromium.connectOverCDP(process.env.CDP_URL || 'http://127.0.0.1:9222')
  const results = []
  if (output) await mkdir(output, {recursive:true})
  try {
    for (const kind of ['channel','thread']) for (const theme of ['light','dark']) {
      const ctx = await browser.newContext({viewport:{width:375,height:812},isMobile:true,hasTouch:true,serviceWorkers:'block'})
      try {
        const page = await ctx.newPage()
        page.setDefaultTimeout(12000)
        await open(page, kind, theme)
        await page.locator(selectors[kind].field).first().focus()
        for (const [orientation, viewport] of [['portrait',{width:375,height:482}],['landscape',{width:812,height:195}]]) {
          await page.setViewportSize(viewport)
          const field = await typeAtCaret(page, kind)
          await showNotificationPrompt(page)
          const g = await geometry(page, kind)
          assertGeometry(g)
          assert(g.scrollHeight > g.listHeight, 'long results scroll internally')
          assert((await page.locator(selectors[kind].list + ' [data-kind]').first().getAttribute('data-kind')) === 'agent', 'agents first')
          if (output) await page.screenshot({path:output + '/' + kind + '-' + orientation + '-' + theme + '.png'})
          // Mutate the actual rendered cap/anchor. The first attempted wrapper
          // top override survived because channel results are in flow; recorded
          // in stage evidence, not counted as a successful mutation control.
          if (orientation === 'landscape') {
            const style = await page.addStyleTag({content: kind === 'channel'
              ? '#compose-form .mention-list-box {max-height:none !important}'
              : '.thread-field-box .mention-list {transform:none !important}'})
            await page.waitForTimeout(100)
            const mutated = await geometry(page, kind)
            console.log('mutation', kind, orientation, JSON.stringify({before:g,after:mutated}))
            assert.throws(() => assertGeometry(mutated), /panel must be above entry|inside visualViewport/, 'disabling cap/anchor must fail geometry guard')
            await style.evaluate(el => el.remove())
            await page.waitForTimeout(100)
            assertGeometry(await geometry(page, kind))
          }
          const row = page.locator(selectors[kind].list + ' [data-kind="agent"]').first()
          const name = await row.getAttribute('data-mention-name')
          await row.tap()
          await page.locator(selectors[kind].list).waitFor({state:'detached'})
          assert.equal(await field.innerText(), 'before @' + name + '\u00a0after')
          assert(await field.evaluate(el => document.activeElement===el))
          await page.keyboard.type(' continued')
          assert((await page.locator(selectors[kind].value).first().inputValue()).includes('continued'))
          if (kind === 'thread') assert.equal(await page.locator('#compose_text').innerText(),'channel draft sentinel')
          results.push({kind,theme,orientation,keyboard:'simulated viewport resize',geometry:g,insertion:true,mutationRejected:orientation === 'landscape'})
        }
        // Multiline drafts and zero matches must not steal the field or focus.
        await page.setViewportSize({width:375,height:482})
        const field = await typeAtCaret(page,kind,'line one\nline two @ after')
        assertGeometry(await geometry(page,kind))
        // Rotate while suggestions are OPEN, not just between selections.
        await page.setViewportSize({width:812,height:195})
        await page.waitForTimeout(300)
        assertGeometry(await geometry(page,kind))
        await page.setViewportSize({width:375,height:482})
        await page.waitForTimeout(300)
        assertGeometry(await geometry(page,kind))
        await field.fill('@no_agent_matches_987654321')
        await page.waitForTimeout(400)
        assert.equal(await page.locator(selectors[kind].list + ' [data-kind="agent"]').count(),0)
        assert(await field.evaluate(el => document.activeElement===el))
        // Pan simulation exercises the existing visualViewport scroll listener.
        await typeAtCaret(page,kind)
        await page.evaluate(() => {
          Object.defineProperty(visualViewport,'offsetTop',{configurable:true,get:()=>12})
          visualViewport.dispatchEvent(new Event('scroll'))
        })
        await page.waitForTimeout(300)
        assertGeometry(await geometry(page,kind))
        await page.evaluate(() => { delete visualViewport.offsetTop; visualViewport.dispatchEvent(new Event('scroll')) })
      } finally { await ctx.close() }
    }
    if (output) await writeFile(output + '/results.json', JSON.stringify(results,null,2))
    console.log(JSON.stringify({cases:results.length,keyboard:'simulated; no physical soft keyboard available',results}))
  } finally { await browser.close() }
})

test('desktop keyboard selection and mobile empty-room picker stay intact', {skip: !base, timeout:90000}, async () => {
  const module = process.env.PLAYWRIGHT_MODULE || new URL('../../../../e2e/node_modules/playwright/index.mjs', import.meta.url).href
  const {chromium} = await import(module.startsWith('/') ? pathToFileURL(module).href : module)
  const browser = await chromium.connectOverCDP(process.env.CDP_URL || 'http://127.0.0.1:9222')
  const ctx = await browser.newContext({viewport:{width:1280,height:800},serviceWorkers:'block'})
  try {
    const page = await ctx.newPage()
    page.setDefaultTimeout(12000)
    for (const kind of ['channel','thread']) {
      await open(page,kind,'light')
      for (const key of ['Enter','Tab']) {
        const field = await typeAtCaret(page,kind)
        await showNotificationPrompt(page)
        assert(await page.locator('[data-role="chat-notification-banner"]').isVisible())
        await page.keyboard.press('ArrowDown')
        const row = page.locator(selectors[kind].list + ' [aria-selected="true"]')
        const name = await row.getAttribute('data-mention-name')
        assert(name)
        await page.keyboard.press(key)
        await page.locator(selectors[kind].list).waitFor({state:'detached'})
        assert.equal(await field.innerText(),'before @' + name + '\u00a0after')
        assert(await field.evaluate(el => document.activeElement===el))
      }
    }
    await page.setViewportSize({width:375,height:812})
    await page.goto(base + '/chat/mobile-mention-empty')
    await page.locator('#empty-room-agents').waitFor()
    await page.getByRole('button',{name:'+ Add an agent',exact:true}).click()
    const picker = page.locator('.mention-list--pick .mention-list-panel')
    await picker.waitFor({state:'visible'})
    const r = await picker.boundingBox()
    assert(r.height > 0 && r.y >= 0 && r.y+r.height <= 812)
    await page.locator('.mention-list--pick [data-kind="agent"]:not([aria-disabled="true"])').first().click()
    await page.waitForTimeout(400)
    // Adding an agent does not send a chat message or erase the invitation.
    assert(await page.locator('#empty-room-agents').isVisible())
    console.log('desktop ArrowDown+Enter/Tab selections: 4 passed; empty-room Add agent: passed')
  } finally { await ctx.close(); await browser.close() }
})
