import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { createHash } from "node:crypto"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"
import {
  DIR_BROWSER_TO_CLI,
  DIR_CLI_TO_BROWSER,
  Receiver,
  Sender,
  deriveKeyBytes,
  generateKeyPair,
  importAesKey,
  openFrame,
  sealFrame,
  supportsX25519,
} from "../../js/terminal/crypto.js"

// The shared protocol vectors, copied byte for byte from burrow-cli
// test/fixtures/terminal_crypto_v1.json (PR 52, 76b7963). The digest pins the copy.
const FILE = resolve(dirname(fileURLToPath(import.meta.url)), "../../../test/fixtures/terminal_crypto_v1.json")
const raw = readFileSync(FILE)
const v = JSON.parse(raw.toString("utf8"))
const hex = (s) => Uint8Array.from(Buffer.from(s, "hex"))
const PKCS8_X25519 = Buffer.from("302e020100300506032b656e04220420", "hex")

const importPrivate = (privHex) =>
  crypto.subtle.importKey("pkcs8", Buffer.concat([PKCS8_X25519, Buffer.from(privHex, "hex")]), { name: "X25519" }, false, ["deriveBits"])

describe("protocol v1 vectors", () => {
  it("is the file copied from burrow-cli, byte for byte", () => {
    expect(createHash("sha256").update(raw).digest("hex")).toBe(
      "9a23dc0482c1431e84de2db5e37da6cf392608cb2100dcb6075854acd1536c41"
    )
  })

  it("derives the vector keys from the browser's private key", async () => {
    const priv = await importPrivate(v.browser_private_hex)
    const keys = await deriveKeyBytes(priv, hex(v.cli_public_hex), v.session_id)
    expect(Buffer.from(keys.recv).toString("hex")).toBe(v.key_cli_to_browser_hex)
    expect(Buffer.from(keys.send).toString("hex")).toBe(v.key_browser_to_cli_hex)
  })

  it("seals and opens every vector frame exactly", async () => {
    const c2b = await importAesKey(hex(v.key_cli_to_browser_hex))
    const b2c = await importAesKey(hex(v.key_browser_to_cli_hex))
    const dir = v.direction_ids

    for (const f of v.out_frames) {
      const plain = Uint8Array.from([f.kind, ...hex(f.plaintext_hex)])
      const sealed = await sealFrame(c2b, dir.cli_to_browser, BigInt(f.counter), plain)
      expect(Buffer.from(sealed).toString("hex")).toBe(f.frame_hex)
      const opened = await openFrame(c2b, DIR_CLI_TO_BROWSER, hex(f.frame_hex))
      expect(Buffer.from(opened.plaintext).toString("hex")).toBe(Buffer.from(plain).toString("hex"))
      expect(opened.counter).toBe(BigInt(f.counter))
    }
    for (const f of v.in_frames) {
      const plain = Uint8Array.from([f.kind, ...hex(f.plaintext_hex)])
      const sealed = await sealFrame(b2c, dir.browser_to_cli, BigInt(f.counter), plain)
      expect(Buffer.from(sealed).toString("hex")).toBe(f.frame_hex)
    }
  })

  it("a flipped bit does not open", async () => {
    const c2b = await importAesKey(hex(v.key_cli_to_browser_hex))
    const frame = hex(v.out_frames[0].frame_hex)
    frame[12] ^= 1
    await expect(openFrame(c2b, DIR_CLI_TO_BROWSER, frame)).rejects.toThrow()
  })
})

describe("a live handshake between two fresh key pairs", () => {
  it("round-trips both directions and rejects replays and reorders", async () => {
    expect(await supportsX25519()).toBe(true)
    const cli = await generateKeyPair()
    const browser = await generateKeyPair()
    const sid = "session-abc"
    const b = await deriveKeyBytes(browser.privateKey, cli.publicRaw, sid)
    const c = await deriveKeyBytes(cli.privateKey, browser.publicRaw, sid)
    // The function is role-free: `send` is always browser->cli, `recv` cli->browser.
    expect(Buffer.from(b.send)).toEqual(Buffer.from(c.send))
    expect(Buffer.from(b.recv)).toEqual(Buffer.from(c.recv))

    const send = new Sender(await importAesKey(b.send), DIR_BROWSER_TO_CLI)
    const recv = new Receiver(await importAesKey(c.send), DIR_BROWSER_TO_CLI)
    const f0 = await send.seal(0, new TextEncoder().encode("ls\r"))
    const f1 = await send.seal(0, new TextEncoder().encode("pwd\r"))

    expect(Buffer.from((await recv.open(f1)).body).toString()).toBe("pwd\r")
    expect(await recv.open(f0)).toBeNull() // reordered
    expect(await recv.open(f1)).toBeNull() // replayed
    const forged = Uint8Array.from(f1)
    forged[forged.length - 1] ^= 1
    expect(await recv.open(forged)).toBeNull()
    expect(await recv.open(new Uint8Array(3))).toBeNull()
  })

  it("a wrong direction does not open", async () => {
    const k = await importAesKey(new Uint8Array(32).fill(7))
    const frame = await sealFrame(k, DIR_BROWSER_TO_CLI, 0n, Uint8Array.from([0, 65]))
    await expect(openFrame(k, DIR_CLI_TO_BROWSER, frame)).rejects.toThrow()
  })
})

describe("no X25519, no terminal", () => {
  it("reports unsupported instead of falling back", async () => {
    const subtle = { generateKey: async () => { throw new Error("NotSupportedError") } }
    expect(await supportsX25519(subtle)).toBe(false)
  })
})
