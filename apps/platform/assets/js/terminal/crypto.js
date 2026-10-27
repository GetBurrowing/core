// Remote terminal wire crypto, protocol v1 (browser end).
//
// X25519, then HKDF-SHA256 (salt = session id, info = a direction label) into
// two AES-256-GCM keys. A frame is `counter (8 bytes, big endian) || ciphertext
// || 16-byte tag`; the nonce is `direction id (4 bytes) || counter (8 bytes)`;
// the plaintext is `kind (1 byte) || body`, kind 0 raw terminal bytes, kind 1 a
// JSON control record. Byte for byte as src/terminal/crypto.ts in burrow-cli;
// test/terminal/crypto.test.js checks it against the shared vector file.
//
// WHAT THIS PROTECTS. The keys are ephemeral and unauthenticated. They keep a
// PASSIVE relay (its logs, its database dumps, an operator reading traffic)
// from reading the stream. They do not stop a relay that actively swaps the
// `hello` keys for its own.
//
// There is NO plaintext fallback anywhere in this module. A browser without
// X25519 in WebCrypto gets `supportsX25519() === false` and the caller refuses.

export const DIR_CLI_TO_BROWSER = 1
export const DIR_BROWSER_TO_CLI = 2
export const KIND_DATA = 0
export const KIND_CONTROL = 1
export const INFO_CLI_TO_BROWSER = "burrow-terminal v1 cli->browser"
export const INFO_BROWSER_TO_CLI = "burrow-terminal v1 browser->cli"

const enc = new TextEncoder()
const subtleOf = (subtle) => subtle ?? globalThis.crypto?.subtle

/** True when this browser can do X25519 in WebCrypto. */
export async function supportsX25519(subtle) {
  const s = subtleOf(subtle)
  if (!s) return false
  try {
    await s.generateKey({ name: "X25519" }, false, ["deriveBits"])
    return true
  } catch {
    return false
  }
}

/** `{ publicRaw: Uint8Array(32), privateKey: CryptoKey }`, private key non-extractable. */
export async function generateKeyPair(subtle) {
  const s = subtleOf(subtle)
  const pair = await s.generateKey({ name: "X25519" }, true, ["deriveBits"])
  const publicRaw = new Uint8Array(await s.exportKey("raw", pair.publicKey))
  return { publicRaw, privateKey: pair.privateKey }
}

async function hkdfBits(s, shared, sessionId, info) {
  const base = await s.importKey("raw", shared, "HKDF", false, ["deriveBits"])
  return new Uint8Array(
    await s.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: enc.encode(sessionId), info: enc.encode(info) },
      base,
      256
    )
  )
}

/**
 * Both direction keys as raw bytes, from the browser's private key and the
 * CLI's raw public key. `send` seals what the browser sends (browser->cli),
 * `recv` opens what the CLI sends (cli->browser).
 */
export async function deriveKeyBytes(privateKey, peerPublicRaw, sessionId, subtle) {
  const s = subtleOf(subtle)
  if (peerPublicRaw.length !== 32) throw new Error("peer public key must be 32 bytes")
  const peer = await s.importKey("raw", peerPublicRaw, { name: "X25519" }, false, [])
  const shared = new Uint8Array(await s.deriveBits({ name: "X25519", public: peer }, privateKey, 256))
  const [c2b, b2c] = await Promise.all([
    hkdfBits(s, shared, sessionId, INFO_CLI_TO_BROWSER),
    hkdfBits(s, shared, sessionId, INFO_BROWSER_TO_CLI),
  ])
  return { send: b2c, recv: c2b }
}

export const importAesKey = (bytes, subtle) =>
  subtleOf(subtle).importKey("raw", bytes, { name: "AES-GCM" }, false, ["encrypt", "decrypt"])

/** The AES keys for a session, ready to seal and open. */
export async function deriveSessionKeys(privateKey, peerPublicRaw, sessionId, subtle) {
  const bytes = await deriveKeyBytes(privateKey, peerPublicRaw, sessionId, subtle)
  const [send, recv] = await Promise.all([importAesKey(bytes.send, subtle), importAesKey(bytes.recv, subtle)])
  return { send, recv }
}

function nonceFor(direction, counter) {
  const n = new Uint8Array(12)
  const v = new DataView(n.buffer)
  v.setUint32(0, direction)
  v.setBigUint64(4, counter)
  return n
}

/** Seal `plaintext` as frame number `counter` (BigInt). */
export async function sealFrame(key, direction, counter, plaintext, subtle) {
  const ct = new Uint8Array(
    await subtleOf(subtle).encrypt({ name: "AES-GCM", iv: nonceFor(direction, counter), tagLength: 128 }, key, plaintext)
  )
  const out = new Uint8Array(8 + ct.length)
  new DataView(out.buffer).setBigUint64(0, counter)
  out.set(ct, 8)
  return out
}

/** `{ counter, plaintext }`. Throws on a short frame or a failed tag. */
export async function openFrame(key, direction, frame, subtle) {
  if (frame.length < 8 + 16) throw new Error("frame too short")
  const counter = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getBigUint64(0)
  const plaintext = new Uint8Array(
    await subtleOf(subtle).decrypt(
      { name: "AES-GCM", iv: nonceFor(direction, counter), tagLength: 128 },
      key,
      frame.subarray(8)
    )
  )
  return { counter, plaintext }
}

/** Seals a stream of records with a rising counter. */
export class Sender {
  #next = 0n
  constructor(key, direction, subtle) {
    this.key = key
    this.direction = direction
    this.subtle = subtle
  }
  async seal(kind, body) {
    const plain = new Uint8Array(1 + body.length)
    plain[0] = kind
    plain.set(body, 1)
    const counter = this.#next
    this.#next += 1n
    return sealFrame(this.key, this.direction, counter, plain, this.subtle)
  }
}

/** Opens a stream of records and rejects any counter that does not rise. */
export class Receiver {
  #last = -1n
  constructor(key, direction, subtle) {
    this.key = key
    this.direction = direction
    this.subtle = subtle
  }
  /** `{ kind, body }`, or null when the frame is replayed, reordered, truncated or forged. */
  async open(frame) {
    if (frame.length < 8) return null
    const counter = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getBigUint64(0)
    if (counter <= this.#last) return null
    let opened
    try {
      opened = await openFrame(this.key, this.direction, frame, this.subtle)
    } catch {
      return null
    }
    // Only an authentic frame advances the counter.
    this.#last = counter
    if (opened.plaintext.length < 1) return null
    return { kind: opened.plaintext[0], body: opened.plaintext.subarray(1) }
  }
}

export const toB64 = (bytes) => {
  let s = ""
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s)
}

export const fromB64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0))
