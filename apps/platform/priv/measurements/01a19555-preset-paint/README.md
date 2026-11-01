# Preset paint harness (task 01a19555-1ed2-7000-bd9a-e743874c5ac0, stage 1)

Adding a theme preset adds two variant blocks, and four design guards read
PAINTED pixels per variant. Their fixtures name a harness
(`paint_glass_01a1557a7a71.mjs`, "kept with the task evidence") that is not in
the repo. This directory is a harness that paints the same rows, so a new
preset (Sage, stage 2) is painted by an instrument that has first been held
against the committed rows.

| Fixture (test/support/fixtures/...) | Read by | Written here as |
|---|---|---|
| `painted_glass/chrome151.csv`, `chrome147.csv` | `bottom_nav_glass_guard_test.exs` | `<out>/chrome151.csv`, `chrome147.csv` |
| `painted_glass/underlay_chrome151.csv`, `underlay_chrome147.csv` | `under_glass_contrast_guard_test.exs` | `<out>/underlay_chrome151.csv`, ... |
| `painted_glass/focus_ring.csv` | `bottom_nav_glass_guard_test.exs` | `<out>/focus_ring.csv` |
| `painted_mix/chrome151_tokens.csv`, `chrome147_tokens.csv` | `agent_slot_tokens_guard_test.exs` (via `PaintedMix`) | `<out>/chrome151_tokens.csv`, ... |

`painted_mix/*_mix.csv` (ink x ground x strength) is not regenerated: its rows
are keyed by colour, not by variant, and stage 1's spec does not name it.

## Files

- `paint.mjs`: the harness. Compiles `assets/css/app.css` with the Tailwind
  standalone binary (or takes `--css`), inlines it into a page per variant,
  paints flat patches and reads each back from `Page.captureScreenshot` (PNG,
  DPR 1) at the patch centre. Transitions and animations are off, so every
  row is the settled paint of its own state.
- `cdp.mjs`: the CDP driver, mirroring `../01a0419a-desktop-verify/cdp.mjs`
  with the host as an argument (one run drives two browsers).
- `run.sh`: starts both pinned containers on a podman host, tunnels their CDP
  ports, runs `paint.mjs`, removes the containers.
- `control.sh`: the positive control, `diff` of each output against its
  fixture with `#` comment lines excepted.
- The PNG decoder is `../01a0cf85-dark-token-diff/png.mjs`.

## The two builds (pins)

| Fixture build | Image (podman, pinned by digest) | Flags |
|---|---|---|
| `chrome151` | `docker.io/chromedp/headless-shell:151.0.7922.109` = `@sha256:2d349b544a1ea6b5b5fd7c0fe99215ff662339c57407ee2e8c0a11af93516b04` | image default (`--use-gl=angle --use-angle=swiftshader`) |
| `chrome147` | `docker.io/chromedp/headless-shell:147.0.7727.15` = `@sha256:69e8a5a1fb39e8029683fb33f41a4a470e1ac183fe431a6a40631b977f6d62f3` | `--disable-gpu` |

Both containers run with `--shm-size=1g`, and `paint.mjs` captures one cell
at a time. At podman's default 64 MB `/dev/shm` a single 900x4500 under-glass
capture crashed the GPU process
(`VALIDATION_ERROR_DESERIALIZATION_FAILED ... viz.mojom.CopyOutputResultSender`),
and at 1 GB the same capture still timed out on Chrome 151. Per-cell clips
paint the same bytes as whole-viewport captures (checked on every row of
all seven outputs, both builds).

**What separates the two glass fixtures is the raster path, not the Chrome
version.** Measured on Burrow light: the 147 image at its default (GPU via
SwiftShader) paints the `chrome151.csv` bytes (10 rows, alphas
0.50/0.51/0.75/0.96/1.00), and the 151 image with `--disable-gpu` paints the
`chrome147.csv` bytes (3 rows compared: black 0.50, white 0.75, black 0.96).
On the under-glass sweep the two images with `--disable-gpu` paint identical
bytes (Burrow dark, 315 rows). So
`chrome147` is painted with `--disable-gpu`; with the default flags the two
builds would agree and the guards' "minimum over both builds" would cover one
raster path, not two. The `chrome147` fixtures' user agent reads
`HeadlessChrome/147.0.7727.15`; the chromedp image reports `Chrome/147...`
(Chrome for Testing's `chrome-headless-shell` 147.0.7727.15 reports the
`HeadlessChrome` token, and it painted the same bytes as the chromedp image
with `--disable-gpu` on the 315 Burrow dark under-glass rows compared).

## Running it

```bash
cd apps/platform/priv/measurements/01a19555-preset-paint
# Tailwind: the binary mix tailwind.install puts in _build, or TAILWIND=<path>.
# Heroicons: BURROW_HEROICONS_DIR=<deps>/heroicons/optimized if this checkout has no deps/
PODMAN_HOST=<user>@<podman host> ./run.sh <out dir> all          # the ten committed variants
PODMAN_HOST=<user>@<podman host> ./run.sh <out dir> sage:light sage:dark
./control.sh <out dir>                                       # the positive control
GLASS_MIX=oklab PAINT_FLAGS="--only glass" ./run.sh <out dir> all   # the named mutation
```

The compile reproduces the CSS a fixture was painted from exactly: compiled at
`9db54b47` (the commit `underlay_*.csv` names) it hashes to
`12b9218e547552ebee7b9a734e2a789ccb4a10be241f75c9a9b7c68019e4030d`, the sha in
that header, and at `6b14b58c8` (task 01a1557a-7a71 stage 5) to
`1fc428155d15b61bd49851caa3c90399ecb16edbd7a13c4fb1763b4fc22134c9`, the sha in
`focus_ring.csv`'s header. None of the task 01a1557a-7a71 stage-1 commits in
the local object store compiles to the glass sweep's `4c6b27c3...`.

## Positive control against the ORIGINAL fixtures: failed (2026-11-01, base 8194f3c1)

This section records the run against the fixtures as committed before this
stage. The decision that followed is under "Regenerated fixtures" below.

Commands (the podman host, both pins above; two full runs, byte-identical to each other):

```bash
PODMAN_HOST=<user>@<podman host> ./run.sh <out> all     # compiled app.css sha256 cf19c320...dc473
./control.sh <out>                                  # exit 1
PODMAN_HOST=<user>@<podman host> PAINT_FLAGS="--css <app.css compiled at 9db54b47> --only underlay" ./run.sh <out9db5> all
./control.sh <out9db5>
```

`control.sh` output, summarised (data lines only, `#` lines excepted):

| Fixture | Rows | Rows that differ (current app.css) | What differs |
|---|---|---|---|
| `painted_mix/chrome151_tokens.csv` | 400 | **0** | |
| `painted_mix/chrome147_tokens.csv` | 400 | **0** | |
| `painted_glass/focus_ring.csv` | 40 | **0** | |
| `painted_glass/chrome147.csv` | 1020 | 18 | (a) |
| `painted_glass/chrome151.csv` | 1020 | 21 | (a), (b) |
| `painted_glass/underlay_chrome151.csv` | 3150 | 3150; **0** at the fixture's own CSS | (c) |
| `painted_glass/underlay_chrome147.csv` | 3150 | 3150; 621 at the fixture's own CSS | (c), (d) |

(a) **The fixture's alpha-0.50 row of every variant after the first is a
frame of a colour transition, not a settled paint.** 9 variants x 2 backdrops
per build. In those rows only the `inactive_*` and `active_*` columns differ,
and they sit between the previous variant's ink and this variant's own (for
example Burrow dark active `#ed731e` where every other alpha paints
`#f47721`, after Burrow light's `#ad4b07`). `.bottom-nav-tab` declares
`transition: color 120ms ease-out`, and the fixture harness changed theme
attributes on a live page. The harness here switches transitions off. With
them on, two runs of the same switch-then-capture sequence painted `#e26c1a`
and `#d76516`: that row has no single true value to reproduce. The guards
never read alpha 0.50 (every declared alpha is 0.86 or higher, and the floor
test steps down by 0.01).

(b) **Three Chrome 151 rows in Burrow midnight light are one byte off, and the
cause is not found.** Diff, verbatim:

```
247c247
< burrow-midnight light,white,0.70,#f4f6fb,#6e6f75,#6e6f75,#b4470a,#b4470a,#b4470a,#6e6f75,#ffffff,#000000
---
> burrow-midnight light,white,0.70,#f3f5fa,#6d6e74,#6d6e74,#b4470a,#b4470a,#b4470a,#6d6e74,#ffffff,#000000
256,257c256,257
< burrow-midnight light,black,0.75,#b2b6ba,#505257,#505257,#b4470a,#b4470a,#b4470a,#505257,#ffffff,#000000
< burrow-midnight light,white,0.75,#f2f6fa,#6d6f74,#6d6f74,#b4470a,#b4470a,#b4470a,#6d6f74,#ffffff,#000000
---
> burrow-midnight light,black,0.75,#b3b6ba,#515257,#515257,#b4470a,#b4470a,#b4470a,#515257,#ffffff,#000000
> burrow-midnight light,white,0.75,#f3f6fa,#6e6f74,#6e6f74,#b4470a,#b4470a,#b4470a,#6e6f74,#ffffff,#000000
```

This harness paints the same bytes on every run (six runs). It does not move with the CSS
(compiled at `6d7a8412a`, the fixtures' merge), with the alpha's float
spelling (`0.7000000000000002`, `0.7000000000000001`), or with the page
geometry (viewports 390x844, 400x240, 375x812, a full-page panel). The
chrome147 fixture agrees with this harness on all three rows. None of the three is a
declared alpha (Burrow midnight light declares 0.98).

(c) **`send` changed in app.css after the under-glass sweep was painted.** The
fixture holds `#00c7de` (rung 10's cyan) in every row, and the current
`.compose-pill-send` paints each variant's primary. It is the only column
that differs on chrome151. Compiled at `9db54b47`, the commit the header
names, the CSS hashes to the header's `12b9218e...` and chrome151 reproduces
all 3150 rows **byte-identically**. The guard reads `send` only in an
advisory `IO.puts`.

(d) **The Chrome 147 under-glass rows are not reproduced by any raster path
tried.** At the fixture's own CSS, 621 rows (1432 cells) differ, each by
exactly one 8-bit step in one channel. Black and white underlays never
differ, only the coloured ones (`ag_*`, `primary`, `base_100`,
`base_content`). That points at the `saturate(1.4)` backdrop filter, a no-op
on black and white. Tried: chromedp 147 x86-64 with `--disable-gpu` (the pin
above, 621 rows) and at its default GPU path (worse); Chrome for Testing
`chrome-headless-shell` 147.0.7727.15 x86-64, whose user agent matches the
fixture's `HeadlessChrome/147.0.7727.15` (bytes identical to the pin);
chromedp 147 arm64 software and GPU (both worse); three page layouts (no
change). The glass-sweep `chrome147.csv`, painted on a different box, matches
this pin on every settled row.

## Regenerated fixtures (the decision, 2026-11-01)

The coordinator chose option 1: this harness is the instrument, and the
committed fixtures were not a ground truth worth matching. (a) never had a
single value, (c) is stale against the current CSS, and the build names
denote raster paths rather than versions. (b) and (d) stay unexplained, are
bounded at one 8-bit step, and are recorded above. All seven fixtures were
repainted from the branch's compiled app.css (sha256
`cf19c32079c0782dcb96e9356d2bec3acb4caa412a9a4978a58f50b9872dc473`), and their
headers name the image digest, the flags and this harness. Every `# paint-input:`
line is unchanged. The data rows are exactly `paint.mjs` output; none was
edited by hand.

Determinism: two independent full runs (`run.sh <out> all`, containers
started fresh each time) give byte-identical output. Diffed against the
regenerated fixtures, both report 0 differing lines in all seven files,
alpha-0.50 rows included:

```
== painted_glass/chrome151.csv: 1021 lines, 0 differing lines
== painted_glass/chrome147.csv: 1021 lines, 0 differing lines
== painted_glass/underlay_chrome151.csv: 3151 lines, 0 differing lines
== painted_glass/underlay_chrome147.csv: 3151 lines, 0 differing lines
== painted_glass/focus_ring.csv: 41 lines, 0 differing lines
== painted_mix/chrome151_tokens.csv: 400 lines, 0 differing lines
== painted_mix/chrome147_tokens.csv: 400 lines, 0 differing lines
```

The original `chrome147` user agent, `HeadlessChrome/147.0.7727.15`, is the
token Chrome for Testing's `chrome-headless-shell` reports. The chromedp image
pinned here reports `Chrome/147.0.7727.15`, so the regenerated `chrome147`
headers carry that. The guards only require `Chrome/147.`.

## The named mutation

`GLASS_MIX=oklab` rewrites the five compiled glass declarations from
`color-mix(in srgb, ...)` to `color-mix(in oklab, ...)`. Against the `srgb`
run, 32 rows of `chrome151.csv` and 6 of `chrome147.csv` change, so the diff
against the fixture is non-empty beyond (a) and (b). Example:
`burrow dark,black,0.75` glass `#0d0e0f` becomes `#0d0d0f`. Against the regenerated
fixtures, `control.sh` reports 64 differing lines in `chrome151.csv` and 12 in
`chrome147.csv` (exit 1). A mix with
`transparent` differs between the two spaces only in rounding, so the
mutation moves few rows. Revert is the default: the variable unset.

## Stage 2: Sage appended (task 01a19555 stage 2)

`run.sh <out> all sage:light sage:dark` repainted all twelve variants from
the CSS with Sage's blocks (sha256 `06bbed03…0a9d`). Two runs were
byte-identical. Every earlier row was unchanged (`control.sh` against the
fixtures, Sage rows excepted: 0 differing lines in all seven), so the Sage
rows were appended verbatim. `git diff -U0` on the fixtures shows no removed
line. One Chrome 147 software capture timed out under load during the first
run, so `read()` now retakes a timed-out capture, at most twice.
