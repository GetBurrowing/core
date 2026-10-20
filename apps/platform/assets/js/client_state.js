// Suite.ClientState — the single localStorage-wrapping API.
//
// Every persistence-touching hook migrates to this module (task 019f3e9a).
// Direct `localStorage.*` calls outside `burrow-theme-v1` become lint-gated in a
// later stage; this file is the sole approved consumer.
//
// Contract:
//   - Keys are namespaced as `suite:<namespace>:<key>`. The `suite:` prefix
//     mirrors the existing `suite:tasks-last-project-id` convention already
//     baked into hooks like `last_project.js` — new callers get it for free.
//   - Values JSON-serialize on write. Reads try `JSON.parse` first; if it
//     throws, we return the raw string. This lets a caller migrate a legacy
//     `localStorage.setItem(key, "blocked")`-style value byte-identically
//     without a data-shape flag day.
//   - Every `localStorage.*` call is wrapped in try/catch. On
//     QuotaExceededError OR SecurityError (private-mode Safari) we flip
//     `_disabled = true` and fall back to an in-memory `Map` for the rest of
//     the tab's lifetime. `available()` reports the current mode.
//   - Optional TTL envelope: `set(ns, key, value, {ttlMs})` writes a
//     `{v, e}` shape where `e` is the absolute expiry epoch. `get` strips
//     the envelope and treats expired reads as missing (returns default).
//     Non-envelope values (raw or plain JSON) pass through unchanged, so
//     older callers see no behaviour change.

const PREFIX = "suite:";

const memory = new Map();
let disabled = false;

function isSecurityLike(err) {
  if (!err) return false;
  // Both DOMException `SecurityError` and the QuotaExceededError family are
  // fatal for the localStorage path; we treat both as "flip to in-memory".
  const name = err.name || "";
  return (
    name === "SecurityError" ||
    name === "QuotaExceededError" ||
    name === "NS_ERROR_DOM_QUOTA_REACHED" ||
    name === "QUOTA_EXCEEDED_ERR"
  );
}

function storageKey(namespace, key) {
  return `${PREFIX}${namespace}:${key}`;
}

function readRaw(fullKey) {
  if (disabled) return memory.has(fullKey) ? memory.get(fullKey) : null;
  try {
    return globalThis.localStorage.getItem(fullKey);
  } catch (err) {
    if (isSecurityLike(err)) {
      disabled = true;
      return memory.has(fullKey) ? memory.get(fullKey) : null;
    }
    return null;
  }
}

function writeRaw(fullKey, encoded) {
  if (disabled) {
    memory.set(fullKey, encoded);
    return;
  }
  try {
    globalThis.localStorage.setItem(fullKey, encoded);
  } catch (err) {
    if (isSecurityLike(err)) {
      disabled = true;
      memory.set(fullKey, encoded);
    }
    // On any other error (unlikely — set() is spec'd to only throw these two
    // families) we silently drop; a persistence best-effort has failed but
    // callers are not expected to react.
  }
}

function removeRaw(fullKey) {
  if (disabled) {
    memory.delete(fullKey);
    return;
  }
  try {
    globalThis.localStorage.removeItem(fullKey);
  } catch (err) {
    if (isSecurityLike(err)) {
      disabled = true;
      memory.delete(fullKey);
    }
  }
}

function listKeys() {
  const keys = [];
  if (disabled) {
    for (const k of memory.keys()) keys.push(k);
    return keys;
  }
  try {
    const ls = globalThis.localStorage;
    for (let i = 0; i < ls.length; i++) {
      const k = ls.key(i);
      if (k != null) keys.push(k);
    }
    return keys;
  } catch (err) {
    if (isSecurityLike(err)) {
      disabled = true;
      for (const k of memory.keys()) keys.push(k);
    }
    return keys;
  }
}

function decode(raw) {
  if (raw == null) return { missing: true };
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_err) {
    // Legacy byte-identical value (e.g. `localStorage.setItem(k, "blocked")`).
    return { value: raw };
  }
  if (
    parsed &&
    typeof parsed === "object" &&
    !Array.isArray(parsed) &&
    Object.prototype.hasOwnProperty.call(parsed, "v") &&
    Object.prototype.hasOwnProperty.call(parsed, "e") &&
    typeof parsed.e === "number"
  ) {
    if (Date.now() >= parsed.e) return { missing: true, expired: true };
    return { value: parsed.v };
  }
  return { value: parsed };
}

const ClientState = {
  get(namespace, key, defaultValue = null) {
    const fullKey = storageKey(namespace, key);
    const raw = readRaw(fullKey);
    const decoded = decode(raw);
    if (decoded.missing) {
      if (decoded.expired) {
        // Expired — proactively clean up the stale envelope.
        removeRaw(fullKey);
      }
      return defaultValue;
    }
    return decoded.value;
  },

  set(namespace, key, value, opts = {}) {
    const fullKey = storageKey(namespace, key);
    let payload;
    if (typeof opts.ttlMs === "number") {
      payload = { v: value, e: Date.now() + opts.ttlMs };
    } else {
      payload = value;
    }
    let encoded;
    try {
      encoded = JSON.stringify(payload);
    } catch (_err) {
      // Un-serializable value; nothing sensible to persist.
      return;
    }
    if (encoded === undefined) return; // JSON.stringify(undefined) case
    writeRaw(fullKey, encoded);
  },

  remove(namespace, key) {
    removeRaw(storageKey(namespace, key));
  },

  clear(namespace) {
    const prefix = `${PREFIX}${namespace}:`;
    for (const k of listKeys()) {
      if (k.startsWith(prefix)) removeRaw(k);
    }
  },

  clearAll() {
    for (const k of listKeys()) {
      if (k.startsWith(PREFIX)) removeRaw(k);
    }
  },

  available() {
    return !disabled;
  },
};

// Test-only reset — not part of the public contract, but keeps the vitest
// suite hermetic without exporting internal state at runtime. Guarded by a
// leading underscore so it does not appear in any published surface.
export function __resetForTests() {
  disabled = false;
  memory.clear();
}

export { ClientState };
export default ClientState;
