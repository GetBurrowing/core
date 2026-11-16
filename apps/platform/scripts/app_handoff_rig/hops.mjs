#!/usr/bin/env node
// app_handoff_rig/hops.mjs: record every hop a handoff URL takes in a browser
// with its own cookie store (task 01a1e58b stage 1).
//
// WHAT IT DOES
//   1. Opens a NEW CDP target with `PUT /json/new`. It never attaches to an
//      existing page: the CDP Chrome on the rig is shared between agents.
//   2. Creates a FRESH browser context (`Target.createBrowserContext`) and a
//      page inside it. That context's empty cookie jar stands in for the
//      native app's web view, which shares no cookies with the system
//      browser sheet. It is NOT WKWebView; say so wherever you quote output.
//   3. Turns on Network and loads the handoff URL (and optionally a second
//      URL, e.g. `/`, in the same context afterwards).
//   4. Prints each hop: URL (query values redacted), status, Location (query
//      values redacted) and the Set-Cookie ATTRIBUTE NAMES with the cookie
//      name. Then prints `Network.getCookies` for the host: name, domain,
//      path, httpOnly, secure, sameSite, session. Cookie VALUES, handoff codes
//      and bearer tokens are never printed.
//   5. Disposes the context and closes the target it opened, by id.
//
// USAGE
//   node hops.mjs <handoff-url> [then-url ...]
//   CDP=http://127.0.0.1:9222 node hops.mjs "$HANDOFF_URL" https://host/
//
//   Pass the handoff URL through an env var, not a literal on a command line
//   that lands in shell history or a log. Mint it with POST /api/app/handoff
//   (bearer) and keep the bearer out of anything that prints.
//
// RIG NOTE: if the CDP Chrome cannot reach the dev server's LAN address
// (net::ERR_ADDRESS_UNREACHABLE, printed as a FAILED hop), tunnel the dev
// server to loopback (ssh -f -N -L 127.0.0.1:<p>:<dev-host-ip>:<port>) and
// mint the handoff against that loopback origin; close the tunnel by pid.
//
// Requires Node 22+ (global fetch and WebSocket).

const CDP = process.env.CDP || "http://127.0.0.1:9222";
const urls = process.argv.slice(2);

if (urls.length === 0) {
  console.error("usage: node hops.mjs <handoff-url> [then-url ...]");
  process.exit(2);
}

// Keep path and parameter NAMES, drop every parameter value.
function redact(raw) {
  if (!raw) return raw;
  try {
    const u = new URL(raw, urls[0]);
    const keys = [...u.searchParams.keys()];
    const q = keys.length ? "?" + keys.map((k) => `${k}=<redacted>`).join("&") : "";
    return `${u.origin}${u.pathname}${q}`;
  } catch {
    return "<unparseable>";
  }
}

// "name=value; Path=/; HttpOnly; SameSite=Lax" -> "name [Path=/, HttpOnly, SameSite=Lax]"
// Attribute values kept only for the non-secret attributes.
const SAFE_VALUE_ATTRS = new Set(["path", "domain", "samesite", "max-age", "expires"]);

function describeSetCookie(header) {
  return header
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [pair, ...attrs] = line.split(";").map((s) => s.trim());
      const name = pair.split("=")[0];
      const shown = attrs.map((a) => {
        const [k, v] = a.split("=");
        return v !== undefined && SAFE_VALUE_ATTRS.has(k.toLowerCase()) ? `${k}=${v}` : k;
      });
      return `${name} [${shown.join(", ")}]`;
    });
}

function header(headers, name) {
  const key = Object.keys(headers || {}).find((k) => k.toLowerCase() === name);
  return key ? headers[key] : undefined;
}

class Session {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.listeners = [];
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
      } else if (msg.method) {
        for (const l of this.listeners) l(msg);
      }
    };
  }
  open() {
    return new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = () => reject(new Error("CDP websocket failed"));
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    const msg = { id, method, params };
    if (sessionId) msg.sessionId = sessionId;
    this.ws.send(JSON.stringify(msg));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }
  on(fn) {
    this.listeners.push(fn);
  }
  close() {
    this.ws.close();
  }
}

async function main() {
  // 1. A NEW target, never page[0].
  const opened = await (await fetch(`${CDP}/json/new?about:blank`, { method: "PUT" })).json();
  const version = await (await fetch(`${CDP}/json/version`)).json();
  const browser = new Session(version.webSocketDebuggerUrl);
  await browser.open();

  let contextId;
  let pageTargetId;
  try {
    // 2. A fresh cookie store: the app web view's stand-in.
    ({ browserContextId: contextId } = await browser.send("Target.createBrowserContext", {
      disposeOnDetach: true,
    }));
    ({ targetId: pageTargetId } = await browser.send("Target.createTarget", {
      url: "about:blank",
      browserContextId: contextId,
    }));
    const { sessionId } = await browser.send("Target.attachToTarget", {
      targetId: pageTargetId,
      flatten: true,
    });

    // 3. Network on.
    const hops = [];
    const extra = new Map(); // requestId -> raw Set-Cookie from ExtraInfo
    browser.on((msg) => {
      if (msg.sessionId !== sessionId) return;
      const p = msg.params;
      if (msg.method === "Network.requestWillBeSent" && p.type === "Document") {
        if (p.redirectResponse) {
          hops.push({
            requestId: p.requestId,
            url: p.redirectResponse.url,
            status: p.redirectResponse.status,
            location: header(p.redirectResponse.headers, "location"),
            setCookie: header(p.redirectResponse.headers, "set-cookie"),
            sentCookieNames: null,
          });
        }
      } else if (msg.method === "Network.requestWillBeSentExtraInfo") {
        const names = (p.associatedCookies || [])
          .filter((c) => !c.blockedReasons || c.blockedReasons.length === 0)
          .map((c) => c.cookie.name);
        extra.set(`sent:${p.requestId}:${extra.size}`, { url: null, names });
      } else if (msg.method === "Network.responseReceivedExtraInfo") {
        const sc = header(p.headers, "set-cookie");
        if (sc) extra.set(`recv:${p.requestId}:${extra.size}`, sc);
      } else if (msg.method === "Network.loadingFailed" && p.type === "Document") {
        hops.push({ requestId: p.requestId, url: null, status: `FAILED ${p.errorText}` });
      } else if (msg.method === "Network.responseReceived" && p.type === "Document") {
        hops.push({
          requestId: p.requestId,
          url: p.response.url,
          status: p.response.status,
          location: header(p.response.headers, "location"),
          setCookie: header(p.response.headers, "set-cookie"),
        });
      }
    });

    await browser.send("Network.enable", {}, sessionId);
    await browser.send("Page.enable", {}, sessionId);

    for (const url of urls) {
      const loaded = new Promise((resolve) => {
        const timer = setTimeout(resolve, 15000);
        browser.on((msg) => {
          if (msg.sessionId === sessionId && msg.method === "Page.loadEventFired") {
            clearTimeout(timer);
            resolve();
          }
        });
      });
      console.log(`== navigate ${redact(url)}`);
      const before = hops.length;
      await browser.send("Page.navigate", { url }, sessionId);
      await loaded;
      // 4. Hops for this navigation.
      for (const h of hops.slice(before)) {
        const loc = h.location ? ` -> ${redact(h.location)}` : "";
        const sc = h.setCookie ? `  set-cookie: ${describeSetCookie(h.setCookie).join("; ")}` : "";
        console.log(`  ${h.status} ${redact(h.url)}${loc}${sc}`);
      }
    }

    // Set-Cookie headers Chrome only reports through ExtraInfo (names + attrs).
    const recv = [...extra.entries()].filter(([k]) => k.startsWith("recv:"));
    if (recv.length) {
      console.log("== set-cookie seen (ExtraInfo)");
      for (const [, sc] of recv) console.log(`  ${describeSetCookie(sc).join("; ")}`);
    }
    const sent = [...extra.entries()].filter(([k]) => k.startsWith("sent:"));
    if (sent.length) {
      console.log("== cookie names sent per request, in order (ExtraInfo)");
      for (const [, s] of sent) console.log(`  [${s.names.join(", ")}]`);
    }

    // Final cookie jar for the host(s): names and attributes only.
    const { cookies } = await browser.send(
      "Network.getCookies",
      { urls: [...new Set(urls.map((u) => new URL(u).origin))] },
      sessionId
    );
    console.log("== cookies in the fresh context");
    for (const c of cookies) {
      console.log(
        `  ${c.name} domain=${c.domain} path=${c.path} httpOnly=${c.httpOnly} ` +
          `secure=${c.secure} sameSite=${c.sameSite || "unset"} session=${c.session}`
      );
    }
  } finally {
    // 5. Clean up only what this run created.
    if (pageTargetId) await browser.send("Target.closeTarget", { targetId: pageTargetId }).catch(() => {});
    if (contextId) await browser.send("Target.disposeBrowserContext", { browserContextId: contextId }).catch(() => {});
    browser.close();
    await fetch(`${CDP}/json/close/${opened.id}`).catch(() => {});
  }
}

main().catch((e) => {
  console.error(`hops.mjs: ${e.message}`);
  process.exit(1);
});
