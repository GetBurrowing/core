import { describe, it, expect } from "vitest"
import { handoverText, collectFields, saveText } from "../../js/hooks/handover_download.js"

const KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"

describe("handoverText", () => {
  it("writes one line per value, the key as a block, and skips blanks", () => {
    const text = handoverText([
      { label: "Burrow", value: "https://acme.example" },
      { label: "Admin", value: "owner@acme.example" },
      { label: "Sign-in link", value: "https://auth.acme.example/lc/CODE" },
      { label: "Missing", value: "" },
      { label: "SSH private key", value: KEY },
    ])

    expect(text).toBe(
      [
        "Your Burrow",
        "===========",
        "",
        "Burrow: https://acme.example",
        "Admin: owner@acme.example",
        "Sign-in link: https://auth.acme.example/lc/CODE",
        "SSH private key:",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "AAAA",
        "-----END OPENSSH PRIVATE KEY-----",
        "",
      ].join("\n"),
    )
    expect(text).not.toMatch(/Missing/)
  })
})

describe("collectFields", () => {
  it("reads label from the attribute and value from data-value, else text", () => {
    const el = (label, value, text) => ({ dataset: { handoverField: label, ...(value === undefined ? {} : { value }) }, textContent: text })
    const root = { querySelectorAll: (sel) => (expect(sel).toBe("[data-handover-field]"), [el("Burrow", "https://a.example", "ignored"), el("Admin", undefined, "  owner@a.example \n")]) }

    expect(collectFields(root)).toEqual([
      { label: "Burrow", value: "https://a.example" },
      { label: "Admin", value: "owner@a.example" },
    ])
  })
})

describe("saveText", () => {
  it("clicks a download link to a Blob URL and removes it again", async () => {
    const events = []
    const anchor = { click: () => events.push("click"), remove: () => events.push("remove") }
    const document = { createElement: (tag) => (events.push(`create ${tag}`), anchor), body: { appendChild: () => events.push("append") } }
    const blobs = []
    class FakeBlob { constructor(parts, opts) { blobs.push({ parts, opts }) } }
    const URL = { createObjectURL: () => "blob:fake/1", revokeObjectURL: (u) => events.push(`revoke ${u}`) }

    expect(saveText("hello\n", "burrow-details.txt", { document, URL, Blob: FakeBlob })).toBe("blob:fake/1")
    expect(anchor.download).toBe("burrow-details.txt")
    expect(anchor.href).toBe("blob:fake/1")
    expect(blobs).toEqual([{ parts: ["hello\n"], opts: { type: "text/plain;charset=utf-8" } }])
    expect(events).toEqual(["create a", "append", "click", "remove"])

    await new Promise((r) => setTimeout(r, 5))
    expect(events).toContain("revoke blob:fake/1")
  })
})
