# Dark token diff: live vs mock, by painted pixel (task 01a0cf85, stage 1)

Every dark-theme token, live Suite and the meetings mock side by side, read
back as the bytes a browser painted. No token value in `app.css` changes in
this task; this directory is the instrument and its record.

- `probe.mjs`: the instrument. Paints one swatch per token from `var(--token)`,
  screenshots, reads each swatch back as bytes.
- `cdp.mjs`, `png.mjs`: a minimal CDP driver and a PNG decoder (no deps).
- `results.json`: the run the fixture was pasted from.
- `results-burrow-01a120c5.json`: the live-side re-measure after the Burrow
  recolor (task 01a120c5). The fixture is kept as the pre-Burrow record and
  marked superseded; the staleness guard holds the current dark block to
  this run.
- The pasted copy the tests read is
  `test/support/dark_token_painted_fixture.ex`, guarded by
  `test/platform/design/dark_token_diff_test.exs`.

## Running it

```bash
# 1. a dev server on the branch under test (scratch DB, seeded)
cd apps/platform
export PLATFORM_DEV_DATABASE=platform_dev_<task>
mix ecto.create && mix ecto.migrate
mix run priv/repo/seeds/dev_federation_seed.exs
mix assets.build
PORT=<port> mix phx.server

# 2. your own headless Chrome. The colour-profile flag is not optional:
#    without it the screenshot bytes are colour-managed to the display.
"<chrome binary>" --headless=new --remote-debugging-port=<cdp-port> \
  --force-color-profile=srgb --user-data-dir=<scratch dir> --hide-scrollbars

# 3. the probe. MOCK_HTML is the mock saved OUTSIDE the repo; the probe
#    refuses a path inside it. The mock is never committed.
cd apps/platform/priv/measurements/01a0cf85-dark-token-diff
CDP_PORT=<cdp-port> LIVE_URL=http://127.0.0.1:<port> LIVE_USER=<throwaway> \
  MOCK_HTML=/absolute/path/outside/repo/Meeting_Desktop.html node probe.mjs
```

The probe opens its own `Target.createBrowserContext`, logs in through
`/dev/login?as=<throwaway>`, checks it landed on `/chat`, forces
`data-theme="dark"` on `<html>`, and then paints. The mock is loaded as a
`file://` URL. Exit status is non-zero if any control misses.

After a re-run, paste the new bytes into the fixture and run
`mix test test/platform/design/dark_token_diff_test.exs`.

## How a reading is taken

Each swatch is a fresh 16x16 element inside a fixed, isolated overlay, so no
page content, opacity or filter sits between the paint and the screenshot.
The reader takes the swatch's 8x8 interior and requires every pixel to be the
same byte triple.

- **Opaque tokens** are painted twice, over a `#FF00FF` and a `#00FF00`
  underlay. A painted opaque colour cannot depend on what is under it, so the
  two readings must agree. If they differ, the token is reported
  **unresolved**, never as a hex.
- **Translucent tokens** (mock `--muted`, `--faint`; live
  `text-base-content/60` and `/40`) are painted over each real ground they sit
  on and the COMPOSITED bytes are recorded. A reading identical to its bare
  ground is reported unresolved. They are also painted over black and white
  to report the alpha actually painted (0.6 / 0.4 live; 0.549 / 0.322 mock).
- The live muted text has no token. It is the Tailwind utility itself on the
  swatch, painted with `background-color: currentColor`, so the browser
  resolves the class the way it does on a real element. The recipe is the
  most-used `text-base-content/NN` in `lib/` (the probe counts them and writes
  the counts to `results.json`).

Stage 2 added the live `-content` tokens (the text colour daisyUI puts on
each fill) and the mock's one text-on-info literal (`#0b1220`, the held Ask
button), so each fill can be measured against its own text. The decision
document built on these readings is `docs/design-system/06-dark-token-diff.md`. The drift guard in `dark_token_diff_test.exs` checks that document against the fixture; it does not cover the sign-off canvas, which is a hand-made copy.

Nothing is ever recorded from a CSS declaration, a `getComputedStyle` string or
an `app.css` comment. The probe reads the dark block only to record WHICH
declaration each live reading came from, which is what the staleness test
compares against.

## Instrument controls (run on each page before any token)

| control | must be |
|---|---|
| `#FFFFFF`, `#000000` swatches (DOM and canvas) | read back exactly |
| planted `#7B3F1D` (in neither palette; `git grep -i 7b3f1d` is empty) | read back exactly |
| `var(--nope)` | unresolved |
| `not-a-colour` in a fresh style attribute | unresolved |
| swatch at `left:-4000px` | unresolved (outside the capture) |
| swatch with `visibility:hidden` | unresolved |
| `var(--nope)` composited over a ground | unresolved (reads identical to the ground) |
| canvas: `not-a-colour` after two different sentinel fillStyles | unresolved |
| canvas trap: planted, then `not-a-colour`, no guard | reads the planted colour (proves the guard is needed) |

A canvas keeps its previous `fillStyle` when an assignment is invalid, so a
naive 1x1 canvas probe reports the previous colour for any bad value. The
canvas leg fills every value twice after resetting to two different sentinels;
if the readbacks follow the sentinel, the assignment did not take.

## Ratio conventions

Every ratio is labelled:

- **painted**: hex-to-hex over the painted bytes, `WcagContrast.contrast_painted/2`.
- **token-space**: float-through from the declaration, `WcagContrast.contrast/2`
  (and `composite/3` for translucent rows).

They agree when both operands are hex literals and split when an operand is
`oklch()` or a translucent composite: `primary` on `base-200` is 11.5672
painted and 11.5762 token-space.

## The ground decision

The dark block records a decision (2026-09-06, task 01a07435): the ground stays
`#000306`; the mock's `#0C1016` was rejected on panel separation, 1.2011:1
against 1.1077:1. This run reproduces both figures exactly from painted bytes.
The diff measures the difference; it does not reopen that decision.
