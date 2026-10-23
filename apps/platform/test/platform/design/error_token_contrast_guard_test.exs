defmodule Platform.Design.ErrorTokenContrastGuardTest do
  @moduledoc """
  The one shared guard for the error tokens (task 01a160c4 stage 1). It holds
  `--color-error` and `--color-error-content` in all ten preset variants
  (Burrow, Midnight, Sand, Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                   | floor |
  |----------------------------------------|-------|
  | `--color-error` on `--color-base-100`  | 4.5   |
  | `--color-error` on `--color-base-200`  | 4.5   |
  | `--color-error-content` on `--color-error` | 4.5 |

  Error is TEXT wherever `text-error` paints it (a failed-action sentence, a
  validation line), so both grounds owe the 4.5:1 text floor. The content
  token is the label on an error fill, also text.

  ## The table prints before anything is asserted

  The designer's direction canvas 01a1618e asks that the next retune start
  from numbers. So the guard prints every variant/pair/ratio/floor row first,
  plus an advisory column: the ratio the OTHER achromatic content (white for
  black, black for white) would give, which says whether a retune has to flip
  the content colour. The advisory column is never asserted.

  ## Retune (task 01a160c4), measured by this guard

  Same hue, lower lightness, values from the designer's ruling. Burrow LIGHT is
  `#da1729` with WHITE content; Burrow DARK is `#f53c41` with BLACK content.
  The two Burrow blocks carry different reds by design and this guard asserts
  that they differ. The preset darks are `#e94c50` (midnight), `#ec4e52`
  (sand) and `#e94c51` (forest), all with black content. The preset lights
  (`#a3252a`) and high contrast (`#8f0000` / `#ff6b6b`) were untouched.

  ## The Stop and Undo hover label (task 01a160c4 stage 2)

  `--cc-stop-hover` is `color-mix(in oklch, var(--color-error) N%, black|white)`.
  It is the `color:` (and `border-color:`) of the 11.5px words "Stop" and
  "Undo" on the meeting candidate rail (`candidate_rail.ex`, the
  `candidate-btn--stop` and `candidate-btn--undo` buttons; `app.css`
  `.candidate-btn` sets `font-size: 11.5px` and `background: var(--cc-btn-bg)`),
  and their `:hover, :focus-visible` rules change only color and
  border-color. The fill never changes on hover. So the label is TEXT and the
  floor is 4.5:1 on `--cc-btn-bg`. This corrects the 3:1 non-text floor
  ("an icon on a fill") in the designer's direction canvas 01a1618e-3597.

  The border is not asserted separately. It is the same colour on the same
  `--cc-btn-bg`, so the 4.5 label assertion already bounds it above 3:1
  against that ground. Its contrast against the card ground outside the
  button is outside this guard.

  The mix percentage, the black/white endpoint and `--cc-btn-bg` are READ
  from `app.css`: the light `:root` block, the `[data-theme="dark"]` block and
  the `prefers-color-scheme: dark` copy. Exactly three `--cc-stop-hover`
  declarations must exist, and `theme_presets.css` must declare no `--cc-`
  token, so a per-preset override goes red here instead of being ignored.
  Light variants (Burrow, the preset lights, high contrast light) use the light
  block; dark variants use the dark block. The prefers-dark copy must equal the
  dark block.

  ### Why `WcagContrast.mix_oklab/3` measures `color-mix(in oklch, ...)` here

  The other endpoint is black or white, which is achromatic: chroma 0, so its
  oklch hue is powerless and the mix takes the error colour's hue. L and C
  then interpolate linearly at that fixed hue, and that is the same point as
  linear a/b interpolation in oklab, because a and b are C times cos/sin of
  that one hue. No new helper is needed unless a chromatic endpoint appears.
  This rests on the browser treating the achromatic hue as powerless, as
  CSS Color 4 specifies; the painted check is the task's review case.

  Positive control: from the PRE-retune Burrow error `oklch(63% 0.22 25)` the
  reader reproduces the figures the old comments were written from, light
  5.21 and dark 5.36.

  ## Anti-vacuity and the positive control

    * Exactly ten blocks are read, a missing one flunks, and every pair is
      resolved through `ThemeBlocks.resolve!/2`, which flunks on an undeclared
      token rather than measuring a default.
    * Positive control: the PRE-retune values (Burrow `oklch(63% 0.22 25)`,
      preset dark `#e5484d`) are parsed with `WcagContrast.parse!/1` and
      measured on the same variant's base-100. Each is under 4.5, so the floor
      can fire on exactly these grounds.

  Mutations (task 01a160c4 stage 1, each on its own probe branch): sand dark
  back to `#e5484d`; Burrow light content back to black; Burrow dark error
  collapsed to the light `#da1729`. Each turns this file red.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)

  @aa_text 4.5

  # The figures the pre-retune stop-hover comments carried (light, dark).
  @stop_hover_pre_retune %{"light" => 5.21, "dark" => 5.36}

  @stop_hover_form ~r/^color-mix\(in oklch, var\(--color-error\) (\d+)%, (black|white)\)$/

  @variants [
    {"burrow", "light"},
    {"burrow", "dark"},
    {"burrow-midnight", "light"},
    {"burrow-midnight", "dark"},
    {"burrow-sand", "light"},
    {"burrow-sand", "dark"},
    {"burrow-forest", "light"},
    {"burrow-forest", "dark"},
    {"high-contrast", "light"},
    {"high-contrast", "dark"}
  ]

  # {label, foreground token, ground token}
  @pairs [
    {"error on base-100", "--color-error", "--color-base-100"},
    {"error on base-200", "--color-error", "--color-base-200"},
    {"error-content on error", "--color-error-content", "--color-error"}
  ]

  # The values the retune replaced, keyed by the variants that carried them.
  @pre_retune [
    {{"burrow", "light"}, "oklch(63% 0.22 25)"},
    {{"burrow", "dark"}, "oklch(63% 0.22 25)"},
    {{"burrow-midnight", "dark"}, "#e5484d"},
    {{"burrow-sand", "dark"}, "#e5484d"},
    {{"burrow-forest", "dark"}, "#e5484d"}
  ]

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    blocks =
      for {id, mode} = key <- @variants do
        Map.get(by_key, key) || flunk("no #{id} #{mode} block")
      end

    {:ok, blocks: blocks, app_css: app_css, presets: presets}
  end

  # An opaque slot's colour: `--color-<slot>`, else Burrow's bare `--<slot>`
  # (mirrors settings_contrast_guard_test.exs).
  defp opaque(b, "--color-" <> slot = token) do
    if Blocks.declaration(b.decls, token),
      do: Blocks.resolve!(b, token),
      else: Blocks.resolve!(b, "--#{slot}")
  end

  # The achromatic content a retune could flip to: white for black, black for white.
  defp other_content(color) do
    if W.luminance(color) > 0.5, do: W.hex("#000000"), else: W.hex("#FFFFFF")
  end

  defp measure(blocks) do
    for b <- blocks, {label, fg, ground} <- @pairs do
      fg_c = opaque(b, fg)
      ground_c = opaque(b, ground)
      ratio = W.contrast(fg_c, ground_c)

      advisory =
        if fg == "--color-error-content",
          do: Float.round(W.contrast(other_content(fg_c), ground_c), 4),
          else: nil

      %{variant: "#{b.id} #{b.mode}", pair: label, ratio: ratio, advisory: advisory}
    end
  end

  defp print_table(rows) do
    header =
      String.pad_trailing("variant", 22) <>
        String.pad_trailing("pair", 26) <>
        String.pad_trailing("ratio", 9) <> "floor  other-content"

    lines =
      Enum.map(rows, fn r ->
        String.pad_trailing(r.variant, 22) <>
          String.pad_trailing(r.pair, 26) <>
          String.pad_trailing(:erlang.float_to_binary(r.ratio, decimals: 4), 9) <>
          String.pad_trailing("#{@aa_text}", 7) <>
          if(r.advisory, do: :erlang.float_to_binary(r.advisory, decimals: 4), else: "")
      end)

    IO.puts("\n[error-token contrast]\n" <> Enum.join([header | lines], "\n"))
  end

  test "exactly ten variant blocks are read", %{blocks: blocks} do
    assert length(blocks) == 10
    assert Enum.map(blocks, &{&1.id, &1.mode}) == @variants
  end

  test "every error pair clears #{@aa_text}:1 in all ten variants (table prints first)",
       %{blocks: blocks} do
    rows = measure(blocks)
    print_table(rows)

    # Anti-vacuity: every variant contributed every pair.
    assert length(rows) == length(@variants) * length(@pairs)

    failures =
      rows
      |> Enum.filter(&(&1.ratio < @aa_text))
      |> Enum.map(&"#{&1.variant}: #{&1.pair} #{Float.round(&1.ratio, 4)}:1")

    assert failures == [],
           "error pairs under the #{@aa_text}:1 text floor:\n  " <> Enum.join(failures, "\n  ")
  end

  test "the Burrow light and dark blocks declare different --color-error values",
       %{blocks: blocks} do
    [light, dark] =
      for mode <- ["light", "dark"] do
        b = Enum.find(blocks, &(&1.id == "burrow" and &1.mode == mode))

        Blocks.declaration(b.decls, "--color-error") ||
          flunk("burrow #{mode}: no --color-error")
      end

    refute String.downcase(light) == String.downcase(dark),
           "the Burrow light and dark --color-error are both #{light}; the two blocks " <>
             "take different reds by design (task 01a160c4). Never collapse them."
  end

  test "positive control: the pre-retune reds fail the floor on these grounds",
       %{blocks: blocks} do
    measured =
      for {{id, mode}, value} <- @pre_retune do
        b = Enum.find(blocks, &(&1.id == id and &1.mode == mode))
        old = W.parse!(value)

        {id, mode, value, W.contrast(old, opaque(b, "--color-base-100")),
         W.contrast(old, opaque(b, "--color-base-200"))}
      end

    IO.puts(
      "\n[error-token positive control: pre-retune error on base-100 / base-200]\n" <>
        Enum.map_join(measured, "\n", fn {id, mode, value, on_100, on_200} ->
          String.pad_trailing("#{id} #{mode}", 22) <>
            String.pad_trailing(value, 20) <>
            :erlang.float_to_binary(on_100, decimals: 4) <>
            " / " <> :erlang.float_to_binary(on_200, decimals: 4)
        end)
    )

    # Only base-100 is asserted: it is the ground every pre-retune value
    # failed on. base-200 prints for the record.
    for {id, mode, value, ratio, _on_200} <- measured do
      assert ratio < @aa_text,
             "#{id} #{mode}: the pre-retune #{value} measures #{Float.round(ratio, 4)}:1 " <>
               "on base-100, so the #{@aa_text} floor could not tell it from the retune."
    end
  end

  # ── --cc-stop-hover (stage 2) ──────────────────────────────────────────

  # The three rail token blocks that declare --cc-stop-hover, comments stripped.
  defp rail_blocks(app_css) do
    pick = fn open ->
      app_css
      |> Blocks.blocks_after(open)
      |> Enum.map(&Blocks.strip_comments/1)
      |> Enum.filter(&Blocks.declaration(&1, "--cc-stop-hover"))
    end

    %{
      "light" => pick.("\n:root {"),
      "dark" => pick.(~s(\n[data-theme="dark"] {)),
      "prefers-dark" => pick.(~s|\n  :root:not([data-theme="light"]) {|)
    }
  end

  defp one_rail_block!(app_css, scope) do
    case Map.fetch!(rail_blocks(app_css), scope) do
      [block] ->
        block

      other ->
        flunk("#{scope}: expected one block declaring --cc-stop-hover, found #{length(other)}")
    end
  end

  # {pct, endpoint colour, raw text, btn-bg colour} for a rail scope.
  defp stop_hover_recipe(app_css, scope) do
    block = one_rail_block!(app_css, scope)
    raw = Blocks.declaration(block, "--cc-stop-hover")

    {pct, endpoint} =
      case Regex.run(@stop_hover_form, raw) do
        [_, pct, "black"] -> {String.to_integer(pct), W.hex("#000000")}
        [_, pct, "white"] -> {String.to_integer(pct), W.hex("#FFFFFF")}
        nil -> flunk("#{scope}: --cc-stop-hover is #{inspect(raw)}; teach the guard to mix it")
      end

    btn_bg =
      W.parse!(Blocks.declaration(block, "--cc-btn-bg") || flunk("#{scope}: no --cc-btn-bg"))

    {pct, endpoint, raw, btn_bg}
  end

  defp stop_hover_rows(blocks, app_css) do
    for b <- blocks do
      {pct, endpoint, _raw, btn_bg} = stop_hover_recipe(app_css, b.mode)
      error = opaque(b, "--color-error")
      label = W.mix_oklab(error, pct, endpoint)

      %{
        variant: "#{b.id} #{b.mode}",
        label_hex: W.to_hex(label),
        ratio: W.contrast(label, btn_bg),
        painted: W.contrast_painted(label, btn_bg),
        raw_error: W.contrast(error, btn_bg)
      }
    end
  end

  defp f4(x), do: :erlang.float_to_binary(x, decimals: 4)

  test "exactly three --cc-stop-hover declarations, and no --cc- token in the presets",
       %{app_css: app_css, presets: presets} do
    declared = Regex.scan(~r/^\s*--cc-stop-hover\s*:/m, Blocks.strip_comments(app_css))
    assert length(declared) == 3, "found #{length(declared)} --cc-stop-hover declarations"

    for {scope, found} <- rail_blocks(app_css) do
      assert length(found) == 1, "#{scope}: #{length(found)} blocks declare --cc-stop-hover"
    end

    refute Blocks.strip_comments(presets) =~ ~r/--cc-[a-z]/,
           "theme_presets.css declares a --cc- token; teach this guard the per-preset rail value"

    # The prefers-dark copy is the dark block's measurement, not a third one.
    assert stop_hover_recipe(app_css, "prefers-dark") == stop_hover_recipe(app_css, "dark")
  end

  test "the Stop and Undo hover label clears #{@aa_text}:1 on --cc-btn-bg in all ten variants (table prints first)",
       %{blocks: blocks, app_css: app_css} do
    rows = stop_hover_rows(blocks, app_css)

    IO.puts(
      "\n[stop-hover label on --cc-btn-bg]\n" <>
        String.pad_trailing("variant", 22) <>
        String.pad_trailing("label", 9) <>
        String.pad_trailing("ratio", 9) <>
        String.pad_trailing("painted", 9) <>
        String.pad_trailing("floor", 7) <>
        "raw-error\n" <>
        Enum.map_join(rows, "\n", fn r ->
          String.pad_trailing(r.variant, 22) <>
            String.pad_trailing(r.label_hex, 9) <>
            String.pad_trailing(f4(r.ratio), 9) <>
            String.pad_trailing(f4(r.painted), 9) <>
            String.pad_trailing("#{@aa_text}", 7) <> f4(r.raw_error)
        end)
    )

    assert length(rows) == 10

    failures =
      rows
      |> Enum.filter(&(&1.ratio < @aa_text))
      |> Enum.map(&"#{&1.variant}: stop-hover label #{&1.label_hex} #{f4(&1.ratio)}:1")

    assert failures == [],
           "Stop/Undo hover labels under the #{@aa_text}:1 text floor:\n  " <>
             Enum.join(failures, "\n  ")
  end

  test "positive control: the pre-retune error reproduces the old stop-hover figures",
       %{app_css: app_css} do
    old = W.parse!("oklch(63% 0.22 25)")

    for {mode, want} <- @stop_hover_pre_retune do
      {pct, endpoint, _raw, btn_bg} = stop_hover_recipe(app_css, mode)
      label = W.mix_oklab(old, pct, endpoint)
      got = W.contrast(label, btn_bg)

      IO.puts(
        "[stop-hover positive control] #{mode}: pre-retune label #{W.to_hex(label)} " <>
          "#{f4(got)}:1 (painted #{f4(W.contrast_painted(label, btn_bg))}), " <>
          "raw error #{f4(W.contrast(old, btn_bg))}:1"
      )

      assert Float.round(got, 2) == want,
             "#{mode}: the pre-retune stop-hover measures #{f4(got)}, the old comment said " <>
               "#{want}; the reader does not reproduce the arithmetic the comments came from."
    end
  end
end
