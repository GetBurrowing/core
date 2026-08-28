/**
 * Enumerate the SERVED stylesheet and count `.chat-jump*` rules sitting
 * inside any hover- or pointer-gated media query.
 *
 * WHY THIS AND NOT AN A/B EMULATION PROBE. `Emulation.setEmulatedMedia` for
 * hover/pointer is a confirmed no-op on this box. A probe that fails to flip
 * `matchMedia` proves only that the probe cannot tell — it is evidence about
 * the instrument, not about the product. Counting the rules removes the
 * dependence completely: if the count is zero then no rule on this component
 * is contingent on a hover/pointer query, and whether emulation works is
 * irrelevant to the claim. That is what the unconditional padding bought.
 */
const PORT = process.env.SPORT || "4021";
const url = `http://localhost:${PORT}/assets/css/app.css`;
const res = await fetch(url);
const src = await res.text();
if (!res.ok || src.length < 1000) {
  console.error("VOID: served stylesheet not fetched", res.status, src.length);
  process.exit(2);
}

function stripComments(s) {
  let o = "", i = 0;
  while (i < s.length) {
    if (s[i] === "/" && s[i + 1] === "*") {
      const e = s.indexOf("*/", i + 2), stop = e === -1 ? s.length : e + 2;
      for (let k = i; k < stop; k++) o += s[k] === "\n" ? "\n" : " ";
      i = stop;
    } else { o += s[i]; i++; }
  }
  return o;
}

const clean = stripComments(src);
const rules = [];
const stack = [];
let prelude = "";
for (let i = 0; i < clean.length; i++) {
  const c = clean[i];
  if (c === "{") {
    const t = prelude.trim();
    const f = { text: t, at: t.startsWith("@"), body: i + 1 };
    if (!f.at) rules.push({ selector: t, ancestors: stack.filter(x => x.at).map(x => x.text), body: i + 1 });
    stack.push(f); prelude = "";
  } else if (c === "}") { stack.pop(); prelude = ""; }
  else if (c === ";" && stack.length === 0) prelude = "";
  else prelude += c;
}

const jump = rules.filter(r => r.selector.includes(".chat-jump"));
const inMedia = r => r.ancestors.some(a => a.startsWith("@media"));
const gatedAny = jump.filter(inMedia);
const gatedHoverPointer = jump.filter(r =>
  r.ancestors.some(a => /@media[^{]*\b(hover|any-hover|pointer|any-pointer)\s*:/.test(a)));
const gatedWidth = jump.filter(r =>
  r.ancestors.some(a => /@media[^{]*\b(min-width|max-width)\s*:/.test(a)));

// Anti-vacuity: the scan must find hover/pointer queries SOMEWHERE, or a
// zero count means the regex is broken rather than the component is clean.
const allHoverPointerRules = rules.filter(r =>
  r.ancestors.some(a => /@media[^{]*\b(hover|any-hover|pointer|any-pointer)\s*:/.test(a)));

const out = {
  served_url: url,
  bytes: src.length,
  total_rules: rules.length,
  chat_jump_rules: jump.length,
  chat_jump_rules_inside_any_media: gatedAny.length,
  chat_jump_rules_inside_hover_or_pointer_media: gatedHoverPointer.length,
  chat_jump_rules_inside_width_media: gatedWidth.length,
  CONTROL_total_rules_inside_hover_or_pointer_media: allHoverPointerRules.length,
  CONTROL_sample_hover_pointer_selectors: allHoverPointerRules.slice(0, 5)
    .map(r => `${r.selector}  <<in>>  ${r.ancestors.join(" / ")}`),
  chat_jump_selectors: jump.map(r => r.selector),
};
console.log(JSON.stringify(out, null, 2));
