const {chromium} = require(process.env.GAME_PAGE_PLAYWRIGHT)
const assert = require('node:assert/strict')
const path = require('node:path')
;(async () => {
  const browser = await chromium.launch({headless: true, args: ['--no-sandbox']})
  const origin = 'http://127.0.0.1:8765'
  try {
    for (const mobile of [false, true]) {
      const context = await browser.newContext({viewport: mobile ? {width:390,height:844} : {width:1280,height:900},
        userAgent: mobile ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1' : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36'})
      await context.grantPermissions(['clipboard-read', 'clipboard-write'], {origin})
      const page = await context.newPage()
      const errors = []
      page.on('pageerror', error => errors.push(error.message))
      await page.route('https://fonts.googleapis.com/**', route => route.abort())
      await page.goto(origin + '/game-page-evidence/visitor.html')
      await page.waitForFunction(() => document.getElementById('public-game')?.dataset.gamePageReady === 'true')
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, 'horizontal overflow')
      const hero = page.locator('.gp-media img')
      assert.equal(await hero.evaluate(img => img.complete && img.naturalWidth > 0), true, 'missing game art')
      if (mobile) {
        assert.equal(await page.locator('#game-copy-link').isVisible(), true)
        await page.locator('#game-copy-link').click()
        await page.waitForFunction(() => document.querySelector('[data-game-status]').textContent.includes('copied'))
        await page.locator('[data-game-windows-override]').click()
      }
      assert.equal(await page.locator('#game-sign-in').isVisible(), true)
      const signIn = await page.locator('#game-sign-in').boundingBox()
      assert.ok(!mobile || signIn.y < 850, 'primary action buried below descriptive sections')
      await page.screenshot({path:path.join(process.env.GAME_PAGE_SCREENSHOTS, mobile ? 'phone.png' : 'desktop.png'), fullPage:true})
      assert.deepEqual(errors, [], 'page JavaScript errors')
      await context.close()
    }
  } finally { await browser.close() }
})().catch(error => {console.error(error);process.exitCode=1})
