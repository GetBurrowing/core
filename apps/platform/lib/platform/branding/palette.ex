defmodule Platform.Branding.Palette do
  @moduledoc """
  Admin-chosen in-app theme colours: three per mode, the rest derived
  (task 01a0dbee-f598-7001-b450-7890103f44c4 stage 1).

  An admin picks an ACTION colour (buttons, the brand fill), a SURFACE colour
  (the page ground) and optionally an ACCENT (follows action when unset), once
  for light mode and once for dark. `derive/2` turns those three into the
  semantic token map the renderer emits; `checks/2` says which pairings the
  result puts at risk. Both are pure and take no database.

  ## What is NOT derived and NOT editable

  `info`, `success`, `warning`, `error`, `neutral`, `secondary` and
  `pipeline-human` carry MEANING, not brand. An install that could repaint
  "error" to its brand green would have no error colour. They stay as
  `app.css` declares them, and `checks/2` warns when the chosen action colour
  would be mistaken for one of the four status hues.

  ## The rules derivation follows

    * `--color-primary` is fill only. Text that needs the brand colour uses
      `--color-interactive`, which is the action colour darkened (light) or
      lightened (dark) in OKLCH lightness, hue kept, until it clears 4.5:1 on
      the surface. This is the brand rule `app.css` already states: primary
      cyan is never text.
    * `--color-primary-content` / `--color-accent-content` are chosen, not
      stepped: black or white, whichever reads better on the fill.
    * `--color-base-content` is one of the two body-text colours Suite
      actually paints, `body_text/0`: today's light `--color-base-content`
      or today's dark one, whichever reads better on the surface.
    * `--focus-ring` is the theme-split slot from task 01a0833d (WCAG 2.2
      SC 1.4.11, 3:1 against every ground it is drawn on). It is the action
      colour when that clears 3:1 on base-100, base-200 AND base-300, else the
      interactive colour pushed further until it does. That mirrors why
      today's light theme rings with #087f93 and the dark theme with #06d5ed.
    * `--color-base-200` / `--color-base-300` step the surface in OKLCH
      lightness the way today's themes do: light steps darker for both; dark
      puts base-200 darker (the sidebar ground) and base-300 raised.
    * `--edge` is a VISIBLE edge: darker than the surface in light, lighter in
      dark, the directions `border_token_direction_test.exs` pins, and at least
      1.2:1 against the surface. A surface too dark (light mode) or too light
      (dark mode) to have an edge in that direction gets one in the other.

  ## A nil is "Suite default", and derivation of the defaults is not app.css

  `derive/2` resolves a nil slot to `suite_defaults/0` so it always has three
  colours to work with. It does NOT reproduce `app.css` byte for byte (today's
  interactive, base-200 and base-300 were hand-tuned, not derived). The renderer
  in stage 2 decides what a fully-nil mode means; the honest reading is "emit
  nothing and let app.css stand".

  ## Body text is Suite's own body text (decision, 2026-09-26)

  Decided by the task owner, Brosnan, at stage 5 of task
  01a0dbee-f598-7001-b450-7890103f44c4: body text is chosen from the colours
  Suite ACTUALLY uses for body text, never from an arbitrary colour no Suite
  theme paints. The stored palette picks surface, action and accent only;
  body text is derived, and it should be the brand's text colour. So the two
  candidates are today's light and dark `--color-base-content`, read from
  `app.css` and pinned there by `palette_test.exs` (`body_text/0`).

  Measured when the decision was applied: the light theme's base-content is
  `oklch(0% 0 0)`, which IS #000000, so the rule did not move any outcome.
  In particular #777777 as a light surface still passes, 4.69:1 against the
  light base-content (#eeeeee on it is 3.86:1). The stage-5 gate that
  expected #777777 to block was taken back to the orchestrator rather than
  met with an invented rule. Button labels (`--color-primary-content`) are
  unaffected: they still choose black or white.

  ## Why body text can block at all

  For ANY surface, one of pure black or pure white clears at least
  sqrt(21) = 4.58:1, so a black-or-white choice could never fail. Body text
  here chooses between the light base-content (#000000) and the dark one
  (#eeeeee, luminance 0.857), so a mid-grey surface with luminance between
  roughly 0.152 and 0.175 (#6c6c6c to #737373) has NO body text colour that
  reads, and that is a BLOCK. #707070 measures 4.24:1 and 4.27:1.
  """

  alias Platform.Branding.Contrast

  @type mode :: :light | :dark
  @type colours :: %{
          optional(:action) => String.t() | nil,
          optional(:surface) => String.t() | nil,
          optional(:accent) => String.t() | nil
        }
  @type check :: %{
          id: atom(),
          level: :pass | :warn | :block,
          ratio: float() | nil,
          message: String.t()
        }

  # Today's app.css values, lowercase. palette_test.exs parses app.css and
  # asserts these equal the declarations, so they cannot drift.
  @suite_defaults %{
    light: %{action: "#06d5ed", surface: "#ffffff", accent: "#06d5ed"},
    dark: %{action: "#06d5ed", surface: "#171b25", accent: "#06d5ed"}
  }

  @black "#000000"
  @white "#ffffff"

  # Today's --color-base-content per theme: light oklch(0% 0 0), dark
  # oklch(95% 0 0). Pinned against app.css by palette_test.exs.
  @body_text %{light: "#000000", dark: "#eeeeee"}
  @near_white @body_text.dark

  @text_floor 4.5
  @non_text_floor 3.0
  @edge_floor 1.2

  # OKLCH hues of the status tokens, as app.css declares them in BOTH themes
  # (palette_test.exs reads them back out of app.css).
  @status_hues [success: 162, warning: 70, error: 25, info: 255]
  @hue_window 25.0
  # Below this OKLCH chroma a colour reads as grey, whatever its nominal hue.
  @collision_chroma 0.06

  # OKLCH lightness steps, taken from today's themes: light 100 -> 96 -> 88;
  # dark base-100 ~22 -> base-200 9 (darker ground). base-300 raised.
  @light_steps %{base_200: -0.04, base_300: -0.12}
  @dark_steps %{base_200: -0.13, base_300: 0.05}

  @step 0.005

  @doc "Today's action/surface/accent hexes per mode, lowercase `#rrggbb`."
  @spec suite_defaults() :: %{light: colours(), dark: colours()}
  def suite_defaults, do: @suite_defaults

  @doc "The status hues `checks/2` guards, `[status: degrees]`."
  @spec status_hues() :: keyword(number())
  def status_hues, do: @status_hues

  @doc """
  The two body-text candidates: today's light and dark
  `--color-base-content` from `app.css`, as lowercase `#rrggbb`.
  """
  @spec body_text() :: %{light: String.t(), dark: String.t()}
  def body_text, do: @body_text

  @doc "The near-white body text colour, `oklch(95% 0 0)`."
  @spec near_white() :: String.t()
  def near_white, do: @near_white

  @doc """
  The derived semantic token map for one mode, keyed by the CSS custom
  property name. nil slots resolve to `suite_defaults/0`; a nil accent follows
  the action colour.
  """
  @spec derive(mode(), colours()) :: %{String.t() => String.t()}
  def derive(mode, colours) when mode in [:light, :dark] do
    %{action: action, surface: surface, accent: accent} = resolve(mode, colours)

    base_200 = step_lightness(surface, steps(mode).base_200)
    base_300 = step_lightness(surface, steps(mode).base_300)
    interactive = interactive(mode, action, surface)

    %{
      "--color-primary" => action,
      "--color-primary-content" => fill_content_on(action),
      "--color-accent" => accent,
      "--color-accent-content" => fill_content_on(accent),
      "--color-base-100" => surface,
      "--color-base-200" => base_200,
      "--color-base-300" => base_300,
      "--edge" => edge(mode, surface, base_300),
      "--color-base-content" => body_content_on(surface),
      "--color-interactive" => interactive,
      "--focus-ring" => focus_ring(mode, action, interactive, [surface, base_200, base_300])
    }
  end

  @doc """
  Which pairings this palette puts at risk, one entry per check.

    * `:block` - a text pairing under 4.5:1 that derivation could not fix. The
      server refuses to save a palette with any block.
    * `:warn` - legal but worth telling the admin: an action colour under 3:1
      against the surface, or one that reads as a status colour.
    * `:pass` - fine; the message still states the ratio.
  """
  @spec checks(mode(), colours()) :: [check()]
  def checks(mode, colours) when mode in [:light, :dark] do
    %{action: action, surface: surface, accent: accent} = resolve(mode, colours)
    tokens = derive(mode, colours)

    [
      text_check(
        :body_text,
        tokens["--color-base-content"],
        surface,
        "Body text on this surface"
      ),
      text_check(
        :button_text,
        tokens["--color-primary-content"],
        action,
        "Text on buttons in the action colour"
      ),
      text_check(
        :accent_text,
        tokens["--color-accent-content"],
        accent,
        "Text on the accent colour"
      ),
      text_check(
        :link_text,
        tokens["--color-interactive"],
        surface,
        "Link text on this surface"
      ),
      action_visibility_check(action, surface),
      focus_ring_check(tokens)
    ] ++ status_collision_checks(action)
  end

  @doc "True when `checks/2` for this mode has any `:block`."
  @spec blocked?(mode(), colours()) :: boolean()
  def blocked?(mode, colours), do: Enum.any?(checks(mode, colours), &(&1.level == :block))

  # ── checks ───────────────────────────────────────────────────────────────

  defp text_check(id, text, ground, subject) do
    r = Contrast.ratio(text, ground)

    if r >= @text_floor do
      %{id: id, level: :pass, ratio: r, message: "#{subject} is #{fmt(r)}:1."}
    else
      %{
        id: id,
        level: :block,
        ratio: r,
        message: "#{subject} is #{fmt(r)}:1. It needs #{fmt(@text_floor)}:1 to be readable."
      }
    end
  end

  defp action_visibility_check(action, surface) do
    r = Contrast.ratio(action, surface)

    if r >= @non_text_floor do
      %{
        id: :action_visibility,
        level: :pass,
        ratio: r,
        message: "The action colour is #{fmt(r)}:1 against the surface."
      }
    else
      %{
        id: :action_visibility,
        level: :warn,
        ratio: r,
        message:
          "The action colour is #{fmt(r)}:1 against the surface. Buttons will be hard to " <>
            "see as outlines; the focus ring has been adjusted separately."
      }
    end
  end

  defp focus_ring_check(tokens) do
    ring = tokens["--focus-ring"]

    r =
      ["--color-base-100", "--color-base-200", "--color-base-300"]
      |> Enum.map(&Contrast.ratio(ring, tokens[&1]))
      |> Enum.min()

    if r >= @non_text_floor do
      %{
        id: :focus_ring,
        level: :pass,
        ratio: r,
        message: "The focus ring is at least #{fmt(r)}:1 on every surface."
      }
    else
      %{
        id: :focus_ring,
        level: :warn,
        ratio: r,
        message:
          "The focus ring is only #{fmt(r)}:1 on one of the surfaces. Keyboard users " <>
            "may lose track of where they are; it needs #{fmt(@non_text_floor)}:1."
      }
    end
  end

  defp status_collision_checks(action) do
    {_l, c, h} = Contrast.to_oklch(action)

    for {status, hue} <- @status_hues,
        c >= @collision_chroma,
        Contrast.hue_distance(h, hue) <= @hue_window do
      %{
        id: :"collides_with_#{status}",
        level: :warn,
        ratio: nil,
        message:
          "The action colour reads as the #{status} colour. People may mistake buttons " <>
            "for #{status} messages."
      }
    end
  end

  # ── derivation ───────────────────────────────────────────────────────────

  defp resolve(mode, colours) do
    defaults = Map.fetch!(@suite_defaults, mode)
    action = Map.get(colours, :action) || defaults.action
    surface = Map.get(colours, :surface) || defaults.surface
    accent = Map.get(colours, :accent) || action
    %{action: action, surface: surface, accent: accent}
  end

  defp steps(:light), do: @light_steps
  defp steps(:dark), do: @dark_steps

  # Label on a fill (primary, accent): black or pure white, whichever reads
  # better. One of the two always clears sqrt(21) = 4.58:1, so this pairing
  # cannot block; the check exists so a regression here would.
  defp fill_content_on(fill), do: better_of(@black, @white, fill)

  # Body text on the surface: Suite's own light or dark base-content. Never
  # pure white; see the moduledoc for why that is the whole reason a block can
  # happen, and for the decision that fixed these two candidates.
  defp body_content_on(surface), do: better_of(@body_text.light, @body_text.dark, surface)

  defp better_of(a, b, ground),
    do: if(Contrast.ratio(a, ground) >= Contrast.ratio(b, ground), do: a, else: b)

  # A surface already at the end of the lightness range cannot step further
  # that way (a black light-mode surface has nothing darker), so it steps the
  # other way rather than collapsing three grounds onto one colour.
  defp step_lightness(hex, delta) do
    {l, c, h} = Contrast.to_oklch(hex)
    target = if l + delta < 0.0 or l + delta > 1.0, do: l - delta, else: l + delta
    Contrast.from_oklch({target, c, h})
  end

  # Light darkens, dark lightens; if that direction runs out before the floor
  # (a dark surface in light mode, say) the other direction is tried. Only if
  # both fail does the best attempt come back, and checks/2 reports it.
  defp interactive(mode, action, surface) do
    push(action, direction(mode), fn c -> Contrast.ratio(c, surface) >= @text_floor end)
  end

  defp focus_ring(mode, action, interactive, grounds) do
    clears? = fn c -> Enum.all?(grounds, &(Contrast.ratio(c, &1) >= @non_text_floor)) end

    if clears?.(action), do: action, else: push(interactive, direction(mode), clears?)
  end

  defp edge(mode, surface, base_300) do
    {start, dir, beyond?} =
      case mode do
        :light -> {base_300, :darker, &Kernel.</2}
        :dark -> {surface, :lighter, &Kernel.>/2}
      end

    visible? = fn c -> Contrast.ratio(c, surface) >= @edge_floor end

    directed? = fn c ->
      beyond?.(Contrast.luminance(c), Contrast.luminance(surface)) and visible?.(c)
    end

    case walk_from(start, dir, directed?) do
      nil -> push(surface, opposite(dir), visible?)
      found -> found
    end
  end

  defp walk_from(hex, dir, ok?), do: if(ok?.(hex), do: hex, else: walk(hex, dir, ok?))

  defp direction(:light), do: :darker
  defp direction(:dark), do: :lighter

  defp push(hex, dir, ok?) do
    cond do
      ok?.(hex) -> hex
      found = walk(hex, dir, ok?) -> found
      found = walk(hex, opposite(dir), ok?) -> found
      true -> end_of(hex, dir)
    end
  end

  defp opposite(:darker), do: :lighter
  defp opposite(:lighter), do: :darker

  defp walk(hex, dir, ok?) do
    {l, c, h} = Contrast.to_oklch(hex)
    delta = if dir == :darker, do: -@step, else: @step

    Stream.iterate(l + delta, &(&1 + delta))
    |> Stream.take_while(&(&1 >= -@step and &1 <= 1.0 + @step))
    |> Stream.map(&Contrast.from_oklch({&1, c, h}))
    |> Enum.find(ok?)
  end

  defp end_of(hex, dir) do
    {_l, c, h} = Contrast.to_oklch(hex)
    Contrast.from_oklch({if(dir == :darker, do: 0.0, else: 1.0), c, h})
  end

  defp fmt(r), do: :erlang.float_to_binary(Float.floor(r * 10) / 10, decimals: 1)
end
