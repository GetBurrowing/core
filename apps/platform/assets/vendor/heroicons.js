const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function({matchComponents, theme}) {
  // TWO ROOTS: the vendored Heroicons set first, then our own `assets/icons`,
  // so a same-named local file overwrites the vendored entry.
  //
  // Added by FE-19 (01a07486-7985-7001-87ce-277681791f52). Heroicons ships no
  // `microphone-slash.svg` at any size, so `hero-microphone-slash` generated
  // no CSS at all and every mute indicator in meetings painted an empty
  // centre. The obvious place to drop the missing file, straight into
  // `deps/heroicons/optimized`, is not a fix: `apps/platform/.gitignore`
  // excludes `/deps/`, so nothing under it is tracked. A file there does not
  // survive `git clone`, `mix deps.get`, `mix deps.update heroicons`,
  // `mix deps.clean`, or a cached Docker layer, and it fails silently: green
  // locally, blank in the container, with nothing in the diff to explain it.
  //
  // `assets/icons/` rather than `assets/vendor/icons/` because
  // `assets/vendor/` and `assets/THIRD_PARTY_NOTICES.md` are for third-party
  // code and this glyph is ours.
  //
  // EXIT CONDITION: if upstream Heroicons ever ships `microphone-slash.svg`,
  // delete `assets/icons/24/outline/microphone-slash.svg` and let the
  // vendored file win again, rather than carrying the fork indefinitely.
  //
  // BURROW_HEROICONS_DIR (ADR 0055 stage 4; "" counts as unset): a with-modules release host builds
  // this stylesheet with core as a path dependency, so the Heroicons dep sits
  // in the HOST's `deps/`, not in apps/platform/deps. The host's Tailwind
  // profile (apps/burrow_release/config/config.exs) passes its own path here.
  // Unset, the root is core's own deps, exactly as before. Without it the
  // with-Play image shipped no `hero-*` class from the vendored set at all,
  // silently: `existsSync` below skips a missing root.
  let roots = [
    process.env.BURROW_HEROICONS_DIR ||
      path.join(__dirname, "../../deps/heroicons/optimized"),
    path.join(__dirname, "../icons")
  ]
  let values = {}
  let icons = [
    ["", "/24/outline"],
    ["-solid", "/24/solid"],
    ["-mini", "/20/solid"],
    ["-micro", "/16/solid"]
  ]
  roots.forEach(iconsDir => {
    icons.forEach(([suffix, dir]) => {
      let subdir = path.join(iconsDir, dir)
      // Only `24/outline` exists under the local root, and `readdirSync`
      // throws on a missing directory. The cost of this guard: a wholly
      // absent root now yields no icons instead of raising, which swaps a
      // loud failure for a quiet one. What closes that gap is
      // `test/platform_web/hero_icon_resolution_guard_test.exs`, which
      // asserts every `hero-*` class used in `lib` resolves against these
      // same two roots. It mirrors the roots and the suffix map below; if
      // either changes here, change it there in the same commit.
      if (!fs.existsSync(subdir)) { return }
      fs.readdirSync(subdir).forEach(file => {
        let name = path.basename(file, ".svg") + suffix
        values[name] = {name, fullPath: path.join(subdir, file)}
      })
    })
  })
  matchComponents({
    "hero": ({name, fullPath}) => {
      let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
      content = encodeURIComponent(content)
      let size = theme("spacing.6")
      if (name.endsWith("-mini")) {
        size = theme("spacing.5")
      } else if (name.endsWith("-micro")) {
        size = theme("spacing.4")
      }
      return {
        [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--hero-${name})`,
        "mask": `var(--hero-${name})`,
        "mask-repeat": "no-repeat",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "width": size,
        "height": size
      }
    }
  }, {values})
})
