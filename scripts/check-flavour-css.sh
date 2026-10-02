#!/usr/bin/env sh
# check-flavour-css.sh <without-modules app.css> <with-modules app.css>
#
# ADR 0055 stage 4 (task 01a0ee08). A with-modules image may ADD styles (its
# modules' classes); it must never LOSE one of core's. This fails when any
# selector or at-rule prelude in the without-modules stylesheet is missing from
# the with-modules one, and prints every missing entry.
#
# Why it exists: the first with-Play image built by stage 4 lacked 129 of
# core's rules, every one a `hero-*` icon. Core's heroicons
# Tailwind plugin read apps/platform/deps, which a release-host build does not
# have, and it skips a missing root without a word (assets/vendor/heroicons.js).
# Nothing else compares the two stylesheets.
#
# Preludes are read by splitting the CSS at `{`, `}` and `;` and keeping the
# text that precedes each `{`, so nested rules inside `@layer` / `@media` are
# each counted on their own. A selector list is then split at its top-level
# commas: the minifier groups identical rules that happen to be adjacent, and
# the order of rules differs between the two builds (the module's utilities
# sit between core's), so `.a,.b{x}` in one file can be `.a{x}` and `.b{x}` in
# the other. Commas inside parentheses (`:is(.a,.b)`) are not split. Works on
# minified or expanded output.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <without-modules app.css> <with-modules app.css>" >&2
  exit 2
fi

preludes() {
  sed -e 's/{/{\n/g' -e 's/}/\n}\n/g' -e 's/;/;\n/g' "$1" |
    sed -n 's/^[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*{$/\1/p' |
    awk '
      /^@/ { print; next }
      {
        depth = 0; part = ""
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c == "(") depth++
          if (c == ")") depth--
          if (c == "," && depth == 0) { print part; part = ""; continue }
          part = part c
        }
        print part
      }' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
    LC_ALL=C sort -u
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-flavour-css-$$.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

preludes "$1" > "$tmp/core"
preludes "$2" > "$tmp/with"

core_count=$(wc -l < "$tmp/core")
with_count=$(wc -l < "$tmp/with")

# A stylesheet with no rules would make the subset check vacuous.
if [ "$core_count" -lt 100 ]; then
  echo "::error::$1 has only $core_count rule preludes; that is not a built app.css"
  exit 1
fi

LC_ALL=C comm -23 "$tmp/core" "$tmp/with" > "$tmp/missing"
missing=$(wc -l < "$tmp/missing")

echo "check-flavour-css: without-modules $core_count preludes, with-modules $with_count, missing $missing"
if [ "$missing" -ne 0 ]; then
  echo "::error::the with-modules app.css lacks $missing of core's rules; first 40:"
  head -n 40 "$tmp/missing"
  exit 1
fi
