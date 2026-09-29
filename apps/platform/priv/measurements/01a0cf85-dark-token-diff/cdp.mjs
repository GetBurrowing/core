// Minimal CDP driver over Node's built-in WebSocket (Node 22+).
// CDP_PORT picks the Chrome this run drives; launch that Chrome yourself
// (see README) so the colour profile flag is guaranteed.
export const CDP_HOST = `127.0.0.1:${process.env.CDP_PORT || "9222"}`;

export async function http(path, method = "GET") {
  const r = await fetch(`http://${CDP_HOST}${path}`, { method });
  const t = await r.text();
  try {
    return JSON.parse(t);
  } catch {
    return t;
  }
}

export class Conn {
  constructor(url) {
    this.url = url;
    this.id = 0;
    this.pending = new Map();
  }

  async open() {
    this.ws = new WebSocket(this.url);
    await new Promise((res, rej) => {
      this.ws.onopen = res;
      this.ws.onerror = rej;
    });
    this.ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const { res, rej } = this.pending.get(m.id);
        this.pending.delete(m.id);
        m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
      }
    };
    return this;
  }

  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(
        JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }),
      );
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          rej(new Error("timeout " + method));
        }
      }, 60000);
    });
  }

  close() {
    this.ws.close();
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * One isolated browser context per run: its own cookie jar, so a dev login
 * here cannot disturb any other tab driving the same Chrome.
 */
export async function isolatedPage(W, H) {
  const ver = await http("/json/version");
  const browser = await new Conn(ver.webSocketDebuggerUrl).open();
  const { browserContextId } = await browser.send("Target.createBrowserContext", {
    disposeOnDetach: true,
  });
  const { targetId } = await browser.send("Target.createTarget", {
    url: "about:blank",
    browserContextId,
  });
  const { sessionId } = await browser.send("Target.attachToTarget", { targetId, flatten: true });
  const S = (m, p) => browser.send(m, p, sessionId);
  await S("Page.enable");
  await S("Runtime.enable");
  await S("Emulation.setDeviceMetricsOverride", {
    width: W,
    height: H,
    deviceScaleFactor: 1,
    mobile: false,
  });

  const evaluate = async (expression) => {
    const r = await S("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 800));
    return r.result.value;
  };

  const navigate = async (url) => {
    await S("Page.navigate", { url });
    for (let i = 0; i < 150; i++) {
      await sleep(200);
      if ((await evaluate("document.readyState")) === "complete") break;
    }
    await sleep(500);
  };

  const close = async () => {
    await browser.send("Target.disposeBrowserContext", { browserContextId }).catch(() => {});
    browser.close();
  };

  return { S, evaluate, navigate, close, version: ver.Browser };
}
