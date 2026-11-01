defmodule Platform.Design.SpaceSheetContrastGuardTest do
  @moduledoc """
  Holds the phone space sheet's paint (task 01a1557a-8a6d, rung 7) in all ten
  variants (Burrow, Midnight, Sand, Forest, High contrast; light and dark),
  the way `chat_list_contrast_guard_test.exs` holds rung 6's list.

  The sheet is base-100 and a pressed row is base-200 (the designer's canvas
  01a160ea: on a base-100 sheet, pressed is the other step).

  ## Pairs and floors

  | pair                                                  | floor |
  |-------------------------------------------------------|-------|
  | row label: base-content on base-100                    | 4.5   |
  | row label pressed: base-content on base-200            | 4.5   |
  | preview / meta / section label: --subtle on base-100   | 4.5   |
  | preview pressed: --subtle on base-200 (painted)        | 4.5   |
  | segment border (unselected): --subtle on base-100      | 3     |
  | segment border (unselected) pressed: --subtle on 200   | 3     |
  | segment border (selected): base-content on base-200    | 3     |
  | scope switch track on: primary on base-100             | 3     |
  | scope switch track on, pressed: primary on base-200    | 3     |
  | header Call icon: primary on base-100                  | 3     |

  No row is disabled: the Agents row stopped toggling the mutex and opens
  the Agents sheet (task 01a1557a-8f80 stage 2), so the `disabled:` variant
  went with it. `--subtle` is alpha over its ground, so its pairs are PAINTED on the worst
  pixel `Platform.Design.PaintedComposite` allows. Every other token is opaque
  and measured with `WcagContrast.contrast/2`. The table prints.

  ## Structure (anti-vacuity first)

  The component source is read and the classes the pairs above assume are
  asserted PRESENT before anything is refuted, so an empty or moved file
  fails here instead of passing every refute: no `hover:` (a phone surface),
  no `text-error` (the status-dot rule: status words in a list are body
  text, and the dot beside them carries the colour; the sheet has no status
  word to colour, and nothing destructive), no colour literal and no
  `[data-theme` qualifier.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @component_path Path.expand(
                    "../../../lib/platform_web/live/chat/partials/space_sheet.ex",
                    __DIR__
                  )

  @aa_text 4.5
  @non_text 3.0

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
    {"high-contrast", "dark"},
    {"sage", "light"},
    {"sage", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  @colour_literal ~r/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\boklch\(|\boklab\(|\blab\(|\blch\(|\bhwb\(/

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

    {:ok, blocks: blocks, source: File.read!(@component_path)}
  end

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)
  defp ratio(b, ink, ground), do: W.contrast(c(b, ink), c(b, ground))

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp subtle_on(b, ground) do
    {r, _} =
      PaintedComposite.contrast_min(c(b, "--color-base-content"), c(b, ground), subtle_pct(b))

    r
  end

  defp pairs(b) do
    [
      {"label / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"label pressed / base-200", ratio(b, "--color-base-content", "--color-base-200"),
       @aa_text},
      {"subtle / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"subtle pressed / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"segment border / base-100 (painted)", subtle_on(b, "--color-base-100"), @non_text},
      {"segment border pressed / base-200 (painted)", subtle_on(b, "--color-base-200"),
       @non_text},
      {"segment selected border / base-200", ratio(b, "--color-base-content", "--color-base-200"),
       @non_text},
      {"switch on / base-100", ratio(b, "--color-primary", "--color-base-100"), @non_text},
      {"switch on pressed / base-200", ratio(b, "--color-primary", "--color-base-200"),
       @non_text},
      {"Call icon / base-100", ratio(b, "--color-primary", "--color-base-100"), @non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    assert length(blocks) == 12

    rows = for b <- blocks, do: {b, pairs(b)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nSpace sheet AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "the component paints the grounds and cues this table measures", %{source: src} do
    # Present first, so the refutes below cannot pass on an empty file.
    assert src =~ ~s(id="space-sheet")
    assert src =~ "active:bg-base-200"
    assert src =~ "text-base-content"
    assert src =~ "text-subtle"
    assert src =~ ~s(do: "border-base-content bg-base-200 font-medium")
    assert src =~ ~s(else: "border-subtle")
    assert src =~ ~S|if(@on?, do: "bg-primary", else: "bg-base-300")|
  end

  test "no hover, no error colour, no colour literal, no theme qualifier", %{source: src} do
    assert String.length(src) > 1_000, "read back a near-empty source"

    refute src =~ "hover:", "a phone surface carries no hover: utility"

    refute src =~ "text-error",
           "status-dot rule: status words are body text; a dot beside them carries the colour"

    refute src =~ "[data-theme", "no theme-qualified selector or utility"

    literals =
      src
      |> String.replace(~r/#\{[^}]*\}/, "")
      |> then(&Regex.scan(@colour_literal, &1))

    assert literals == [], "colour literals in the sheet: #{inspect(literals)}"
  end
end
