const assert = require('node:assert/strict')
const http = require('node:http')
const fs = require('node:fs/promises')
const path = require('node:path')
const {chromium} = require('/tmp/sign-in-setup-playwright/node_modules/playwright')
const root = '/tmp/sign-in-setup-evidence'
;(async () => {
  const server = http.createServer(async (req,res) => {
    try {
      const target = path.resolve(root, '.' + new URL(req.url,'http://localhost').pathname)
      assert.ok(target.startsWith(root + '/'))
      const data = await fs.readFile(target)
      const ext = path.extname(target)
      res.setHeader('Content-Type', ({'.html':'text/html','.css':'text/css','.svg':'image/svg+xml','.woff2':'font/woff2','.png':'image/png'})[ext] || 'application/octet-stream')
      res.end(data)
    } catch {res.writeHead(404);res.end()}
  })
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve))
  const browser = await chromium.launch({headless:true,args:['--no-sandbox']})
  try {
    for (const [name,viewport] of [['phone',{width:390,height:844}],['desktop',{width:1440,height:900}]]) {
      const page = await browser.newPage({viewport})
      await page.goto(`http://127.0.0.1:${server.address().port}/sign-in.html`)
      assert.ok(await page.locator('#invitation-sign-in').isVisible())
      assert.ok(await page.locator('#email-setup-request').isVisible())
      assert.ok(await page.locator('#passkey-sign-in').isVisible())
      await page.getByLabel('Invitation or sign-in link').fill('https://install.example.test/auth/link?token=example')
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1))
      await page.screenshot({path:path.join(root,name + '-sign-in.png'),fullPage:true,animations:'disabled'})
      await page.goto(`http://127.0.0.1:${server.address().port}/code.html`)
      assert.ok(await page.locator('#email-setup-complete').isVisible())
      assert.equal(await page.locator('#email-setup-request').count(),0)
      await page.getByLabel('Setup code').fill('example-code')
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1))
      await page.screenshot({path:path.join(root,name + '-code.png'),fullPage:true,animations:'disabled'})
      await page.close()
      console.log(name + ': invitation, code and returning-passkey screens rendered without overflow')
    }
  } finally {await browser.close();server.close()}
})().catch(e => {console.error(e);process.exitCode=1})
