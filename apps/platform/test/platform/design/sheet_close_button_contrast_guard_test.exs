defmodule Platform.Design.SheetCloseButtonContrastGuardTest do
  @moduledoc """
  Holds the sheet header X's paint (`.sheet-close-button`, task 01a161c4
  stage 2) in all ten preset variants (Burrow, Midnight, Sand, Forest, High
  contrast; light and dark).

  The X is an icon-only control: meaningful non-text, so every state clears
  3:1 (WCAG 1.4.11) against the ground it sits on.

  | state                          | ink           | ground   | floor |
  |--------------------------------|---------------|----------|-------|
  | rest (`text-subtle`)           | --subtle      | base-100 | 3     |
  | pressed (`active:bg-base-200`) | --subtle      | base-200 | 3     |
  | desktop hover (app.css)        | base-content  | base-200 | 3     |

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha
  over the ground, so its pairs are PAINTED on the worst pixel
  `Platform.Design.PaintedComposite` allows (the method the More sheet guard
  uses). base-content and base-200 are opaque and measured with
  `WcagContrast.contrast/2`. The table prints.

  The desktop-hover pair is the one app.css paints: the guard reads the
  `.sheet-close-button:hover` rule's body and asserts it names exactly these
  two tokens, so a token swap there cannot leave this table measuring the
  wrong pair.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)

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
    {"high-contrast", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

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

    {:ok, blocks: blocks, all_rules: CssRules.rules(app_css)}
  end

  defp c(b, token), do: Blocks.resolve!(b, token)

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
      {"rest: subtle / base-100 (painted)", subtle_on(b, "--color-base-100")},
      {"pressed: subtle / base-200 (painted)", subtle_on(b, "--color-base-200")},
      {"desktop hover: base-content / base-200",
       W.contrast(c(b, "--color-base-content"), c(b, "--color-base-200"))}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "every state of the X clears 3:1 in all ten variants; the table prints",
       %{blocks: blocks} do
    # Anti-vacuity: exactly the ten variants, each pair a real ratio.
    assert length(blocks) == 10
    assert length(Enum.uniq_by(blocks, &{&1.id, &1.mode})) == 10

    rows = for b <- blocks, do: {b, pairs(b)}

    for {b, ps} <- rows, {label, r} <- ps do
      assert is_number(r) and r > 1.0, "#{b.id} #{b.mode}: #{label} is #{inspect(r)}"
    end

    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nSheet close button (X) non-text contrast, floor 3:1:\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r} -> f4(r) end) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, r} <- ps, r < @non_text do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{@non_text}"
      end

    assert failures == []
  end

  test "the desktop hover rule paints exactly the measured pair", %{all_rules: all} do
    hover = Enum.filter(all, &(&1.selector == ".sheet-close-button:hover"))
    assert [rule] = hover
    assert rule.body =~ ~r/(^|;|\s)color:\s*var\(--color-base-content\);/
    assert rule.body =~ ~r/background:\s*var\(--color-base-200\);/
  end
end
