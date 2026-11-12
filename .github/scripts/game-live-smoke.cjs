// Read-only checks against a deployed gaming install. No accounts or releases are created.
const assert = require('node:assert/strict')
const fs = require('node:fs/promises')
const path = require('node:path')
const {chromium} = require(process.env.GAME_LIVE_PLAYWRIGHT)

;(async () => {
  const url = new URL(process.env.GAME_LIVE_ORIGIN)
  assert.equal(url.protocol, 'https:')
  assert.ok(/^[a-z0-9.-]+$/i.test(url.hostname) && url.hostname.includes('.') && !/^(\d+\.){3}\d+$/.test(url.hostname), 'Use a public HTTPS hostname')
  assert.ok(!url.username && !url.password && !url.search && !url.hash && url.pathname === '/' && (!url.port || url.port === '443'), 'Pass an origin without credentials or a path')
  const origin = url.origin
  const expected = (process.env.GAME_LIVE_GAMES || '').split(',').map(s => s.trim()).filter(Boolean)
  assert.ok(expected.every(slug => /^[a-z0-9][a-z0-9-]{0,63}$/.test(slug)))
  const revision = process.env.GAME_LIVE_COMMIT || ''
  assert.ok(!revision || /^[a-f0-9]{7,40}$/.test(revision))
  await fs.mkdir(process.env.GAME_LIVE_SHOTS, {recursive:true})
  const browser = await chromium.launch({headless:true, args:['--no-sandbox']})
  try {
    for (const mobile of [false, true]) {
      const device = mobile ? 'phone' : 'desktop'
      const context = await browser.newContext({viewport:mobile ? {width:390,height:844} : {width:1440,height:900},
        userAgent:mobile ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1' : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36'})
      const health = await context.request.get(origin + '/health')
      assert.equal(health.status(),200)
      const state = await health.json()
      assert.equal(state.status,'ok')
      if (revision) assert.ok(state.commit.startsWith(revision), 'Deployment revision differs from the requested revision')
      const page = await context.newPage()
      const errors = []
      page.on('pageerror', error => errors.push(error.message))
      await page.route('https://fonts.googleapis.com/**', route => route.abort())
      const visit = async (route, name) => {
        const response = await page.goto(origin + route, {waitUntil:'domcontentloaded'})
        assert.equal(response.status(),200,route)
        assert.equal(new URL(page.url()).origin,origin,'Public game navigation left the install')
        await page.evaluate(() => document.fonts.ready)
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1),route + ' overflows horizontally')
        if (name) await page.screenshot({path:path.join(process.env.GAME_LIVE_SHOTS,device + '-' + name + '.png'),fullPage:true,animations:'disabled'})
      }
      await visit('/','home')
      assert.equal(new URL(page.url()).pathname,'/play')
      assert.ok(await page.locator('#console-glass-shell').isVisible())
      const games = await page.locator('[data-game-tile]').evaluateAll(tiles => tiles.map(tile => new URL(tile.href).pathname.split('/').pop()))
      if (expected.length) assert.deepEqual(games,expected,'Catalog order or membership differs')
      assert.ok(games.length > 0 && games.length <= 30,'Use a bounded catalog for this smoke check')
      assert.equal(await page.locator('#gaming-create').count(),0,'Anonymous visitors must not see publishing controls')
      if (games.length > 1) {
        await page.locator('[data-game-tile]').first().focus()
        await page.keyboard.press('ArrowRight')
        assert.ok(await page.locator('[data-game-tile]').nth(1).evaluate(el => document.activeElement === el))
        const title = await page.locator('[data-game-tile] h3').last().innerText()
        await visit('/play?mode=discover')
        await page.locator('#game-search input[name="catalog[q]"]').fill(title)
        await page.locator('#game-search button[type=submit]').click()
        await page.waitForURL(u => u.searchParams.get('catalog[q]') === title)
        assert.equal(await page.locator('[data-game-tile]').count(),1,'Live search did not narrow the catalog')
      }
      await visit('/play?mode=discover','discover')
      await visit('/play?mode=create','create-anonymous')
      assert.equal(await page.locator('#gaming-projects a[href^="/chat/"],#gaming-projects a[href^="/files/"]').count(),0,'Anonymous project links leaked')
      for (const slug of games) {
        await visit('/games/' + slug,slug)
        await page.waitForFunction(() => document.getElementById('public-game')?.dataset.gamePageReady === 'true')
        assert.ok(await page.locator('#community-tab').isVisible())
        const shots = page.locator('[data-game-shot]')
        const count = await shots.count()
        if (count) {
          await shots.first().focus()
          await page.keyboard.press('Enter')
          assert.ok(await page.locator('#game-lightbox').evaluate(el => el.open))
          if (count > 1) await page.keyboard.press('ArrowRight')
          await page.keyboard.press('Escape')
          await page.waitForFunction(() => !document.querySelector('#game-lightbox').open)
          await page.waitForFunction(() => document.activeElement?.hasAttribute('data-game-shot'))
        }
        await visit('/games/' + slug + '?tab=community',slug + '-community')
        assert.equal(await page.locator('#game-live-chat').count(),0,'Anonymous visitors must join before receiving chat')
        await visit('/games/' + slug + '/sign-in',slug + '-sign-in')
        const continuation = new URL(await page.locator('#continue-sign-in').getAttribute('href'),origin)
        assert.equal(continuation.pathname,'/auth/login')
        assert.equal(continuation.searchParams.get('game'),slug)
        const metaResponse = await context.request.get(origin + '/games/' + slug + '/updates')
        assert.equal(metaResponse.status(),200)
        const meta = await metaResponse.json()
        assert.equal(meta.download_path,'/games/' + slug + '/player/releases/' + meta.version)
        const denied = await context.request.get(origin + meta.download_path,{maxRedirects:0})
        assert.equal(denied.status(),401,'Native release accepted an anonymous request')
        const player = await context.request.get(origin + '/games/' + slug + '/player',{maxRedirects:0})
        assert.ok([302,303].includes(player.status()))
        assert.equal(player.headers().location,'/games/' + slug + '/sign-in')
        console.log(`${device}: ${slug} page, gallery (${count}), community, sign-in and download gates passed`)
      }
      assert.deepEqual(errors,[],'Live browser errors')
      await context.close()
      console.log(`${device}: public catalog, search and anonymous Create access passed at ${state.commit}`)
    }
  } finally {await browser.close()}
})().catch(error => {console.error(error);process.exitCode=1})
