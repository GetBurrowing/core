// Shared session helper for the 01a05873 desktop-follow harness.
// Same CDP-over-Node-22-WebSocket approach as ../01a0419a-desktop-verify —
// no npm dependencies; `cdp.mjs` is copied verbatim from that directory.
import { http, Conn, sleep } from "./cdp.mjs";

export const PORT = process.env.SPORT || "4000";
// The app may live on a remote dev box (dev-on-moon serves it from moon
// while this driver runs on hive) — APP_HOST overrides `localhost`.
export const APP_HOST = process.env.APP_HOST || "localhost";
export const SLUG = process.env.SPACE_SLUG || "follow-probe";
export const OUT_DIR = process.env.OUT_DIR || "./results";

/**
 * An ISOLATED browser context (own cookie jar) — CDP port 9222 is shared
 * with sibling agents on this box and one Chrome profile is one identity,
 * so the reader and the sender MUST NOT share a context or the second
 * /dev/login would re-login the first.
 */
export async function session(W, H, slug) {
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
      throw new Error(
        (r.exceptionDetails.exception?.description || JSON.stringify(r.exceptionDetails)).slice(0, 1200),
      );
    return r.result.value;
  };

  const nav = async (url) => {
    await S("Page.navigate", { url });
    for (let i = 0; i < 150; i++) {
      await sleep(200);
      if ((await evalp("document.readyState")) === "complete") break;
    }
  };

  const login = () => nav(`http://${APP_HOST}:${PORT}/dev/login?as=${slug}`);
  return { browser, S, evalp, nav, login, targetId, browserContextId, slug };
}

/** Poll until `expression` returns truthy, or throw after `timeoutMs`. */
export async function until(evalp, expression, timeoutMs = 20000, everyMs = 250, label = expression) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await evalp(expression);
    if (last) return last;
    await sleep(everyMs);
  }
  throw new Error(`timeout waiting for: ${label} (last=${JSON.stringify(last)?.slice(0, 200)})`);
}

export { sleep };
