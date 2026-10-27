#!/usr/bin/env node
// Tab-switch time-to-interactive harness (task 01a17b00 stage 1).
//
// For every app tab (read off the rendered desktop sidebar, which renders
// PlatformWeb.Components.IconRail.destinations/1 + /settings; in local mode
// the destination list is also fetched from the node and absences are
// reported), from a warm origin page, taps the REAL tab link N times and
// records per tap:
//
//   tap_ms     click event timeStamp -> the designated probe on the new page
//              received a keystroke (an `input` event for a text probe, a
//              `focusin` inside the new main LiveView for the Tab-key probe).
//              The page must first have fired `phx:page-loading-stop`, and
//              the NEW `[data-phx-main]` must carry `.phx-connected`.
//   ready_ms   click -> those two conditions plus the probe being present
//              (before the keystroke round trip; the gap is driver overhead).
//   raw bytes  the phx_reply to the destination's phx_join, from CDP
//              Network.webSocketFrameReceived (CDP shows DECOMPRESSED text),
//              plus every other frame received on that topic in the window.
//   wire bytes local: server->client TCP payload bytes on the LiveView
//              websocket in the tap window, counted by a byte-counting proxy
//              between Chrome and the dev server (so permessage-deflate shows
//              up once negotiated). exp: no proxy (TLS); an ESTIMATE from
//              raw-deflating the captured frames (window 15, context
//              takeover over the window's frames only).
//   server     local only: the dev-only probe (tab_switch_probe.exs) loaded
//              into the dev node over distribution: mount/handle_params ms,
//              Repo query count, refresh_board and count_by_scope calls.
//
// Usage: see measure-tab-switch.sh (the runner). Direct:
//   node e2e/scripts/measure-tab-switch.mjs --base-url http://localhost:4073 \
//     --login-as tabswitch --probe-node tabswitch01a17b00@127.0.0.1 \
//     --cookie-file /tmp/x/cookie --out /tmp/x/results.json [--tabs tasks,chat]
//
// Never attaches to a browser it did not launch, never indexes /json/list.

import { chromium } from "playwright";
import { execFile } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  launchChrome,
  startByteProxy,
  joinReply,
  byteLength,
  deflateEstimate,
  parseFrame,
  summarize,
  PROFILES,
  cdpConditions,
  traceBreakdown,
} from "./tab-switch-lib.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// ── args ──────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const a = {
    taps: 10,
    viewport: "1280x800",
    chromePort: 9461,
    tabTimeoutMs: 5 * 60_000,
    runTimeoutMs: 60 * 60_000,
    busySlug: "tab-switch-busy",
    label: "local seeded",
    proxy: true,
    serverLogLevel: "info",
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => argv[++i];
    switch (k) {
      case "--base-url": a.baseUrl = v().replace(/\/$/, ""); break;
      case "--login-as": a.loginAs = v(); break;
      case "--auth-state": a.authState = v(); break;
      case "--probe-node": a.probeNode = v(); break;
      case "--cookie-file": a.cookieFile = v(); break;
      case "--out": a.out = v(); break;
      case "--tabs": a.tabs = v().split(",").filter(Boolean); break;
      case "--taps": a.taps = Number(v()); break;
      case "--viewport": a.viewport = v(); break;
      case "--chrome-port": a.chromePort = Number(v()); break;
      case "--busy-slug": a.busySlug = v(); break;
      case "--label": a.label = v(); break;
      case "--tasks-scenario": a.tasksScenario = v(); break;
      case "--no-proxy": a.proxy = false; break;
      // --throttle proxy:4g shapes the byte proxy (bandwidth + RTT, both
      // directions, shared pipe); --throttle cdp:4g uses CDP
      // Network.emulateNetworkConditions. Chrome's emulation may not touch
      // WebSocket frames; --throttle-check reports whether it did.
      case "--throttle": a.throttle = v(); break;
      case "--trace": a.trace = true; break;
      case "--server-log-level": a.serverLogLevel = v(); break;
      case "--headed": a.headed = true; break;
      default: throw new Error(`unknown argument ${k}`);
    }
  }
  if (!["debug", "info", "warning", "error"].includes(a.serverLogLevel)) throw new Error("bad --server-log-level");
  if (a.throttle) {
    const [mode, prof] = a.throttle.split(":");
    if (!["proxy", "cdp"].includes(mode) || !PROFILES[prof]) throw new Error("bad --throttle (proxy:4g | cdp:4g)");
    a.throttleMode = mode;
    a.throttleProfile = PROFILES[prof];
    if (mode === "proxy" && a.proxy === false) throw new Error("--throttle proxy needs the proxy");
  }
  if (!a.baseUrl) throw new Error("--base-url is required");
  if (!a.out) throw new Error("--out is required");
  if (!a.loginAs && !a.authState) throw new Error("--login-as (local /dev/login) or --auth-state is required");
  if (a.loginAs && !/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(a.baseUrl))
    throw new Error("--login-as uses /dev/login and is for a local dev server only");
  return a;
}

// ── dev-node probe over distribution ──────────────────────────────────────

function rpc(args, expr, timeoutMs = 30_000) {
  if (!args.probeNode) return Promise.resolve(null);
  const cookie = readFileSync(args.cookieFile, "utf8").trim();
  const self = `tsp${process.pid}${Math.floor(Math.random() * 1e6)}@127.0.0.1`;
  const code = `Logger.put_process_level(self(), :error); IO.puts("<<TSP>>" <> (${expr}) <> "<<TSP>>")`;
  return new Promise((resolve, reject) => {
    execFile(
      "elixir",
      ["--name", self, "--cookie", cookie, "--rpc-eval", args.probeNode, code],
      { timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 },
      (err, stdout) => {
        const m = /<<TSP>>([\s\S]*?)<<TSP>>/.exec(stdout || "");
        if (m) return resolve(m[1]);
        reject(new Error(`rpc failed: ${err?.message || "no marker"}`));
      },
    );
  });
}

const probeFile = path.join(HERE, "tab_switch_probe.exs");
// Loads the probe on first use. Also sets the node's Logger to :info (prod's
// level): at the dev default :debug every Repo query is formatted and
// logged, which inflates server time and streams to the live-reload socket.
const probeReset = (args) =>
  rpc(
    args,
    `(Code.ensure_loaded?(TabSwitchProbe) || Code.eval_file(${JSON.stringify(probeFile)}); Logger.configure(level: :${args.serverLogLevel}); TabSwitchProbe.reset(); "ok")`,
  );
const probeDump = async (args) => {
  const s = await rpc(args, "TabSwitchProbe.dump()");
  return s ? JSON.parse(s) : null;
};
const nodeDestinations = async (args) => {
  const s = await rpc(
    args,
    `Jason.encode!(%{destinations: PlatformWeb.Components.IconRail.destinations(root_user: false) |> Enum.map(&%{key: &1.key, path: &1.path}), email_enabled: Platform.Mail.Config.enabled?(), games_enabled: Platform.Files.Browser.games_enabled?()})`,
  ).catch(() => null);
  return s ? JSON.parse(s) : null;
};

// ── page helpers ──────────────────────────────────────────────────────────

const PROBES = {
  chat: { kind: "text", selector: "#compose_text", name: "composer (#compose_text)" },
  // voice: #ctx-search lives in the closed "Talking about" sheet, so it is
  // not a page input; voice takes the Tab-key probe like the other tabs.
  tasks: { kind: "text", selector: "#task-search", name: "task search (#task-search)" },
};
const TAB_FOCUS = { kind: "tabfocus", selector: null, name: "Tab key moves focus into the new main LiveView" };

function tabKeyFor(href) {
  const p = href.split("?")[0];
  if (href.includes("type=canvas")) return "canvases";
  if (href.includes("type=game")) return "games";
  const seg = p.split("/").filter(Boolean);
  if (seg[0] === "control" && seg[1] === "experiments") return "experiments";
  return seg[0] || "root";
}

async function waitConnected(page, timeout = 20_000) {
  await page.waitForSelector("[data-phx-main].phx-connected", { timeout });
  await page.waitForTimeout(300);
}

// A hidden navigate link to go back to the origin: the return trip is not
// measured, so it does not need to be a real tab link.
async function softNavigate(page, href) {
  await page.evaluate((h) => {
    const a = document.createElement("a");
    a.href = h;
    a.setAttribute("data-phx-link", "redirect");
    a.setAttribute("data-phx-link-state", "push");
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    a.remove();
  }, href);
  await page.waitForFunction(
    (h) => location.pathname + location.search === h || location.pathname === h.split("?")[0],
    href,
    { timeout: 20_000 },
  );
  await waitConnected(page);
}

async function visibleLink(page, href) {
  const handles = await page.$$(`a[data-phx-link="redirect"][href="${href}"]`);
  for (const h of handles) if (await h.isVisible()) return h;
  return null;
}

async function arm(page) {
  await page.evaluate(() => {
    const old = document.querySelector("[data-phx-main]");
    window.__tsp = { old, t0: null, stop: null };
    document.addEventListener("click", (e) => { if (window.__tsp && window.__tsp.t0 == null) window.__tsp.t0 = e.timeStamp; }, { capture: true, once: true });
    window.addEventListener("phx:page-loading-stop", () => { if (window.__tsp && window.__tsp.t0 != null && window.__tsp.stop == null) window.__tsp.stop = performance.now(); });
  });
}

async function waitReady(page, probe, timeout) {
  await page.waitForFunction(
    (sel) => {
      const s = window.__tsp;
      if (!s || s.t0 == null || s.stop == null) return false;
      const main = document.querySelector("[data-phx-main]");
      if (!main || main === s.old || !main.classList.contains("phx-connected")) return false;
      if (sel) {
        const el = document.querySelector(sel);
        if (!el || el.disabled || !el.isConnected) return false;
      }
      if (s.ready == null) s.ready = performance.now();
      s.mainId = main.id;
      return true;
    },
    probe.selector,
    { timeout, polling: "raf" },
  );
  return page.evaluate(() => ({ t0: window.__tsp.t0, stop: window.__tsp.stop, ready: window.__tsp.ready, mainId: window.__tsp.mainId }));
}

async function keystroke(page, probe) {
  // A text probe that is in the DOM but not rendered (the phone layout puts
  // task search behind a sheet) cannot take a keystroke: fall back to the
  // Tab-key probe and say so in the tap record.
  if (probe.kind === "text") {
    const visible = await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      return !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden";
    }, probe.selector);
    if (!visible) return { at: await keystroke(page, TAB_FOCUS).then((r) => r.at), used: TAB_FOCUS.name + " (text probe not rendered)" };
  }
  if (probe.kind === "text") {
    await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      window.__tsp.key = null;
      el.addEventListener("input", (e) => { if (window.__tsp.key == null) window.__tsp.key = e.timeStamp; }, { once: true });
      el.focus();
    }, probe.selector);
    await page.keyboard.press("x");
  } else {
    await page.evaluate(() => {
      window.__tsp.key = null;
      const main = document.querySelector("[data-phx-main]");
      if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
      main.addEventListener("focusin", (e) => { if (window.__tsp.key == null) window.__tsp.key = e.timeStamp; }, { once: true });
      // Start the tab order just before the main LiveView's content.
      main.setAttribute("tabindex", "-1");
      main.focus();
      main.removeAttribute("tabindex");
    });
    await page.keyboard.press("Tab");
  }
  await page.waitForFunction(() => window.__tsp.key != null, null, { timeout: 10_000 });
  const key = await page.evaluate(() => window.__tsp.key);
  if (probe.kind === "text") await page.keyboard.press("Backspace");
  return { at: key, used: probe.name };
}

// CDP Performance.getMetrics: cumulative main-thread seconds. A tap's client
// cost is the delta from just before the click to ready.
async function perfMetrics(cdp) {
  const { metrics } = await cdp.send("Performance.getMetrics");
  const m = Object.fromEntries(metrics.map((x) => [x.name, x.value]));
  return {
    script: m.ScriptDuration, layout: m.LayoutDuration, style: m.RecalcStyleDuration, task: m.TaskDuration,
    layoutCount: m.LayoutCount, styleCount: m.RecalcStyleCount, nodes: m.Nodes,
  };
}
const perfDelta = (a, b) => ({
  script_ms: (b.script - a.script) * 1000,
  layout_ms: (b.layout - a.layout) * 1000,
  style_ms: (b.style - a.style) * 1000,
  task_ms: (b.task - a.task) * 1000,
  layout_count: b.layoutCount - a.layoutCount,
  style_count: b.styleCount - a.styleCount,
});

// ── one tab ───────────────────────────────────────────────────────────────

async function measureTab(ctx, args, tab, frames, proxy) {
  const { page } = ctx;
  const probe = PROBES[tab.key] || TAB_FOCUS;
  const originHref = tab.key === "chat" ? "/inbox" : `/chat/${args.busySlug}`;
  const destHref = tab.href;

  await page.goto(args.baseUrl + originHref);
  await waitConnected(page);
  await probeReset(args);

  const taps = [];
  for (let i = 0; i <= args.taps; i++) {
    const warmup = i === 0;
    const link = await visibleLink(page, destHref);
    if (!link) throw new Error(`no visible navigate link for ${destHref} on ${originHref}`);
    await arm(page);
    const frameIdx = frames.length;
    const traced = args.trace && !warmup && tab.key === "chat";
    if (traced) await ctx.browser.startTracing(page, { categories: ["devtools.timeline", "v8.execute", "disabled-by-default-devtools.timeline"], screenshots: false });
    const pm0 = await perfMetrics(ctx.cdp);
    const nodeT0 = performance.now();
    await link.click();
    const r = await waitReady(page, probe, 30_000);
    const pm1 = await perfMetrics(ctx.cdp);
    let trace = null;
    if (traced) {
      const buf = await ctx.browser.stopTracing();
      const evs = JSON.parse(buf.toString("utf8")).traceEvents || [];
      // The trace ran from just before the click to ready.
      trace = traceBreakdown(evs.filter((e) => e.ph !== "X" || e.dur != null));
    }
    // The byte window closes at "ready": the keystroke below sends events of
    // its own (search, typing) whose replies are not part of the switch.
    const nodeT1 = performance.now();
    const { at: key, used: probeUsed } = await keystroke(page, probe);
    await page.waitForTimeout(150);

    const all = frames.slice(frameIdx).filter((f) => f.wall <= nodeT1);
    // Only the LiveView socket. The dev server's live-reload socket streams
    // server log lines to the page and is not part of a tab switch.
    const win = all.filter((f) => f.socket === "/live/websocket");
    const topic = `lv:${r.mainId}`;
    const jr = joinReply(win, { topic });
    const recvInWindow = win.filter((f) => f.dir === "recv");
    const byTopic = {};
    for (const f of all.filter((x) => x.dir === "recv")) {
      const k = `${f.socket}|${parseFrame(f.data)?.topic ?? "?"}`;
      byTopic[k] = (byTopic[k] || 0) + byteLength(f.data);
    }
    const rawRecvAll = recvInWindow.reduce((s, f) => s + byteLength(f.data), 0);
    const est = (await deflateEstimate(recvInWindow.map((f) => f.data))).reduce((s, n) => s + n, 0);
    const replyEst = jr?.replyData ? (await deflateEstimate([jr.replyData]))[0] : null;

    const tap = {
      i,
      warmup,
      url: await page.evaluate(() => location.pathname + location.search),
      probe_used: probeUsed,
      tap_ms: key - r.t0,
      ready_ms: r.ready - r.t0,
      loading_stop_ms: r.stop - r.t0,
      join_topic: jr?.topic ?? null,
      join_reply_status: jr?.replyStatus ?? null,
      join_reply_raw_bytes: jr?.replyBytes ?? null,
      topic_other_raw_bytes: jr?.extraRecvBytes ?? null,
      window_raw_recv_bytes: rawRecvAll,
      window_raw_recv_by_socket_topic: byTopic,
      window_deflate_estimate_bytes: est,
      join_reply_deflate_estimate_bytes: replyEst,
      wire_down_bytes: proxy ? proxy.sum(nodeT0, nodeT1, "down") : null,
      wire_up_bytes: proxy ? proxy.sum(nodeT0, nodeT1, "up") : null,
      client: perfDelta(pm0, pm1),
      trace,
    };
    taps.push(tap);
    process.stderr.write(`  ${tab.key} tap ${i}${warmup ? " (warm-up)" : ""}: ${tap.tap_ms.toFixed(0)} ms, reply ${tap.join_reply_raw_bytes} B, wire ${tap.wire_down_bytes}\n`);

    await softNavigate(page, originHref);
  }

  // Server side: connected mounts of the destination view, in order; the
  // first is the warm-up tap's.
  let server = null;
  const dump = await probeDump(args).catch((e) => ({ error: e.message }));
  if (Array.isArray(dump)) {
    // Reset ran after the origin mounted, so the first connected mount is
    // the warm-up tap's destination; the return trips mount the origin view.
    const destView = dump.find((m) => m.connected)?.view;
    const destMounts = dump.filter((m) => m.connected && m.view === destView);
    server = destMounts;
  } else if (dump) {
    server = dump;
  }

  return { key: tab.key, href: destHref, origin: originHref, probe: probe.name, taps, server };
}

// ── run ───────────────────────────────────────────────────────────────────

function summarizeTab(t) {
  const measured = t.taps.filter((x) => !x.warmup);
  const pick = (k) => summarize(measured.map((x) => x[k]));
  const s = {
    key: t.key,
    href: t.href,
    origin: t.origin,
    probe: [...new Set(measured.map((x) => x.probe_used))].join("; ") || t.probe,
    n: measured.length,
    // A tap with no phx_join on /live/websocket did not switch over the
    // websocket (LiveView fell back to long-poll, seen once on this rig):
    // its timings and bytes are not comparable, and the tab is flagged.
    websocket_join_every_tap: measured.every((x) => x.join_reply_raw_bytes != null),
    tap_ms: pick("tap_ms"),
    ready_ms: pick("ready_ms"),
    join_reply_raw_bytes: pick("join_reply_raw_bytes"),
    join_reply_deflate_estimate_bytes: pick("join_reply_deflate_estimate_bytes"),
    window_raw_recv_bytes: pick("window_raw_recv_bytes"),
    window_deflate_estimate_bytes: pick("window_deflate_estimate_bytes"),
    wire_down_bytes: pick("wire_down_bytes"),
    client_script_ms: summarize(measured.map((x) => x.client?.script_ms)),
    client_layout_ms: summarize(measured.map((x) => x.client?.layout_ms)),
    client_style_ms: summarize(measured.map((x) => x.client?.style_ms)),
    client_task_ms: summarize(measured.map((x) => x.client?.task_ms)),
  };
  if (Array.isArray(t.server)) {
    const ms = t.server.slice(1);
    s.server = {
      mounts_seen: t.server.length,
      view: t.server[0]?.view ?? null,
      mount_ms: summarize(ms.map((m) => m.mount_ms)),
      handle_params_ms: summarize(ms.map((m) => (m.handle_params_ms || []).reduce((a, b) => a + b, 0))),
      arrival_queries: summarize(ms.map((m) => m.arrival_queries)),
      refresh_board: summarize(ms.map((m) => m.refresh_board)),
      count_by_scope: summarize(ms.map((m) => m.count_by_scope)),
      list_all_tasks_first: ms.map((m) => (m.list_all_tasks || [])[0] || null),
      handle_params_calls: summarize(ms.map((m) => (m.handle_params_ms || []).length)),
    };
  } else {
    s.server = t.server ? { error: t.server.error || "unavailable" } : "unavailable";
  }
  return s;
}

async function openSession(args, baseUrl) {
  const [w, h] = args.viewport.split("x").map(Number);
  const chrome = await launchChrome({ port: args.chromePort, headless: !args.headed });
  const browser = await chromium.connectOverCDP(chrome.endpoint);
  const context = await browser.newContext({
    viewport: { width: w, height: h },
    ...(args.authState ? { storageState: args.authState } : {}),
  });
  const page = await context.newPage();
  const frames = [];
  const sockets = new Map();
  const cdp = await context.newCDPSession(page);
  await cdp.send("Network.enable");
  await cdp.send("Performance.enable");
  if (args.throttleMode === "cdp") await cdp.send("Network.emulateNetworkConditions", cdpConditions(args.throttleProfile));
  cdp.on("Network.webSocketCreated", (e) => sockets.set(e.requestId, new URL(e.url).pathname));
  cdp.on("Network.webSocketFrameSent", (e) => {
    if (e.response.opcode === 1) frames.push({ dir: "sent", socket: sockets.get(e.requestId) || e.requestId, t: e.timestamp, wall: performance.now(), data: e.response.payloadData });
  });
  cdp.on("Network.webSocketFrameReceived", (e) => {
    if (e.response.opcode === 1) frames.push({ dir: "recv", socket: sockets.get(e.requestId) || e.requestId, t: e.timestamp, wall: performance.now(), data: e.response.payloadData });
  });
  if (args.loginAs) {
    await page.goto(`${baseUrl}/dev/login?as=${encodeURIComponent(args.loginAs)}`);
  }
  return { chrome, browser, context, page, cdp, frames, version: chrome.version };
}

async function closeSession(s) {
  try { await s.browser.close(); } catch {}
  s.chrome.kill();
}

function withTimeout(p, ms, what) {
  let t;
  return Promise.race([p, new Promise((_, rej) => (t = setTimeout(() => rej(new Error(`${what} timed out after ${ms} ms`)), ms)))]).finally(() => clearTimeout(t));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const started = Date.now();
  const target = new URL(args.baseUrl);

  let proxy = null;
  let baseUrl = args.baseUrl;
  if (args.proxy && target.protocol === "http:") {
    proxy = await startByteProxy({ listenPort: 0, targetHost: "127.0.0.1", targetPort: Number(target.port || 80), shape: args.throttleMode === "proxy" ? args.throttleProfile : null });
    baseUrl = `http://localhost:${proxy.port}`;
  }
  const runArgs = { ...args, baseUrl };

  let session = await openSession(runArgs, baseUrl);
  const result = existsSync(args.out) ? JSON.parse(readFileSync(args.out, "utf8")) : { runs: [] };
  const run = {
    label: args.label,
    started_at: new Date().toISOString(),
    base: args.proxy ? "local dev server via byte-counting proxy" : "direct",
    viewport: args.viewport,
    taps_per_tab: args.taps,
    throttle: args.throttle ? { mode: args.throttleMode, ...args.throttleProfile } : null,
    load_avg_at_start: os.loadavg(),
    tasks_scenario: args.tasksScenario || null,
    server_log_level: args.probeNode ? args.serverLogLevel : null,
    machine: { platform: `${os.type()} ${os.release()} ${os.arch()}`, cpu: os.cpus()[0]?.model, cores: os.cpus().length, mem_gb: Math.round(os.totalmem() / 2 ** 30) },
    chrome: session.version,
    node_destinations: await nodeDestinations(runArgs),
    tabs: [],
    errors: [],
  };

  await session.page.goto(`${baseUrl}/chat/${args.busySlug}`);
  await waitConnected(session.page);
  const hrefs = await session.page.$$eval('#sidebar-nav a[data-phx-link="redirect"], #sidebar a[data-phx-link="redirect"][href="/settings"]', (as) =>
    [...new Set(as.map((a) => a.getAttribute("href")))],
  );
  run.sidebar_hrefs = hrefs;
  let tabs = hrefs.map((href) => ({ key: tabKeyFor(href), href }));
  if (args.tabs) tabs = tabs.filter((t) => args.tabs.includes(t.key));

  for (const tab of tabs) {
    if (Date.now() - started > args.runTimeoutMs) {
      run.errors.push({ tab: tab.key, error: "run timebox reached; not measured" });
      continue;
    }
    process.stderr.write(`measuring ${tab.key} (${tab.href})\n`);
    try {
      const t = await withTimeout(measureTab(session, runArgs, tab, session.frames, proxy), args.tabTimeoutMs, `tab ${tab.key}`);
      run.tabs.push({ summary: summarizeTab(t), raw: t });
    } catch (e) {
      run.errors.push({ tab: tab.key, error: e.message });
      process.stderr.write(`  ${tab.key} FAILED: ${e.message}; restarting Chrome\n`);
      await closeSession(session);
      session = await openSession(runArgs, baseUrl);
    }
    session.frames.length = 0;
    result.runs = result.runs.filter((r) => r !== run);
    result.runs.push(run);
    writeFileSync(args.out, JSON.stringify(result, null, 2));
  }

  if (proxy) {
    run.websocket_connections = [...proxy.conns.values()].filter((c) => c.ws).map((c) => ({ id: c.id, upgrade_status: c.upgradeStatus ?? null, deflate_offered: c.deflateOffered, deflate_accepted: c.deflateAccepted ?? null }));
  }
  run.finished_at = new Date().toISOString();
  writeFileSync(args.out, JSON.stringify(result, null, 2));
  await closeSession(session);
  if (proxy) await proxy.close();

  for (const t of run.tabs) {
    const s = t.summary;
    const f = (x) => (x?.median == null ? "-" : `${Math.round(x.median)}/${Math.round(x.p90)}`);
    process.stdout.write(
      `${s.key.padEnd(12)} tap ${f(s.tap_ms).padEnd(10)} reply ${f(s.join_reply_raw_bytes).padEnd(14)} wire ${f(s.wire_down_bytes).padEnd(14)} mount ${f(s.server?.mount_ms)}\n`,
    );
  }
  for (const e of run.errors) process.stdout.write(`ERROR ${e.tab}: ${e.error}\n`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
