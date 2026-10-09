defmodule Platform.Design.DarkTokenPaintedFixture do
  @moduledoc """
  The bytes a browser PAINTED for every dark-theme token, live Suite and the
  meetings mock side by side (task 01a0cf85, stage 1). Read by
  `Platform.Design.DarkTokenDiffTest`.

  Measured, never derived. Each hex here was read back from a screenshot of a
  swatch painted from `var(--token)` by
  `priv/measurements/01a0cf85-dark-token-diff/probe.mjs`; the full run is
  `results.json` in the same directory. Nothing was copied from a declaration,
  a `getComputedStyle` string or an `app.css` comment. The instrument's own
  controls (white, black, a planted colour, and five negative controls that
  must come back unresolved) ran on each page before any token was read.

  ## Two ratio conventions, labelled on every row

    * `painted`: hex-to-hex over the painted bytes,
      `WcagContrast.contrast_painted/2`. What a viewer's screen shows.
    * `token_space`: float-through from the declaration,
      `WcagContrast.contrast/2` (and `composite/3` for the translucent rows).

  They agree when both operands are hex literals and split when an operand is
  `oklch()` or a translucent composite. Example on this palette: `primary` on
  `base-200` is 11.5672 painted and 11.5762 token-space, and the second figure
  is the one `app.css`'s focus-ring comment quotes.

  ## The ground decision is recorded here, not reopened

  The dark block records a DECISION (2026-09-06, task 01a07435): the ground
  stays `#000306` and the mock's `#0C1016` was rejected on panel separation,
  1.2011:1 against 1.1077:1. The painted readings below reproduce both figures
  exactly (`base-100` vs `base-200`, live and mock). This fixture measures the
  difference; it does not propose the mock's ground.

  ## Staleness, and the Burrow supersession

  Every live row carries the dark-block DECLARATION it was read from. If a
  later change edits any of those declarations, the diff test fails with
  "re-measure" instead of leaving a stale table behind.

  The Burrow recolor (task 01a120c5 stage 1) replaced every live dark token
  this table compares. The table, and the signed decision document built on
  it, compare the PRE-Burrow palette with the meetings mock; re-deciding
  their recommendations is not a re-measure, so they are kept as a dated
  record and marked superseded (`superseded_by/0`). The live side WAS
  re-measured with the same probe: `results-burrow-01a120c5.json` in the
  measurements directory, and the staleness guard now holds the CURRENT dark
  block to that run instead.
  """

  @doc "Where and how the bytes below were taken."
  def provenance do
    %{
      task: "01a0cf85-5bee-7001-844f-bcf4761591ae",
      measured_on: "2026-09-28",
      commit:
        "81c5a1e6be6592cab4e059f09cc0e7a15bf2c722 (app.css byte-identical to origin/main d8d6814f)",
      browser: "Chrome/154.0.8037.58, headless, --force-color-profile=srgb",
      viewport: "800x900 @1x",
      instrument: "priv/measurements/01a0cf85-dark-token-diff/probe.mjs",
      runs:
        "six full runs (four in stage 1, two in stage 2 after the -content tokens were added); " <>
          "every reading common to them is byte-identical",
      superseded_by: "01a120c5-9c98-7001-af58-38f6a2c596a6"
    }
  end

  @doc """
  The task whose palette change made this table a historical record, or nil
  while it still describes what ships. Read from `provenance/0`.
  """
  def superseded_by, do: Map.get(provenance(), :superseded_by)

  @doc "The live-side re-measure taken for the superseding palette."
  def burrow_remeasure_path,
    do: "priv/measurements/01a0cf85-dark-token-diff/results-burrow-01a120c5.json"

  @doc "The planted known colour. It appears nowhere in either palette."
  def planted, do: "#7B3F1D"

  @doc """
  The instrument's self-checks, per page. Positive controls are the hex read
  back; negative controls are `:unresolved`, which is what the instrument
  reported instead of a hex.
  """
  def controls do
    page = %{
      white: "#FFFFFF",
      black: "#000000",
      planted: "#7B3F1D",
      undefined_var: :unresolved,
      invalid_colour: :unresolved,
      offscreen: :unresolved,
      unpainted: :unresolved,
      undefined_var_over_ground: :unresolved,
      canvas_white: "#FFFFFF",
      canvas_black: "#000000",
      canvas_planted: "#7B3F1D",
      canvas_invalid_colour: :unresolved,
      # The trap the canvas guard exists for: planted, then an invalid
      # string, read with no guard. It reads the PREVIOUS colour.
      canvas_unguarded_trap: "#7B3F1D"
    }

    %{live: page, mock: page}
  end

  @doc "The twelve rows the table must carry, in display order."
  def rows,
    do:
      ~w(base-100 base-200 base-300 edge base-content muted faint primary info success warning error)

  @doc """
  Live Suite, dark theme, `data-theme="dark"` on a real app page.

  `muted` and `faint` have no token. They are the most-used
  `text-base-content/NN` utility in `lib/` (60%, 384 uses) and the most-used
  at or below 40% (40%, 186 uses), counted by the probe. Their bytes are the
  COMPOSITE over each ground they sit on.
  """
  def live do
    %{
      "base-100" => %{painted: "#171B25", declaration: "--color-base-100: #171b25;"},
      "base-200" => %{painted: "#000306", declaration: "--color-base-200: oklch(9% 0.018 240);"},
      "base-300" => %{painted: "#091821", declaration: "--color-base-300: oklch(20% 0.028 240);"},
      "edge" => %{painted: "#232A38", declaration: "--edge: #232A38;"},
      "base-content" => %{
        painted: "#EEEEEE",
        declaration: "--color-base-content: oklch(95% 0 0);"
      },
      "muted" => %{
        recipe: "text-base-content/60",
        uses_in_lib: 384,
        alpha: 0.6,
        declaration: "--color-base-content: oklch(95% 0 0);",
        over: %{"base-100" => "#989A9E", "base-200" => "#8F9091"}
      },
      "faint" => %{
        recipe: "text-base-content/40",
        uses_in_lib: 186,
        alpha: 0.4,
        declaration: "--color-base-content: oklch(95% 0 0);",
        over: %{"base-100" => "#6D7076", "base-200" => "#5F6163"}
      },
      "primary" => %{painted: "#06D5ED", declaration: "--color-primary: #06D5ED;"},
      "info" => %{painted: "#6FA7EE", declaration: "--color-info: oklch(72% 0.12 255);"},
      "success" => %{painted: "#15BA81", declaration: "--color-success: oklch(70% 0.15 162);"},
      "warning" => %{painted: "#F49A00", declaration: "--color-warning: oklch(76% 0.17 70);"},
      "error" => %{painted: "#F1383E", declaration: "--color-error: oklch(63% 0.22 25);"},
      # The text daisyUI puts on each fill. Not rows of the table; read so each
      # fill can be measured against its own content colour.
      "primary-content" => %{
        painted: "#000000",
        declaration: "--color-primary-content: oklch(0% 0 0);"
      },
      "info-content" => %{painted: "#000000", declaration: "--color-info-content: oklch(0% 0 0);"},
      "success-content" => %{
        painted: "#FFFFFF",
        declaration: "--color-success-content: oklch(100% 0 0);"
      },
      "warning-content" => %{
        painted: "#000000",
        declaration: "--color-warning-content: oklch(0% 0 0);"
      },
      "error-content" => %{
        painted: "#FFFFFF",
        declaration: "--color-error-content: oklch(100% 0 0);"
      }
    }
  end

  @doc """
  The mock (`:root` of the meetings desktop prototype; not in this repo).

  The mock has no edge token (every border is `var(--base-300)`, which is also
  a fill) and no warning token (`var(--warning)` came back unresolved; the
  mock paints the literal fallback in `var(--warning,#f59e0b)`).
  """
  def mock do
    %{
      "base-100" => %{painted: "#171B25", declaration: "--base-100: #171b25;"},
      "base-200" => %{painted: "#0C1016", declaration: "--base-200: #0c1016;"},
      "base-300" => %{painted: "#232A38", declaration: "--base-300: #232a38;"},
      "edge" => %{painted: "#232A38", declaration: "--base-300: #232a38;"},
      "base-content" => %{painted: "#F2F3F5", declaration: "--content: #f2f3f5;"},
      "muted" => %{
        alpha: 0.55,
        content: "#F2F3F5",
        declaration: "--muted: rgba(242,243,245,.55);",
        over: %{"base-100" => "#8F9297", "card" => "#8D8F94"}
      },
      "faint" => %{
        alpha: 0.32,
        content: "#F2F3F5",
        declaration: "--faint: rgba(242,243,245,.32);",
        over: %{"base-100" => "#5D6068", "card" => "#5A5D64"}
      },
      "primary" => %{painted: "#22C9E0", declaration: "--primary: #22c9e0;"},
      "info" => %{painted: "#7AA2F7", declaration: "--info: #7aa2f7;"},
      "success" => %{painted: "#10B981", declaration: "--success: #10b981;"},
      "warning" => %{
        painted: :unresolved,
        declaration: nil,
        fallback: %{recipe: "var(--warning,#f59e0b)", painted: "#F59E0B"}
      },
      "error" => %{painted: "#EF4444", declaration: "--error: #ef4444;"},
      # No -content tokens in the mock. The one text-on-info pairing it ships
      # is the held Ask button, a literal: .ask.held { color: #0b1220 }.
      "info-content" => %{painted: "#0B1220", literal: "#0b1220"}
    }
  end

  @doc """
  The grounds, painted. Live: `base-100` (panel) and `base-200` (the page
  ground). Mock: `base-100` (panel), `base-200` (body) and the hard-coded
  `#12161f` card.
  """
  def grounds do
    %{
      live: %{"base-100" => "#171B25", "base-200" => "#000306"},
      mock: %{"base-100" => "#171B25", "base-200" => "#0C1016", "card" => "#12161F"}
    }
  end

  @doc """
  `{side, fg, bg, painted, token_space}`. Side `:cross` is a hypothetical
  pairing of two measured values (`"mock:info"` on `"live:base-200"`): what a
  mock value would read on a live ground if adopted. Painted only, because the
  bytes were never declared together; token-space is `nil`.

  For the other sides, `fg` is a row key, `"row@ground"`
  for a translucent row's composite, or `"warning-fallback"`. Painted is
  hex-to-hex over the bytes above; token-space is float-through from the
  declaration. Both rounded to 4 dp.
  """
  def ratios do
    [
      {:live, "base-content", "base-100", 14.8369, 14.8760},
      {:live, "base-content", "base-200", 17.8209, 17.8816},
      {:live, "primary", "base-100", 9.6304, 9.6304},
      {:live, "primary", "base-200", 11.5672, 11.5762},
      {:live, "info", "base-100", 6.9168, 6.9412},
      {:live, "info", "base-200", 8.3079, 8.3436},
      {:live, "success", "base-100", 6.8631, 6.8919},
      {:live, "success", "base-200", 8.2434, 8.2844},
      {:live, "warning", "base-100", 7.7619, 7.7732},
      {:live, "warning", "base-200", 9.3229, 9.3437},
      {:live, "error", "base-100", 4.4063, 4.4198},
      {:live, "error", "base-200", 5.2925, 5.3128},
      {:live, "muted@base-100", "base-100", 6.1078, 6.0972},
      {:live, "muted@base-200", "base-200", 6.4649, 6.4779},
      {:live, "faint@base-100", "base-100", 3.4670, 3.4490},
      {:live, "faint@base-200", "base-200", 3.3246, 3.3305},
      {:live, "base-100", "base-200", 1.2011, 1.2020},
      {:live, "edge", "base-100", 1.1966, 1.1966},
      {:live, "base-300", "base-100", 1.0478, 1.0493},
      {:live, "base-300", "base-200", 1.1463, 1.1456},
      {:mock, "base-content", "base-100", 15.5045, 15.5045},
      {:mock, "base-content", "card", 16.3016, 16.3016},
      {:mock, "primary", "base-100", 8.6063, 8.6063},
      {:mock, "primary", "card", 9.0488, 9.0488},
      {:mock, "info", "base-100", 6.8355, 6.8355},
      {:mock, "info", "card", 7.1869, 7.1869},
      {:mock, "success", "base-100", 6.7862, 6.7862},
      {:mock, "success", "card", 7.1351, 7.1351},
      {:mock, "warning-fallback", "base-100", 8.0153, 8.0153},
      {:mock, "warning-fallback", "card", 8.4274, 8.4274},
      {:mock, "error", "base-100", 4.5745, 4.5745},
      {:mock, "error", "card", 4.8096, 4.8096},
      {:mock, "muted@base-100", "base-100", 5.5138, 5.5124},
      {:mock, "muted@card", "card", 5.5928, 5.6282},
      {:mock, "faint@base-100", "base-100", 2.7366, 2.7395},
      {:mock, "faint@card", "card", 2.7446, 2.7317},
      {:mock, "base-100", "base-200", 1.1077, 1.1077},
      {:mock, "edge", "base-100", 1.1966, 1.1966},
      {:mock, "base-300", "base-100", 1.1966, 1.1966},
      {:mock, "base-300", "base-200", 1.3254, 1.3254},
      # stage 2: content on base-300 (active pill), primary as a focus ring on
      # base-300, each fill against its own content colour, and the mock body
      # ground as a text ground.
      {:live, "base-content", "base-300", 15.5466, 15.6090},
      {:live, "primary", "base-300", 10.0911, 10.1049},
      {:live, "primary-content", "primary", 11.7483, 11.7483},
      {:live, "info-content", "info", 8.4380, 8.4677},
      {:live, "success-content", "success", 2.5082, 2.4978},
      {:live, "warning-content", "warning", 9.4689, 9.4826},
      {:live, "error-content", "error", 3.9067, 3.8948},
      {:mock, "base-content", "base-200", 17.1739, 17.1739},
      {:mock, "primary", "base-200", 9.5330, 9.5330},
      {:mock, "info", "base-200", 7.5715, 7.5715},
      {:mock, "success", "base-200", 7.5169, 7.5169},
      {:mock, "warning-fallback", "base-200", 8.8784, 8.8784},
      {:mock, "error", "base-200", 5.0670, 5.0670},
      {:mock, "base-content", "base-300", 12.9571, 12.9571},
      {:mock, "primary", "base-300", 7.1923, 7.1923},
      {:mock, "info-content", "info", 7.4346, 7.4346},
      {:cross, "mock:info", "live:base-200", 8.2102, nil},
      {:cross, "mock:primary", "live:base-200", 10.3372, nil},
      {:cross, "mock:primary", "live:base-300", 9.0180, nil},
      {:cross, "mock:base-content", "live:base-200", 18.6227, nil},
      {:cross, "mock:base-content", "live:base-300", 16.2461, nil},
      {:cross, "mock:error", "live:base-200", 5.4945, nil},
      {:cross, "mock:success", "live:base-200", 8.1510, nil},
      {:cross, "live:error-content", "mock:error", 3.7631, nil},
      {:cross, "live:primary-content", "live:error", 5.3754, nil},
      {:cross, "live:primary-content", "mock:error", 5.5805, nil},
      {:cross, "live:primary-content", "live:success", 8.3724, nil},
      {:cross, "live:base-300", "mock:base-200", 1.0571, nil},
      {:cross, "mock:base-300", "live:base-200", 1.4373, nil},
      {:cross, "live:edge", "mock:base-300", 1.0000, nil},
      {:cross, "live:success-content", "live:base-100", 17.2143, nil}
    ]
  end

  @doc "The painted bytes of a ratio operand key on one side."
  def painted_hex(:cross, key) do
    [side, row] = String.split(key, ":", parts: 2)
    painted_hex(String.to_existing_atom(side), row)
  end

  def painted_hex(side, key) do
    table = if side == :live, do: live(), else: mock()

    case String.split(key, "@") do
      [row, ground] ->
        get_in(table, [row, :over, ground])

      ["warning-fallback"] ->
        get_in(table, ["warning", :fallback, :painted])

      [row] ->
        case Map.get(table, row) do
          %{painted: hex} when is_binary(hex) -> hex
          _ -> Map.fetch!(grounds()[side], row)
        end
    end
  end
end
