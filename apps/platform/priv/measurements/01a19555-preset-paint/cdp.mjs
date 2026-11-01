// Minimal CDP driver over Node 22's built-in WebSocket, mirroring
// ../01a0419a-desktop-verify/cdp.mjs. One difference: the host is an
// argument, because one run drives two browsers (one per build).

export async function http(host, path) {
  const r = await fetch(`http://${host}${path}`);
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
        const { res, rej, timer } = this.pending.get(m.id);
        clearTimeout(timer);
        this.pending.delete(m.id);
        m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
      }
    };
    return this;
  }

  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          rej(new Error("timeout " + method));
        }
      }, 60000);
      this.pending.set(id, { res, rej, timer });
      this.ws.send(
        JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }),
      );
    });
  }

  close() {
    this.ws.close();
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * A page in its own browser context on the Chrome at `host`, DPR 1.
 * The context is disposed on close, so nothing outlives the run.
 */
export async function isolatedPage(host, W, H) {
  const ver = await http(host, "/json/version");
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

  const resize = (width, height) =>
    S("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
  await resize(W, H);

  const evaluate = async (expression) => {
    const r = await S("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 800));
    return r.result.value;
  };

  // Replace the document wholesale; wait until it has laid out.
  const setContent = async (html) => {
    const { frameTree } = await S("Page.getFrameTree");
    await S("Page.setDocumentContent", { frameId: frameTree.frame.id, html });
    for (let i = 0; i < 100; i++) {
      if ((await evaluate("document.readyState")) === "complete") break;
      await sleep(50);
    }
    // Two animation frames: style, layout and paint have all run once.
    await evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))");
  };

  const close = async () => {
    await browser.send("Target.disposeBrowserContext", { browserContextId }).catch(() => {});
    browser.close();
  };

  return { S, evaluate, setContent, resize, close, version: ver.Browser, userAgent: ver["User-Agent"] };
}
