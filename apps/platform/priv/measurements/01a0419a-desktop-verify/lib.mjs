import { http, Conn, sleep } from "./cdp.mjs";

export const PORT = process.env.SPORT || "4021";
export const SPACE = process.env.SPACE_ID;
export const OUT_DIR = process.env.OUT_DIR || "/Volumes/Dev/tmp/01a0419a-s5";

/**
 * Open an ISOLATED browser context. CDP port 9222 is shared with sibling
 * agents on this box and one Chrome profile is one identity — a second
 * /dev/login in the shared default context re-logs-in whoever else is
 * driving it. `Target.createBrowserContext` gives this run its own cookie
 * jar so nothing here can disturb a sibling, and nothing a sibling does
 * can disturb these numbers.
 */
export async function session(W, H) {
  const ver = await http("/json/version");
  const browser = await new Conn(ver.webSocketDebuggerUrl).open();
  const { browserContextId } = await browser.send("Target.createBrowserContext", {
    disposeOnDetach: false,
  });
  const { targetId } = await browser.send("Target.createTarget", {
    url: "about:blank",
    browserContextId,
    width: W,
    height: H,
  });
  const { sessionId } = await browser.send("Target.attachToTarget", {
    targetId,
    flatten: true,
  });
  const S = (m, p) => browser.send(m, p, sessionId);
  await S("Page.enable");
  await S("Runtime.enable");
  await S("DOM.enable");
  await S("CSS.enable");
  await S("Emulation.setDeviceMetricsOverride", {
    width: W,
    height: H,
    deviceScaleFactor: 1,
    mobile: false,
    screenWidth: W,
    screenHeight: H,
  });

  const evalp = async (expression) => {
    const r = await S("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (r.exceptionDetails)
      throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 800));
    return r.result.value;
  };

  const nav = async (url) => {
    await S("Page.navigate", { url });
    for (let i = 0; i < 120; i++) {
      await sleep(200);
      if ((await evalp("document.readyState")) === "complete") break;
    }
  };

  return { browser, S, evalp, nav, targetId, browserContextId };
}

/** Screenshot -> raw RGBA pixel reader, for pixel-sampled contrast. */
export async function grabPixels(S, evalp, clip) {
  const { data } = await S("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  const px = await evalp(`(async () => {
    const img = new Image();
    img.src = "data:image/png;base64,${data}";
    await img.decode();
    const c = document.createElement("canvas");
    c.width = img.width; c.height = img.height;
    const g = c.getContext("2d");
    g.drawImage(img, 0, 0);
    const box = ${JSON.stringify(clip)};
    const d = g.getImageData(box.x, box.y, box.w, box.h).data;
    return { w: box.w, h: box.h, data: Array.from(d) };
  })()`);
  return px;
}

export const srgb = (v) => {
  const c = v / 255;
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
};
export const lum = ([r, g, b]) =>
  0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b);
export const ratio = (a, b) => {
  const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m);
  return (x + 0.05) / (y + 0.05);
};
