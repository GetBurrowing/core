// Node-runnable tests for the root layout's theme-boot script (task 01a1557a
// stage 3).
//
// The script lives inline in `lib/platform_web/components/layouts/root.html.heex`
// (it has to run before first paint, so it cannot be a bundle). This test
// extracts the `data-role="theme-boot"` body from that template and runs it
// in `node:vm` against a fake document, localStorage and matchMedia, so what
// is tested is the exact text the browser executes.
//
// The preset ids are read from `Platform.Accounts.ThemePreference`
// (`lib/platform/accounts/theme_preference.ex`), the same registry the layout
// renders into the script's `data-presets` attribute: there is no second list
// here either.
//
// Run from the assets dir:
//
//     node --test test/theme_boot_test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const PLATFORM = fileURLToPath(new URL("../../", import.meta.url));
const ROOT_LAYOUT = readFileSync(
  `${PLATFORM}lib/platform_web/components/layouts/root.html.heex`,
  "utf8",
);
const REGISTRY = readFileSync(`${PLATFORM}lib/platform/accounts/theme_preference.ex`, "utf8");

const BOOT_MATCHES = [
  ...ROOT_LAYOUT.matchAll(/<script\b[^>]*data-role="theme-boot"[^>]*>([\s\S]*?)<\/script>/g),
];
const BOOT_SOURCE = BOOT_MATCHES.length === 1 ? BOOT_MATCHES[0][1] : null;

const PRESET_IDS = [...REGISTRY.matchAll(/%\{id: "([^"]+)", name: "[^"]+"\}/g)].map((m) => m[1]);
const BASE = REGISTRY.match(/def base_preset, do: "([^"]+)"/)[1];
const DEFAULT = REGISTRY.match(/@default %\{"preset" => "([^"]+)", "mode" => "([^"]+)"\}/);
const MODES = REGISTRY.match(/@modes \[([^\]]+)\]/)[1].match(/"([^"]+)"/g).map((m) => m.slice(1, -1));

const KEY = "burrow-theme-v1";

// Objects built inside the vm context carry that realm's Object prototype,
// which deepStrictEqual treats as different from this realm's.
const plain = (value) => JSON.parse(JSON.stringify(value));

// The computed `--color-base-200` the fake stylesheet yields for each
// attribute combination. Stand-in strings, not colours: the assertion is that
// the meta copies whatever the cascade computed.
const groundFor = (attrs) =>
  `ground(${attrs.get("data-preset") || "base"}/${attrs.get("data-theme") || "none"})`;

const BRANDING_THEME_COLOR = "branding-theme-color";

function boot({ server = null, cache, prefersDark = false, emptyComputed = false } = {}) {
  const attrs = new Map();
  if (server) {
    if (server.mode === "light" || server.mode === "dark") attrs.set("data-theme", server.mode);
    if (server.preset !== BASE) attrs.set("data-preset", server.preset);
  }

  const root = {
    getAttribute: (name) => (attrs.has(name) ? attrs.get(name) : null),
    hasAttribute: (name) => attrs.has(name),
    setAttribute: (name, value) => attrs.set(name, String(value)),
    removeAttribute: (name) => attrs.delete(name),
  };

  const meta = {
    content: BRANDING_THEME_COLOR,
    setAttribute(name, value) {
      if (name === "content") this.content = value;
    },
  };

  const docListeners = new Map();
  const dataset = {
    presets: PRESET_IDS.join(" "),
    modes: MODES.join(" "),
    basePreset: BASE,
    defaultPreset: DEFAULT[1],
    defaultMode: DEFAULT[2],
  };
  if (server) {
    dataset.serverPreset = server.preset;
    dataset.serverMode = server.mode;
  }

  const document = {
    documentElement: root,
    currentScript: { dataset },
    querySelector: (selector) => (selector === 'meta[name="theme-color"]' ? meta : null),
    addEventListener: (type, fn) => docListeners.set(type, fn),
  };

  const store = new Map();
  if (cache !== undefined) store.set(KEY, typeof cache === "string" ? cache : JSON.stringify(cache));
  const localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };

  const mqlListeners = [];
  const mql = {
    matches: prefersDark,
    addEventListener: (type, fn) => type === "change" && mqlListeners.push(fn),
  };

  const winListeners = new Map();
  const events = [];
  const window = {
    matchMedia: (query) => {
      assert.equal(query, "(prefers-color-scheme: dark)");
      return mql;
    },
    addEventListener: (type, fn) => {
      if (!winListeners.has(type)) winListeners.set(type, []);
      winListeners.get(type).push(fn);
    },
    dispatchEvent: (event) => {
      events.push(event);
      for (const fn of winListeners.get(event.type) || []) fn(event);
      return true;
    },
  };

  class CustomEvent {
    constructor(type, init = {}) {
      this.type = type;
      this.detail = init.detail;
    }
  }

  const getComputedStyle = (el) => {
    assert.equal(el, root, "theme-color must come from <html>'s computed style");
    return { getPropertyValue: (name) => (name === "--color-base-200" && !emptyComputed ? ` ${groundFor(attrs)}` : "") };
  };

  const context = vm.createContext({ window, document, localStorage, getComputedStyle, CustomEvent });
  vm.runInContext(BOOT_SOURCE, context, { filename: "root.html.heex#theme-boot" });

  return {
    attrs,
    meta,
    store,
    events,
    api: window.burrowTheme,
    cached: () => JSON.parse(store.get(KEY)),
    flipScheme(dark) {
      mql.matches = dark;
      for (const fn of mqlListeners) fn({ matches: dark });
    },
    storageEvent(key, newValue) {
      for (const fn of winListeners.get("storage") || []) fn({ key, newValue });
    },
    domContentLoaded: () => docListeners.get("DOMContentLoaded"),
  };
}

test("the layout carries exactly one theme-boot script, and the registry parses", () => {
  assert.equal(BOOT_MATCHES.length, 1, "expected one data-role=\"theme-boot\" script");
  assert.deepEqual(PRESET_IDS, [
    "burrow",
    "burrow-midnight",
    "burrow-sand",
    "burrow-forest",
    "high-contrast",
    "sage",
  ]);
  assert.deepEqual(MODES, ["light", "dark", "system"]);
  assert.equal(BASE, "burrow");
});

test("the boot body has no hex colour and no EEx", () => {
  assert.doesNotMatch(BOOT_SOURCE, /#[0-9a-fA-F]{3,8}\b/);
  assert.doesNotMatch(BOOT_SOURCE, /<%|\{@|theme_boot\./);
});

test("server attributes beat a stale cache and overwrite it", () => {
  const page = boot({
    server: { preset: "high-contrast", mode: "dark" },
    cache: { preset: "burrow-sand", mode: "light" },
  });

  assert.equal(page.attrs.get("data-preset"), "high-contrast");
  assert.equal(page.attrs.get("data-theme"), "dark");
  assert.deepEqual(page.cached(), { preset: "high-contrast", mode: "dark" });
});

test("a server Burrow value clears a cached preset, even with no attributes (Burrow + system)", () => {
  const page = boot({
    server: { preset: "burrow", mode: "system" },
    cache: { preset: "burrow-sand", mode: "light" },
    prefersDark: true,
  });

  assert.equal(page.attrs.has("data-preset"), false);
  assert.equal(page.attrs.get("data-theme"), "dark");
  assert.deepEqual(page.cached(), { preset: "burrow", mode: "system" });
});

test("the cache applies when there are no server attributes", () => {
  const page = boot({ cache: { preset: "burrow-forest", mode: "light" } });

  assert.equal(page.attrs.get("data-preset"), "burrow-forest");
  assert.equal(page.attrs.get("data-theme"), "light");
});

test("with no server value and no cache, the registry default applies", () => {
  const page = boot();

  assert.equal(page.attrs.has("data-preset"), false);
  assert.equal(page.attrs.get("data-theme"), "dark");
  assert.deepEqual(plain(page.api.get()), { preset: "burrow", mode: "dark", resolved: "dark" });
});

test("an unknown cached id falls back to the default", () => {
  const unknown = boot({ cache: { preset: "burrow-dark", mode: "dim" } });
  assert.equal(unknown.attrs.has("data-preset"), false);
  assert.equal(unknown.attrs.get("data-theme"), "dark");

  const garbled = boot({ cache: "{not json" });
  assert.equal(garbled.attrs.has("data-preset"), false);
  assert.equal(garbled.attrs.get("data-theme"), "dark");
});

test("system follows the matchMedia change event", () => {
  const page = boot({ server: { preset: "burrow-sand", mode: "system" }, prefersDark: false });
  assert.equal(page.attrs.get("data-theme"), "light");
  assert.equal(page.attrs.get("data-preset"), "burrow-sand");

  page.flipScheme(true);
  assert.equal(page.attrs.get("data-theme"), "dark");
  assert.equal(page.meta.content, "ground(burrow-sand/dark)");
  assert.deepEqual(plain(page.events.at(-1).detail), {
    preset: "burrow-sand",
    mode: "system",
    resolved: "dark",
  });

  page.flipScheme(false);
  assert.equal(page.attrs.get("data-theme"), "light");
});

test("an explicit mode ignores the OS scheme", () => {
  const page = boot({ server: { preset: "burrow-sand", mode: "light" }, prefersDark: true });
  assert.equal(page.attrs.get("data-theme"), "light");
  page.flipScheme(true);
  assert.equal(page.attrs.get("data-theme"), "light");
});

test("theme-color comes from the computed --color-base-200 of <html>, after every apply", () => {
  const page = boot({ server: { preset: "burrow-sand", mode: "light" } });
  assert.equal(page.meta.content, "ground(burrow-sand/light)");
  assert.notEqual(page.meta.content, BRANDING_THEME_COLOR);

  page.api.apply({ preset: "high-contrast", mode: "dark" });
  assert.equal(page.meta.content, "ground(high-contrast/dark)");

  page.api.apply({ preset: "burrow" });
  assert.equal(page.meta.content, "ground(base/dark)");
});

test("an empty boot read of the token is retried on DOMContentLoaded", () => {
  const page = boot({ server: { preset: "burrow-forest", mode: "dark" }, emptyComputed: true });
  assert.equal(page.meta.content, BRANDING_THEME_COLOR);
  assert.equal(typeof page.domContentLoaded(), "function");
});

test("window.burrowTheme.apply paints, caches and dispatches burrow:theme", () => {
  const page = boot();
  const result = page.api.apply({ preset: "burrow-midnight", mode: "light" });

  assert.deepEqual(plain(result), { preset: "burrow-midnight", mode: "light", resolved: "light" });
  assert.equal(page.attrs.get("data-preset"), "burrow-midnight");
  assert.equal(page.attrs.get("data-theme"), "light");
  assert.deepEqual(page.cached(), { preset: "burrow-midnight", mode: "light" });
  assert.equal(page.events.at(-1).type, "burrow:theme");

  // A partial apply keeps the other field; an unknown id is ignored.
  page.api.apply({ mode: "dark" });
  assert.deepEqual(plain(page.api.get()), { preset: "burrow-midnight", mode: "dark", resolved: "dark" });
  page.api.apply({ preset: "nope", mode: "dim" });
  assert.deepEqual(plain(page.api.get()), { preset: "burrow-midnight", mode: "dark", resolved: "dark" });
});

// Task 01a1557a stage 5: an org theme published after the page loaded is
// registered by the ThemePicker hook once its CSS has been injected.
test("burrowTheme.register admits an org-<uuid> id only, after which apply accepts it", () => {
  const page = boot();
  const id = "org-01a173d4-9a48-7004-9a0e-e12d2a39a5fe";

  assert.equal(page.api.has(id), false);
  page.api.apply({ preset: id });
  assert.equal(page.attrs.get("data-preset"), undefined, "an unregistered org id was applied");

  for (const bad of ["burrow-x", "org-nope", `${id}"`, 42, null]) {
    assert.equal(page.api.register(bad), false, `registered ${bad}`);
  }

  assert.equal(page.api.register(id), true);
  assert.equal(page.api.has(id), true);
  page.api.apply({ preset: id, mode: "dark" });
  assert.equal(page.attrs.get("data-preset"), id);
  assert.deepEqual(page.cached(), { preset: id, mode: "dark" });
});

test("a storage event on the cache key repaints (cross-tab sync); other keys do not", () => {
  const page = boot();

  page.storageEvent("suite:other:key", JSON.stringify({ preset: "burrow-sand", mode: "light" }));
  assert.equal(page.attrs.has("data-preset"), false);

  page.storageEvent(KEY, JSON.stringify({ preset: "burrow-sand", mode: "light" }));
  assert.equal(page.attrs.get("data-preset"), "burrow-sand");
  assert.equal(page.attrs.get("data-theme"), "light");
  assert.equal(page.meta.content, "ground(burrow-sand/light)");
});
