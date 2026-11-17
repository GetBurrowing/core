const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const {chromium} = require(process.env.STUDIO_PLAYWRIGHT);
(async () => {
  const root = '/tmp/studio-evidence';
  const server = http.createServer(async (req, res) => {
    const file = path.join(root, new URL(req.url, 'http://localhost').pathname);
    try {
      const bytes = await fs.readFile(file);
      res.setHeader('Content-Type', file.endsWith('.css') ? 'text/css' : file.endsWith('.js') ? 'text/javascript' : file.endsWith('.svg') ? 'image/svg+xml' : file.endsWith('.png') ? 'image/png' : 'text/html');
      res.end(bytes);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(8766, '127.0.0.1', resolve));
  const browser = await chromium.launch({headless: true});
  try {
    for (const [name, width, height] of [['desktop', 1440, 1000], ['phone', 390, 844]]) {
      const context = await browser.newContext({viewport: {width, height}});
      const page = await context.newPage();
      await page.route('**/live/**', route => route.abort());
      await page.goto('http://127.0.0.1:8766/studio.html');
      await page.locator('#game-studio').waitFor();
      await page.screenshot({path: `/tmp/studio-screens/studio-${name}.png`});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, `${name} horizontal overflow`);
      const box = await page.locator('.studio-conversation').boundingBox();
      assert.ok(box && box.width > 260 && box.height > 180, `${name} usable conversation`);
      if (name === 'phone') {
        const nav = await page.locator('#bottom-nav').boundingBox();
        assert.ok(nav && nav.y + nav.height <= height, 'phone dock is reachable');
        assert.equal(await page.locator('#bottom-nav [data-destination]').count(), 5);
      }
      await context.close();
    }
  } finally { await browser.close(); server.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
