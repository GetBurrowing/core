// One-off generator for assets/emoji/data.js — the reaction picker's emoji
// inventory. Run it, commit the output; nothing at runtime depends on this
// script or on the network.
//
//     node scripts/generate_emoji_data.mjs            # writes ../emoji/data.js
//     node scripts/generate_emoji_data.mjs --stdout   # print, write nothing
//
// ---------------------------------------------------------------------------
// EMOJI VERSION FLOOR: 14.0. Nothing newer ships.
// ---------------------------------------------------------------------------
// Newer emoji render as empty boxes ("tofu") on older Android and Windows, and
// a picker full of boxes is worse than a short curated list. So the inventory
// is pinned to a version every current platform has had years to ship.
//
// 14.0 is not a taste call, it is forced from below: U+1FAF6 HEART HANDS (🫶)
// is Emoji 14.0 and is ALREADY in production in `@reaction_picker_emojis`
// (lib/platform_web/live/chat/messages_hooks.ex). A lower floor would drop an
// emoji people have already reacted with. 14.0 is also comfortably old — it
// was published 2021-09 and shipped in Android 12L/13, iOS 15.4 and
// Windows 11 22H2 — so it is the floor that is both conservative and legal.
//
// Raising the floor later is a one-line change to EMOJI_VERSION plus a rerun.
// LOWERING it is not: it can strip an emoji already stored in chat_reactions.
//
// Windows has never shipped regional-indicator flag glyphs, so the Flags
// category renders as two-letter boxes there. Accepted, not fixed — the
// alternative is dropping 269 emoji that work everywhere else.
//
// ---------------------------------------------------------------------------
// SOURCES (both fetched at generation time, both pinned)
// ---------------------------------------------------------------------------
//  1. Unicode emoji-test.txt for the 14.0 release. Authoritative for the exact
//     FULLY-QUALIFIED byte sequence of every emoji, plus its group/subgroup and
//     CLDR short name. Using the 14.0 file rather than filtering a later one by
//     E-version means the floor is enforced by the source, not by our parser.
//     Terms: https://www.unicode.org/terms_of_use.html
//  2. CLDR annotations at tag release-41 (the CLDR release contemporaneous with
//     Unicode 14.0) for the search keywords. `common/annotations/en.xml` covers
//     base emoji; `common/annotationsDerived/en.xml` covers derived sequences
//     (flags, keycaps, ZWJ sequences). Unicode licence, same terms.
//
// GOTCHA, and it is the one that silently produces a keyword-less dataset:
// CLDR keys its annotations by the VARIATION-SELECTOR-STRIPPED form. ❤️ is
// `2764 FE0F` in emoji-test.txt but `2764` in en.xml. We emit the FE0F form
// (that is what is already in the database) and look keywords up under the
// stripped form. See stripVs() below.
//
// ---------------------------------------------------------------------------
// EXCLUSIONS
// ---------------------------------------------------------------------------
//  * Anything not `fully-qualified`. The minimally-qualified and unqualified
//    rows are the SAME emoji missing a variation selector; emitting them would
//    put two byte-different spellings of one emoji in the picker, and
//    Chat.list_reactions_grouped/1 groups on exact string match, so they would
//    render as two pills under one message.
//  * The `Component` group (skin-tone swatches, hair components). Not emoji.
//  * Every sequence containing a skin-tone modifier (U+1F3FB..U+1F3FF), for the
//    same grouping reason: a thumbs-up in three tones is three pills each
//    reading 1. Neutral forms only. Their tone keywords are folded onto the
//    neutral entry (see TONE_KEYWORDS) so searching "dark skin tone" still
//    lands somewhere real instead of an empty state.
//
// ZWJ sequences (family, profession, gendered) are NOT skin-tone modifiers and
// are kept.
//
// ---------------------------------------------------------------------------
// OUTPUT SHAPE
// ---------------------------------------------------------------------------
//     { e: "\u{1F63A}", n: "grinning cat", k: ["cat","face",...], c: "animals-nature" }
//
// One-letter keys are deliberate: multiplied across ~1,850 entries, "emoji"/
// "name"/"keywords"/"category" would cost tens of KB for nothing.
//
// `n` and every `k` are emitted ALREADY LOWERCASED AND TRIMMED. Search does not
// normalise the haystack — it lowercases the query and trusts the data, the way
// js/hooks/channel_picker.js does. Doing it here costs one build; doing it at
// runtime costs ~1,850 names plus ~9,000 keywords on every keystroke.

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(HERE, "..", "emoji", "data.js");

const EMOJI_VERSION = "14.0";
const CLDR_TAG = "release-41";

const SOURCES = {
  emojiTest: `https://unicode.org/Public/emoji/${EMOJI_VERSION}/emoji-test.txt`,
  annotations: `https://raw.githubusercontent.com/unicode-org/cldr/${CLDR_TAG}/common/annotations/en.xml`,
  annotationsDerived: `https://raw.githubusercontent.com/unicode-org/cldr/${CLDR_TAG}/common/annotationsDerived/en.xml`,
};

// Unicode's display names, in file order, mapped to the slugs the picker uses
// for its category tabs. Order here IS the tab order.
const CATEGORY_SLUGS = new Map([
  ["Smileys & Emotion", "smileys-emotion"],
  ["People & Body", "people-body"],
  ["Animals & Nature", "animals-nature"],
  ["Food & Drink", "food-drink"],
  ["Travel & Places", "travel-places"],
  ["Activities", "activities"],
  ["Objects", "objects"],
  ["Symbols", "symbols"],
  ["Flags", "flags"],
]);

const SKIN_TONE = /[\u{1F3FB}-\u{1F3FF}]/u;
const VARIATION_SELECTORS = /[︎️]/g;

const XML_ENTITIES = new Map([
  ["amp", "&"],
  ["lt", "<"],
  ["gt", ">"],
  ["quot", '"'],
  ["apos", "'"],
]);

function decodeXml(text) {
  return text.replace(/&(#x?[0-9A-Fa-f]+|[a-z]+);/g, (whole, body) => {
    if (body[0] === "#") {
      const code =
        body[1] === "x" || body[1] === "X"
          ? parseInt(body.slice(2), 16)
          : parseInt(body.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : whole;
    }
    return XML_ENTITIES.get(body) ?? whole;
  });
}

const stripVs = (seq) => seq.replace(VARIATION_SELECTORS, "");

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status} ${res.statusText}`);
  return res.text();
}

/**
 * emoji-test.txt rows, in file order.
 *
 *     1F600 ; fully-qualified # 😀 E1.0 grinning face
 *
 * Group and subgroup arrive as comment lines above their members.
 */
function parseEmojiTest(text) {
  const rows = [];
  let group = null;

  for (const line of text.split("\n")) {
    const groupLine = line.match(/^#\s*group:\s*(.+?)\s*$/);
    if (groupLine) {
      group = groupLine[1];
      continue;
    }

    const row = line.match(
      /^([0-9A-Fa-f ]+?)\s*;\s*(\S+)\s*#\s*\S+\s+E[0-9.]+\s+(.+?)\s*$/
    );
    if (!row) continue;

    const [, codepoints, status, name] = row;
    rows.push({
      seq: String.fromCodePoint(
        ...codepoints.trim().split(/\s+/).map((h) => parseInt(h, 16))
      ),
      status,
      name,
      group,
    });
  }

  return rows;
}

/** `cp` (variation selectors already stripped by CLDR) -> keyword list. */
function parseAnnotations(text, into = new Map()) {
  const re = /<annotation cp="([^"]*)"\s*>([^<]*)<\/annotation>/g;
  for (const [, cp, body] of text.matchAll(re)) {
    const keywords = decodeXml(body)
      .split("|")
      .map((k) => k.trim().toLowerCase())
      .filter(Boolean);
    if (keywords.length) into.set(decodeXml(cp), keywords);
  }
  return into;
}

function build(emojiTest, keywordsByCp) {
  const rows = parseEmojiTest(emojiTest);

  // The tone variants are excluded from the inventory, but "dark skin tone" is
  // a phrase the user can read on their own keyboard, and a search for it
  // returning an empty picker reads as a broken search rather than as a
  // deliberate exclusion. So their keywords are harvested here, from the rows
  // we are about to throw away, and folded onto the neutral entry below.
  //
  // Harvested rather than hardcoded: CLDR is the authority on how it spells
  // these, and in practice it yields exactly the five phrases ("light skin
  // tone" ... "dark skin tone") across 309 tone-capable bases. Keeping the
  // PHRASE and not just the words matters, because the search precedent this
  // dataset is built for (js/hooks/channel_picker.js) substring-matches the
  // whole query — under `includes(q)`, a stored "light" does not match a typed
  // "light skin tone", while the stored phrase matches every substring of
  // itself, "skin tone" and "dark" included.
  const toneKeywords = new Map();
  for (const row of rows) {
    if (row.status !== "fully-qualified" || !SKIN_TONE.test(row.seq)) continue;

    const base = stripVs(row.seq).replace(SKIN_TONE, "");
    if (!toneKeywords.has(base)) toneKeywords.set(base, new Set());
    for (const keyword of keywordsByCp.get(stripVs(row.seq)) ?? []) {
      toneKeywords.get(base).add(keyword);
    }
  }

  const entries = [];
  const seen = new Set();
  const missingKeywords = [];

  for (const row of rows) {
    if (row.status !== "fully-qualified") continue;
    if (!CATEGORY_SLUGS.has(row.group)) continue; // drops the Component group
    if (SKIN_TONE.test(row.seq)) continue;
    if (seen.has(row.seq)) continue;
    seen.add(row.seq);

    const bare = stripVs(row.seq);
    const name = row.name.trim().toLowerCase();

    const keywords = new Set(keywordsByCp.get(bare) ?? []);
    if (!keywords.size) missingKeywords.push(row.seq);
    for (const keyword of toneKeywords.get(bare) ?? []) keywords.add(keyword);
    keywords.delete(name);

    entries.push({
      e: row.seq,
      n: name,
      k: [...keywords],
      c: CATEGORY_SLUGS.get(row.group),
    });
  }

  return { entries, missingKeywords };
}

/**
 * Emits the sequences as \u escapes rather than literal glyphs. The file is
 * then pure ASCII, which makes it diffable, immune to an editor or a git
 * filter re-normalising a variation selector, and reviewable — a reviewer can
 * SEE that ❤️ carries its FE0F, which is invisible in the glyph.
 */
const escape = (str) =>
  [...str]
    .map((ch) => {
      const cp = ch.codePointAt(0);
      return cp > 0xffff
        ? `\\u{${cp.toString(16).toUpperCase()}}`
        : `\\u${cp.toString(16).toUpperCase().padStart(4, "0")}`;
    })
    .join("");

const jsString = (str) => JSON.stringify(str);

function render(entries) {
  const byCategory = new Map();
  for (const entry of entries) {
    if (!byCategory.has(entry.c)) byCategory.set(entry.c, []);
    byCategory.get(entry.c).push(entry);
  }

  const lines = [
    "// GENERATED FILE — DO NOT EDIT BY HAND.",
    "//",
    "// Regenerate with:  node scripts/generate_emoji_data.mjs",
    "// The generator carries the full rationale: the Emoji 14.0 version floor,",
    "// the sources and their licences, and why skin-tone forms are excluded.",
    "//",
    "// It lives in assets/emoji/ and NOT in assets/js/ on purpose: app.css",
    "// declares `@source \"../js\"`, so Tailwind scans every file under assets/js.",
    "// CLDR emoji keywords include \"block\", \"flex\", \"grid\" and \"table\", and",
    "// Tailwind would mine utility classes out of them. The thin esbuild entry",
    "// point that imports this file is js/emoji_island.js.",
    "//",
    `// Source: Unicode emoji-test.txt ${EMOJI_VERSION} + CLDR ${CLDR_TAG} annotations (en).`,
    `// ${entries.length} emoji in ${byCategory.size} categories.`,
    "//",
    "// `n` and every `k` are ALREADY lowercased and trimmed. Search lowercases",
    "// the query only; it must not re-normalise the haystack.",
    "",
    "/** Category slugs in picker tab order. */",
    "export const CATEGORIES = [",
    ...[...byCategory.keys()].map((c) => `  ${jsString(c)},`),
    "];",
    "",
    "/**",
    " * @typedef {object} EmojiEntry",
    " * @property {string} e Fully-qualified emoji, exactly as it must be stored.",
    " * @property {string} n CLDR short name, lowercase.",
    " * @property {string[]} k CLDR keywords, lowercase, none equal to `n`.",
    " * @property {string} c Category slug, one of CATEGORIES.",
    " */",
    "",
    "/** @type {EmojiEntry[]} */",
    "export const EMOJI = [",
  ];

  for (const [category, group] of byCategory) {
    lines.push(`  // ${category} (${group.length})`);
    for (const entry of group) {
      lines.push(
        `  { e: "${escape(entry.e)}", n: ${jsString(entry.n)}, k: [${entry.k
          .map(jsString)
          .join(",")}], c: ${jsString(entry.c)} },`
      );
    }
  }

  lines.push("];", "", "export default EMOJI;", "");
  return lines.join("\n");
}

const [emojiTest, annotations, annotationsDerived] = await Promise.all([
  fetchText(SOURCES.emojiTest),
  fetchText(SOURCES.annotations),
  fetchText(SOURCES.annotationsDerived),
]);

const keywordsByCp = parseAnnotations(
  annotationsDerived,
  parseAnnotations(annotations)
);

const { entries, missingKeywords } = build(emojiTest, keywordsByCp);
const output = render(entries);

if (process.argv.includes("--stdout")) {
  process.stdout.write(output);
} else {
  await fs.writeFile(OUT, output, "utf8");
}

const keywordCount = entries.reduce((n, entry) => n + entry.k.length, 0);
process.stderr.write(
  [
    `emoji:            ${entries.length}`,
    `categories:       ${new Set(entries.map((e) => e.c)).size}`,
    `keywords:         ${keywordCount} (${(keywordCount / entries.length).toFixed(1)} per emoji)`,
    `without keywords: ${missingKeywords.length}${missingKeywords.length ? ` -> ${missingKeywords.join(" ")}` : ""}`,
    `raw output:       ${Buffer.byteLength(output)} bytes`,
    "",
  ].join("\n")
);
