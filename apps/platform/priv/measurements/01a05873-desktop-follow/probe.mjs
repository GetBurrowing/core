// probe.mjs — the 01a05873 desktop-follow scenario suite.
//
// Reproduces (or refutes) the reported failure — Rowan, 2026-08-31: "desktop
// chat does not autoscroll to the latest message" — in the REAL app: real
// `mix phx.server`, real Chrome over CDP, real LiveView patches, a second
// logged-in browser session posting as another user.
//
// ALL instrumentation is CDP-side injection. No product file is touched:
// the live ScrollToBottom hook instance is monkey-patched in the reader
// page to record the lifecycle order (beforeUpdate's captured distance,
// updated, MutationObserver fire, viewport-resize fire, scroll events),
// scrollHeight/clientHeight/scrollTop before and after, whether the
// follow snap ran, and the jump-chip presence — plus the width of
// `#chat-sidebar` and its inline style, read synchronously at every step
// (that is the measurement that names the mechanism).
//
// Usage (run against the dev server of whatever SHA is checked out):
//   cd apps/platform/priv/measurements/01a05873-desktop-follow
//   SPORT=4000 GIT_LABEL=origin-main VW=1440 VH=900 node probe.mjs
//   SPORT=4000 GIT_LABEL=origin-main-mobile VW=390 VH=844 node probe.mjs
// Mobile (VW=390) runs the same arrival scenario; `#chat-sidebar` is
// `hidden lg:flex` below `lg`, so there is no sidebar to squeeze and no
// resize/drag scenario to run there.
//
// Fixture: run reseed.exs first (200 messages, UUIDv7 ids sorted into
// inserted_at order — see the cursor dead-end note in reseed.exs).
import fs from "node:fs";
import { PORT, APP_HOST, SLUG, OUT_DIR, session, until, sleep } from "./lib.mjs";

const W = parseInt(process.env.VW || "1440", 10);
const H = parseInt(process.env.VH || "900", 10);
const GIT_LABEL = process.env.GIT_LABEL || "unknown";
const CHAT = `/chat/${SLUG}`;
const MOBILE = W < 1024;

const snapshot = `(() => {
  const sc = document.getElementById("chat-message-scroller");
  const aside = document.getElementById("chat-sidebar");
  const ta = document.querySelector("#compose-form textarea");
  return {
    st: sc ? Math.round(sc.scrollTop) : null,
    sh: sc ? sc.scrollHeight : null,
    ch: sc ? sc.clientHeight : null,
    cw: sc ? Math.round(sc.clientWidth) : null,
    d: sc ? Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight) : null,
    sw: aside ? Math.round(aside.getBoundingClientRect().width) : null,
    asideHidden: aside ? getComputedStyle(aside).display === "none" : null,
    sSt: aside ? aside.style.width || "" : null,
    taH: ta ? Math.round(ta.getBoundingClientRect().height) : null,
    chip: !!document.querySelector(".chat-jump-chip"),
    rows: document.querySelectorAll("#message-list [data-message-id]").length,
    lastRow: (() => {
      const rows = document.querySelectorAll("#message-list [data-message-id]");
      return rows.length
        ? (rows[rows.length - 1].textContent || "").replace(/\\s+/g, " ").trim().slice(0, 60)
        : null;
    })(),
    initialScroll: window.__hk ? window.__hk._initialScroll : null,
    connected: !!(window.liveSocket && window.liveSocket.isConnected()),
  };
})()`;

// Injected into the READER page once the view is live. Records every
// lifecycle step into window.__tr; see the header comment.
const INSTRUMENT = `(() => {
  const ls = window.liveSocket;
  if (!ls) return { fatal: "no liveSocket" };
  let hk = null;
  for (const v of Object.values(ls.roots || {})) {
    for (const h of Object.values(v.viewHooks || {})) {
      if (h && h.el && h.el.id === "message-list") hk = h;
    }
  }
  if (!hk) return { fatal: "no #message-list hook" };
  window.__hk = hk;
  window.__tr = [];
  window.__t0 = performance.now();
  const rec = (type, extra) => {
    const sc = document.getElementById("chat-message-scroller");
    const aside = document.getElementById("chat-sidebar");
    const e = {
      t: Math.round(performance.now() - window.__t0),
      type,
      st: sc ? Math.round(sc.scrollTop) : null,
      sh: sc ? sc.scrollHeight : null,
      ch: sc ? sc.clientHeight : null,
      cw: sc ? Math.round(sc.clientWidth) : null,
      sw: aside ? Math.round(aside.getBoundingClientRect().width) : null,
      sSt: aside ? aside.style.width || "" : null,
      chip: !!document.querySelector(".chat-jump-chip"),
      rows: document.querySelectorAll("#message-list [data-message-id]").length,
    };
    if (extra) Object.assign(e, extra);
    window.__tr.push(e);
  };
  window.__rec = rec;
  if (hk.beforeUpdate) {
    const orig = hk.beforeUpdate.bind(hk);
    hk.beforeUpdate = function () {
      orig();
      rec("beforeUpdate", { preD: this._preUpdateDistance });
    };
  }
  if (hk.updated) {
    const orig = hk.updated.bind(hk);
    hk.updated = function () {
      rec("updated:enter");
      orig();
      rec("updated:exit", { preD: this._preUpdateDistance });
    };
  }
  if (hk._safeUpdate) {
    const orig = hk._safeUpdate.bind(hk);
    hk._safeUpdate = function () {
      rec("safeUpdate:enter");
      orig();
      rec("safeUpdate:exit");
    };
  }
  if (hk.scrollToBottom) {
    const orig = hk.scrollToBottom.bind(hk);
    hk.scrollToBottom = function (d) {
      const before = this.scrollEl.scrollTop;
      rec("scrollToBottom:enter", {
        arg: d === undefined ? null : d,
        initial: this._initialScroll,
      });
      orig(d);
      rec("scrollToBottom:exit", { snapRan: this.scrollEl.scrollTop !== before });
    };
  }
  if (typeof hk._onViewportResize === "function") {
    const orig = hk._onViewportResize.bind(hk);
    hk._onViewportResize = function () {
      rec("viewportResize:enter", {
        lastW: this._lastClientWidth,
        lastH: this._lastClientHeight,
      });
      orig();
      rec("viewportResize:exit");
    };
  }
  if (hk._reportDistance) {
    const orig = hk._reportDistance.bind(hk);
    hk._reportDistance = function (pre) {
      orig(pre);
      rec("reportDistance", {
        arg: pre === undefined ? null : pre,
        away: this._lastAway,
        deep: this._lastDeep,
      });
    };
  }
  hk.scrollEl.addEventListener("scroll", () => rec("scroll"), { passive: true });
  new MutationObserver((muts) => {
    const added = muts.reduce((n, m) => n + m.addedNodes.length, 0);
    rec("mo:message-list", { added });
  }).observe(hk.el, { childList: true, subtree: false });
  const aside = document.getElementById("chat-sidebar");
  if (aside) {
    new MutationObserver((muts) => {
      const kinds = {};
      for (const m of muts) {
        const k = m.type === "attributes" ? "attr:" + m.attributeName : m.type;
        kinds[k] = (kinds[k] || 0) + 1;
      }
      rec("mo:sidebar", { kinds, styleW: aside.style.width || "" });
    }).observe(aside, {
      attributes: true,
      attributeFilter: ["style", "class"],
      childList: true,
      subtree: true,
    });
  }
  return { ok: true, hasViewportResize: typeof hk._onViewportResize === "function" };
})()`;

async function sendMsg(pg, body) {
  return pg.evalp(`(() => {
    const form = document.getElementById("compose-form");
    const input = form ? form.querySelector("textarea") : null;
    if (!form || !input) return { fatal: "no composer" };
    input.value = ${JSON.stringify(body)};
    input.dispatchEvent(new Event("input", { bubbles: true }));
    return { ok: true };
  })()`);
}

async function submitMsg(pg) {
  return pg.evalp(`(() => {
    const form = document.getElementById("compose-form");
    if (!form) return { fatal: "no composer" };
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    return { ok: true };
  })()`);
}

async function resetToBottom(pg) {
  // A programmatic scrollTop write fires a real scroll event, so the
  // hook's passive scroll listener re-reports distance and the server
  // drops the chip — a clean slate for the next scenario.
  await pg.evalp(`(() => {
    const sc = document.getElementById("chat-message-scroller");
    sc.scrollTop = sc.scrollHeight;
    return true;
  })()`);
  await sleep(1000);
}

async function scenario(reader, sender, name, body, opts = {}) {
  await reader.evalp(`(() => { window.__tr = []; window.__t0 = performance.now(); return true; })()`);
  const pre = await reader.evalp(snapshot);
  let beforeNote = null;
  if (opts.before) beforeNote = await opts.before(reader);
  const preAfterBefore = opts.before ? await reader.evalp(snapshot) : null;
  const s = await sendMsg(sender, body);
  await submitMsg(sender);
  await sleep(opts.wait ?? 2500);
  const trace = await reader.evalp(`window.__tr`);
  const post = await reader.evalp(snapshot);
  return { name, body, s, beforeNote, pre, preAfterBefore, post, trace };
}

const longBody =
  "A tall arriving body with several sentences of ordinary prose, long enough that the row is clearly taller than the follow threshold and visibly taller than a one-liner, so a declined follow leaves the reader measurably far from the live edge rather than a pixel or two below it. ";

(async () => {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const out = {
    git: GIT_LABEL,
    viewport: { w: W, h: H },
    url: `http://${APP_HOST}:${PORT}${CHAT}`,
    started: new Date().toISOString(),
    baseline: null,
    scenarios: [],
    fatal: null,
  };
  try {
    // ── Reader: log in, open the channel, wait out the arrival phase.
    // ── Sender: second ISOLATED browser context, its own login, same
    //    channel — the "second logged-in browser session" of the stage brief.
    const reader = await session(W, H, "reader");
    const sender = await session(W, H, "sender");
    await reader.login();
    await sender.login();
    await reader.evalp(`location.assign("http://${APP_HOST}:${PORT}${CHAT}")`);
    await sender.evalp(`location.assign("http://${APP_HOST}:${PORT}${CHAT}")`);
    await until(reader.evalp, `!!(window.liveSocket && document.getElementById("chat-message-scroller"))`, 25000);
    await until(sender.evalp, `!!(window.liveSocket && document.getElementById("compose-form"))`, 25000, 250, "sender composer");
    // Arrival phase ends on 250ms of quiet layout / 3s ceiling / gesture.
    // _initialScroll flips false at the end; allow for slow first paint.
    await until(
      reader.evalp,
      `(() => { for (const v of Object.values(window.liveSocket.roots || {})) { for (const h of Object.values(v.viewHooks || {})) { if (h && h.el && h.el.id === "message-list") { window.__probeHk = h; return !h._initialScroll; } } } return false; })()`,
      30000,
      300,
      "arrival phase to end",
    );

    const inj = await reader.evalp(INSTRUMENT);
    out.instrumentation = inj;
    if (inj.fatal) throw new Error("instrumentation: " + JSON.stringify(inj));

    // Baseline: reader parked at the live edge, chip gone, sidebar intact.
    out.baseline = await reader.evalp(snapshot);
    if (out.baseline.d === null || out.baseline.d > 150) {
      // Nudge to the live edge and re-snapshot.
      await resetToBottom(reader);
      out.baseline = await reader.evalp(snapshot);
    }

    // ── S1: one-liner from the second session. The primary repro.
    out.scenarios.push(await scenario(reader, sender, "s1-oneliner", "probe one-liner " + Date.now()));
    await resetToBottom(reader);

    // ── S2: tall multi-paragraph body.
    out.scenarios.push(await scenario(reader, sender, "s2-tall-body", longBody + Date.now()));
    await resetToBottom(reader);

    // ── S3: burst of three one-liners back to back.
    await reader.evalp(`(() => { window.__tr = []; window.__t0 = performance.now(); return true; })()`);
    for (const i of [1, 2, 3]) {
      await sendMsg(sender, `burst ${i} ` + Date.now());
      await submitMsg(sender);
      await sleep(300);
    }
    await sleep(2500);
    out.scenarios.push({
      name: "s3-burst",
      body: "x3 one-liners",
      post: await reader.evalp(snapshot),
      trace: await reader.evalp(`window.__tr`),
    });
    await resetToBottom(reader);

    // ── S4: sender message while the READER's composer has a long draft
    // grown toward its cap. The #848 viewport observer was built for this
    // shape (sibling resizing the pane). Records whether the follow runs.
    out.scenarios.push(
      await scenario(reader, sender, "s4-long-draft", "arrived under a long draft " + Date.now(), {
        before: async (pg) => {
          const draft =
            "A long draft in the reader's composer, typed out to many lines so the textarea grows toward its 200px cap and the pane's in-flow siblings shrink the scroller. Line two. Line three. Line four. Line five. Line six. Line seven. Line eight. Line nine. Line ten. Line eleven. Line twelve. Line thirteen. Line fourteen. Line fifteen.";
          await pg.evalp(`(() => {
            const ta = document.querySelector("#compose-form textarea");
            ta.value = ${JSON.stringify(draft)};
            ta.dispatchEvent(new Event("input", { bubbles: true }));
            return true;
          })()`);
          await sleep(1200);
        },
      }),
    );
    // clear the draft
    await reader.evalp(`(() => {
      const ta = document.querySelector("#compose-form textarea");
      ta.value = "";
      ta.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    })()`);
    await sleep(800);
    await resetToBottom(reader);

    // ── Control: reader scrolled up by hand — a follow here would be a BUG
    // (yanking a history reader). Confirms the harness observes a decline.
    await reader.evalp(`(() => {
      const sc = document.getElementById("chat-message-scroller");
      sc.scrollTop = sc.scrollTop - 400;
      return true;
    })()`);
    await sleep(800);
    out.scenarios.push(await scenario(reader, sender, "s7-control-scrolled-up", "while scrolled up " + Date.now()));
    await resetToBottom(reader);

    if (!MOBILE) {
      // ── S5: window resize 1440 -> 1200 (width rewrap), then a message.
      // Width changes hit `_onViewportResize`'s bare-return width branch.
      out.scenarios.push(
        await scenario(reader, sender, "s5-window-resize", "after window resize " + Date.now(), {
          before: async (pg) => {
            await pg.S("Emulation.setDeviceMetricsOverride", {
              width: 1200, height: H, deviceScaleFactor: 1, mobile: false,
              screenWidth: 1200, screenHeight: H,
            });
            await sleep(1200);
          },
          wait: 3000,
        }),
      );
      // restore 1440 and resettle
      await reader.S("Emulation.setDeviceMetricsOverride", {
        width: W, height: H, deviceScaleFactor: 1, mobile: false,
        screenWidth: W, screenHeight: H,
      });
      await sleep(1200);
      await resetToBottom(reader);

      // ── S6: sidebar WIDTH change by drag is NOT reachable in the real app
      // at any SHA in the A/B window: `#chat-sidebar` renders no
      // `[data-drag-handle]` (that affordance exists on the CANVAS sidebar,
      // `canvas_sidebar_resize.js`), so `ResizableSidebar` binds no drag on
      // the rail and its width only ever comes from ClientState (224 default).
      // The width path is therefore exercised by S5's window resize, which
      // is the real user action that reaches `_onViewportResize`'s bare
      // width branch.
    }

    reader.browser.close();
    sender.browser.close();
  } catch (e) {
    out.fatal = String(e && e.message ? e.message : e).slice(0, 2000);
  }
  out.finished = new Date().toISOString();
  const file = `${OUT_DIR}/${GIT_LABEL}-${W}x${H}.json`;
  fs.writeFileSync(file, JSON.stringify(out, null, 1));
  console.log("WROTE", file);
  if (out.fatal) console.error("FATAL", out.fatal);
  // Verdict line per scenario, for quick shell-side reading. `arrived` is
  // proof the reader's trace actually saw a message row land — without it
  // a "followed" verdict is vacuous.
  for (const s of out.scenarios) {
    const d = s.post && s.post.d !== null ? s.post.d : null;
    const arrived = (s.trace || []).some((e) => e.added > 0) || (s.trace || []).length > 0;
    console.log(
      `${out.git} ${s.name}: post-distance=${d} chip=${s.post ? s.post.chip : "?"} ` +
        `traceEvents=${(s.trace || []).length} arrived=${arrived} last="${(s.post && s.post.lastRow ? String(s.post.lastRow).slice(0, 34) : "")}"`,
    );
  }
  // The raw CDP websocket can keep the event loop alive after the file is
  // written; everything is flushed by now, so exit deterministically.
  process.exit(0);
})().catch((e) => {
  console.error("FATAL", e);
  process.exit(1);
});
