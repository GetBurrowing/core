const {chromium} = require(process.env.GAME_PAGE_PLAYWRIGHT)
const assert = require('node:assert/strict')
const path = require('node:path')
;(async () => {
  const browser = await chromium.launch({headless: true, args: ['--no-sandbox']})
  const origin = 'http://127.0.0.1:8765'
  try {
    for (const mobile of [false, true]) {
      const context = await browser.newContext({viewport: mobile ? {width:390,height:844} : {width:1440,height:900},
        userAgent: mobile ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1' : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36'})
      await context.grantPermissions(['clipboard-read', 'clipboard-write'], {origin})
      const page = await context.newPage()
      const errors = []
      page.on('pageerror', error => errors.push(error.message))
      await page.route('https://fonts.googleapis.com/**', route => route.abort())
      await page.goto(origin + '/game-page-evidence/visitor.html')
      await page.waitForFunction(() => document.getElementById('public-game')?.dataset.gamePageReady === 'true')
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, 'horizontal overflow')
      assert.equal(await page.locator('img').evaluateAll(images => images.every(img => img.complete && img.naturalWidth > 0)), true, 'missing game art or logo')
      assert.notEqual(await page.evaluate(() => getComputedStyle(document.body).overflowY), 'hidden', 'page cannot scroll')
      if (mobile) {
        assert.equal(await page.locator('#game-copy-link').isVisible(), true)
        await page.locator('#game-copy-link').click()
        await page.waitForFunction(() => document.querySelector('[data-game-status]').textContent.includes('copied'))
        await page.screenshot({path:path.join(process.env.GAME_PAGE_SCREENSHOTS, 'phone.png'), fullPage:true})
        await page.locator('[data-game-windows-override]').click()
      }
      assert.equal(await page.locator('#game-sign-in').isVisible(), true)
      const signIn = await page.locator('#game-sign-in').boundingBox()
      assert.ok(!mobile || signIn.y < 850, 'primary action buried below descriptive sections')
      await page.locator('.gp-foot').scrollIntoViewIfNeeded()
      assert.equal(await page.locator('.gp-foot').isVisible(), true)
      await page.evaluate(() => window.scrollTo(0, 0))
      await page.screenshot({path:path.join(process.env.GAME_PAGE_SCREENSHOTS, mobile ? 'phone-windows-override.png' : 'desktop.png'), fullPage:true})
      assert.deepEqual(errors, [], 'page JavaScript errors')
      const community = await context.newPage()
      await community.goto(origin + '/game-page-evidence/community.html')
      await community.waitForFunction(() => document.getElementById('public-game')?.dataset.gamePageReady === 'true')
      assert.equal(await community.locator('#game-live-chat').isVisible(), true)
      assert.equal(await community.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, 'community horizontal overflow')
      if (mobile) {
        await community.setViewportSize({width:390, height:500})
        await community.waitForFunction(() => parseFloat(document.querySelector('#public-game').style.getPropertyValue('--game-viewport-height')) <= 500)
        assert.ok((await community.locator('.gp-room').boundingBox()).height <= 410, 'chat ignores the reduced viewport')
        await community.setViewportSize({width:390, height:844})
      }
      await community.screenshot({path:path.join(process.env.GAME_PAGE_SCREENSHOTS, mobile ? 'community-phone.png' : 'community-desktop.png'), fullPage:true})
      for (const state of ['gaming-visitor', 'gaming-owner', 'gaming-empty', 'gaming-three', 'gaming-create', 'gaming-discover']) {
        const gaming = await context.newPage()
        await gaming.goto(origin + '/game-page-evidence/' + state + '.html')
        assert.equal(await gaming.locator('#gaming-home').isVisible(), true)
        assert.notEqual(await gaming.evaluate(() => getComputedStyle(document.body).overflowY), 'hidden', 'gaming catalog cannot scroll')
        const bottom = gaming.locator('#gaming-home').locator('a').last()
        if (await bottom.count()) {
          await bottom.scrollIntoViewIfNeeded()
          const box = await bottom.boundingBox()
          assert.ok(box.y >= 0 && box.y + box.height <= (mobile ? 844 : 900) + 1, 'catalog footer action unreachable')
        }
        await gaming.evaluate(() => window.scrollTo(0, 0))
        assert.equal(await gaming.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, 'gaming home overflow')
        if (['gaming-visitor', 'gaming-owner', 'gaming-three'].includes(state)) assert.equal(await gaming.locator('#gaming-play').isVisible(), true)
        if (state === 'gaming-owner') assert.equal(await gaming.locator(mobile ? '#gaming-publish-mobile' : '#gaming-create').isVisible(), true)
        if (state === 'gaming-three') {
          await gaming.locator('[data-game-tile]').first().focus()
          await gaming.keyboard.press('ArrowRight')
          assert.equal(await gaming.locator('#game-tile-sky-haulers').evaluate(el => document.activeElement === el), true, 'arrow navigation failed')
          assert.equal(await gaming.locator('#game-tile-sky-haulers').evaluate(el => document.documentElement.style.getPropertyValue('--cg-tint') === el.dataset.gameTint), true, 'focus should tint the game backdrop')
          await gaming.keyboard.press('ArrowRight')
          assert.equal(await gaming.locator('#game-tile-tiny-tactics').evaluate(el => document.activeElement === el), true)
          await gaming.keyboard.press('ArrowLeft')
          assert.equal(await gaming.locator('#game-tile-sky-haulers').evaluate(el => document.activeElement === el), true)
          await gaming.locator('[data-game-tile]').first().focus()
          await gaming.locator('.cg-shelf').evaluate(el => el.scrollLeft = 0)
          assert.equal(await gaming.locator('[data-game-tile]').first().evaluate(el => document.activeElement === el && getComputedStyle(el).outlineStyle === 'solid' && parseFloat(getComputedStyle(el).outlineWidth) >= 3), true, 'selected tile must have a visible white focus ring')
          await gaming.evaluate(() => window.scrollTo(0, 0))
        }
        await gaming.screenshot({path:path.join(process.env.GAME_PAGE_SCREENSHOTS, state + (mobile ? '-phone.png' : '-desktop.png')), fullPage:true})
      }
      for (const slug of ['voltron', 'sky-haulers', 'tiny-tactics']) {
        const game = await context.newPage()
        await game.goto(origin + '/game-page-evidence/gaming-game-' + slug + '.html')
        assert.equal(await game.locator('#console-glass-shell').isVisible(), true)
        assert.equal(await game.locator('#community-tab').isVisible(), true, 'game community tab must remain reachable')
        assert.equal(await game.locator('#game-tab').isVisible(), true)
        assert.equal(await game.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, 'game page overflow')
        await game.locator('.gp-foot').scrollIntoViewIfNeeded()
        await game.evaluate(() => window.scrollTo(0,0))
        await game.screenshot({path:path.join(process.env.GAME_PAGE_SCREENSHOTS, 'gaming-game-' + slug + (mobile ? '-phone.png' : '-desktop.png')),fullPage:true})
      }
      const workspace = await context.newPage()
      await workspace.goto(origin + '/game-page-evidence/gaming-workspace.html')
      assert.equal(await workspace.locator('#chat-panes').isVisible(), true, 'existing chat workspace missing')
      if (!mobile) {
        assert.equal(await workspace.locator('#gaming-project-context').isVisible(), true, 'game project context missing')
        assert.equal(await workspace.locator('#gaming-more-modules a[href="/files"]').isVisible(), false, 'secondary modules should start collapsed')
        await workspace.locator('#gaming-more-modules summary').click()
        assert.equal(await workspace.locator('#gaming-more-modules a[href="/files"]').isVisible(), true, 'secondary modules must remain accessible')
        await workspace.locator('#gaming-more-modules summary').click()
      }
      assert.equal(await workspace.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, 'workspace overflow')
      await workspace.screenshot({path:path.join(process.env.GAME_PAGE_SCREENSHOTS, 'gaming-workspace' + (mobile ? '-phone.png' : '-desktop.png')), fullPage:true})
      await context.close()
    }
  } finally { await browser.close() }
})().catch(error => {console.error(error);process.exitCode=1})
