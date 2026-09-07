// Integrity tests for the generated emoji inventory (assets/emoji/data.js).
//
// The dataset is machine-generated, so these do not check taste — they check
// the properties the picker and, more importantly, the DATABASE depend on.

import { test } from "node:test";
import assert from "node:assert/strict";

import { EMOJI, CATEGORIES } from "../emoji/data.js";

// ── The round trip that actually matters ────────────────────────────────────
//
// These are the emoji ALREADY IN PRODUCTION USE: the 32 in
// `@reaction_picker_emojis` (lib/platform_web/live/chat/messages_hooks.ex) and
// the 6 in the longpress overlay literal (live/chat/partials/overlays.ex).
// People have already reacted with them, so those exact byte sequences are
// sitting in chat_reactions right now.
//
// They are frozen here as escapes rather than read out of the .ex files on
// purpose. The .ex literals are about to be replaced by the new picker; the
// bytes in the database are not, and it is the bytes in the database this test
// is protecting. Escapes rather than glyphs so a reviewer can SEE the variation
// selector.
//
// THE TRAP: `❤️` (❤️, what is live) and `❤` (bare ❤) are
// different strings. Chat.list_reactions_grouped/1 groups with
// `Enum.group_by(& &1.emoji)` — exact string match — so if the generator
// normalised the heart away, every message would grow a SECOND heart pill: one
// holding every reaction from before this ticket, one from after. There is no
// migration that repairs that, because there is no way to tell the two apart
// after the fact.
const LIVE_PICKER_EMOJI = [
  "\u{1F44D}", "\u{1F44E}", "❤️", "\u{1F525}",
  "\u{1F389}", "\u{1F680}", "✅", "❌",
  "\u{1F600}", "\u{1F602}", "\u{1F605}", "\u{1F60A}",
  "\u{1F60D}", "\u{1F914}", "\u{1F62E}", "\u{1F622}",
  "\u{1F64F}", "\u{1F44F}", "\u{1F64C}", "\u{1F4AA}",
  "\u{1F440}", "\u{1F4A1}", "⭐", "✨",
  "\u{1F973}", "\u{1F92F}", "\u{1F4AF}", "\u{1FAF6}",
  "\u{1F91D}", "☕", "\u{1F355}", "\u{1F41B}",
];

const LIVE_LONGPRESS_EMOJI = [
  "\u{1F44D}", "\u{1F389}", "✅", "❤️", "\u{1F602}", "\u{1F64F}",
];

const codepoints = (str) =>
  [...str].map((c) => c.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")).join(" ");

const shipped = new Set(EMOJI.map((entry) => entry.e));

test("every emoji already in production is in the dataset, byte-identical", () => {
  assert.equal(LIVE_PICKER_EMOJI.length, 32);
  assert.equal(LIVE_LONGPRESS_EMOJI.length, 6);

  for (const emoji of [...LIVE_PICKER_EMOJI, ...LIVE_LONGPRESS_EMOJI]) {
    assert.ok(
      shipped.has(emoji),
      `${emoji} (U+${codepoints(emoji)}) is in production use but is NOT in ` +
        `assets/emoji/data.js as that exact byte sequence. Reactions are grouped ` +
        `by exact string match, so shipping a different spelling of it splits ` +
        `every existing reaction on it into a second pill, permanently. Check ` +
        `the Emoji version floor in scripts/generate_emoji_data.mjs and whether ` +
        `a variation selector was normalised away.`
    );
  }
});

test("the heart keeps its variation selector and the bare heart is absent", () => {
  // The single most likely normalisation slip, asserted in both directions so
  // the test cannot pass by the dataset containing both spellings.
  assert.ok(shipped.has("❤️"), "U+2764 U+FE0F (❤️) must be present");
  assert.ok(!shipped.has("❤"), "bare U+2764 (❤) must NOT be present");
});

test("the version floor holds: heart hands (Emoji 14.0) ships", () => {
  // U+1FAF6 is Emoji 14.0 and is already live. It is the entry that pins the
  // floor — if a future regeneration lowers EMOJI_VERSION, this fires.
  assert.ok(shipped.has("\u{1FAF6}"));
});

// ── Category coverage ───────────────────────────────────────────────────────

test("every entry is in exactly one declared category, and no category is empty", () => {
  const counts = new Map(CATEGORIES.map((c) => [c, 0]));

  for (const entry of EMOJI) {
    assert.ok(
      counts.has(entry.c),
      `${entry.e} has category ${JSON.stringify(entry.c)}, which is not in CATEGORIES`
    );
    counts.set(entry.c, counts.get(entry.c) + 1);
  }

  for (const [category, count] of counts) {
    assert.ok(count > 0, `category ${category} is empty`);
  }

  assert.equal(CATEGORIES.length, new Set(CATEGORIES).size, "CATEGORIES has a duplicate");
});

test("no emoji appears twice", () => {
  assert.equal(
    shipped.size,
    EMOJI.length,
    "assets/emoji/data.js contains a duplicate emoji — it would render twice in " +
      "the grid and, if the duplicates disagree on category, in two tabs."
  );
});

test("the inventory is the expected order of magnitude", () => {
  // A floor and a ceiling, not an exact count: the point is to catch a
  // regeneration that silently dropped a category or let skin-tone forms back
  // in (which would roughly triple the count), not to churn on +/- one emoji.
  assert.ok(EMOJI.length > 1500, `only ${EMOJI.length} emoji — a category was probably dropped`);
  assert.ok(EMOJI.length < 2200, `${EMOJI.length} emoji — skin-tone forms may have leaked back in`);
});

test("no skin-tone modifier forms", () => {
  // Excluded because grouping is by exact string: a thumbs-up in three tones
  // is three pills under one message, each reading 1.
  const withTone = EMOJI.filter((entry) => /[\u{1F3FB}-\u{1F3FF}]/u.test(entry.e));
  assert.deepEqual(
    withTone.map((entry) => entry.e),
    [],
    "skin-tone modifier forms must not ship"
  );
});

test("ZWJ sequences DO ship", () => {
  // The other half of the rule above: ZWJ sequences (family, profession,
  // gendered) are not skin-tone modifiers and must survive the filter.
  const zwj = EMOJI.filter((entry) => entry.e.includes("‍"));
  assert.ok(zwj.length > 100, `only ${zwj.length} ZWJ sequences — the filter is too broad`);
  assert.ok(shipped.has("\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}"), "family: man, woman, girl, boy");
});

// ── Keyword integrity ───────────────────────────────────────────────────────
//
// Search lowercases the QUERY only and trusts the haystack — the precedent is
// js/hooks/channel_picker.js. Lowercasing ~1,850 names and ~6,000 keywords on
// every keystroke is work the generator already did once, so these assert the
// generator really did it.

test("every entry has a non-empty, lowercase, trimmed name", () => {
  for (const entry of EMOJI) {
    assert.ok(entry.n && entry.n.length > 0, `${entry.e} has an empty name`);
    assert.equal(entry.n, entry.n.toLowerCase(), `${entry.e} name is not lowercase: ${entry.n}`);
    assert.equal(entry.n, entry.n.trim(), `${entry.e} name is not trimmed: ${JSON.stringify(entry.n)}`);
  }
});

test("every keyword is lowercase, trimmed, non-empty, and not a copy of the name", () => {
  for (const entry of EMOJI) {
    assert.ok(Array.isArray(entry.k), `${entry.e} has no keyword array`);

    for (const keyword of entry.k) {
      assert.ok(keyword.length > 0, `${entry.e} has an empty keyword`);
      assert.equal(keyword, keyword.toLowerCase(), `${entry.e} keyword not lowercase: ${keyword}`);
      assert.equal(keyword, keyword.trim(), `${entry.e} keyword not trimmed: ${JSON.stringify(keyword)}`);
      assert.notEqual(
        keyword,
        entry.n,
        `${entry.e} repeats its own name ${JSON.stringify(entry.n)} as a keyword — ` +
          `dead bytes multiplied across the inventory`
      );
    }

    assert.equal(entry.k.length, new Set(entry.k).size, `${entry.e} has a duplicate keyword`);
  }
});

test("the variation-selector lookup held: FE0F entries are as searchable as the rest", () => {
  // The specific failure this catches, which the generator hit in draft: CLDR
  // keys its annotations by the VARIATION-SELECTOR-STRIPPED form (❤️ is
  // `2764 FE0F` in emoji-test.txt but `2764` in CLDR en.xml). Look keywords up
  // under the unstripped sequence and every FE0F-carrying emoji comes back with
  // none — while the dataset still parses, still renders, and is simply
  // unsearchable for 344 of its entries. Nothing else notices.
  //
  // So this compares COVERAGE between the two populations rather than demanding
  // every entry have keywords. A blanket "k is non-empty" would be the wrong
  // instrument twice over: it fails on ~43 entries whose only CLDR keyword is
  // their own name (🐒 "monkey", ⚠️ "warning") and which the previous test
  // correctly strips, and it would still pass if FE0F coverage merely sagged.
  const coverage = (entries) =>
    entries.length === 0 ? 1 : entries.filter((e) => e.k.length > 0).length / entries.length;

  const withVs = EMOJI.filter((entry) => entry.e.includes("\uFE0F"));
  const withoutVs = EMOJI.filter((entry) => !entry.e.includes("\uFE0F"));

  assert.ok(withVs.length > 300, `only ${withVs.length} FE0F entries — is the dataset right?`);
  assert.ok(
    coverage(withVs) > coverage(withoutVs) - 0.05,
    `keyword coverage is ${(100 * coverage(withVs)).toFixed(1)}% for FE0F-carrying emoji ` +
      `against ${(100 * coverage(withoutVs)).toFixed(1)}% for the rest. That gap means the ` +
      `generator looked CLDR up under the unstripped sequence. See stripVs() in ` +
      `scripts/generate_emoji_data.mjs.`
  );

  // Belt and braces on the single entry that matters most, since it is both
  // FE0F-carrying and already in production.
  const heart = EMOJI.find((entry) => entry.e === "❤️");
  assert.ok(heart.k.length > 0, "the FE0F-carrying heart lost its keywords");
});

test("a skin-tone search lands on the neutral emoji instead of an empty state", () => {
  // Tone variants are excluded from the inventory, but "dark skin tone" is a
  // phrase the user can read on their own keyboard, and a search for it hitting
  // an empty picker reads as a broken search rather than a deliberate
  // exclusion. The generator folds the tone variants' own CLDR keywords onto
  // the neutral entry.
  //
  // Asserted as the WHOLE PHRASE, not as the word "light", because the search
  // precedent (js/hooks/channel_picker.js) substring-matches the entire query:
  // under `includes(q)` a stored "light" does not match a typed "light skin
  // tone", while the stored phrase matches every substring of itself.
  const thumbsUp = EMOJI.find((entry) => entry.e === "\u{1F44D}");
  for (const phrase of ["light skin tone", "medium skin tone", "dark skin tone"]) {
    assert.ok(thumbsUp.k.includes(phrase), `👍 is tone-capable but is missing ${phrase}`);
  }

  // And the negative half: an emoji with no tone variants must not carry them,
  // or the phrases are 1,500 dead keywords instead of a working search.
  const grinning = EMOJI.find((entry) => entry.e === "\u{1F600}");
  assert.ok(
    !grinning.k.some((keyword) => keyword.includes("skin tone")),
    "😀 has no tone variants, so tone keywords on it are dead bytes"
  );
});
