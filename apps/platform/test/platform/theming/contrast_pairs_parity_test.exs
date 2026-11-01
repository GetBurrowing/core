defmodule Platform.Theming.ContrastPairsParityTest do
  @moduledoc """
  `Platform.Theming.ContrastPairs` reproduces the preset guards exactly (task
  01a1557a-fe9b stage 1).

    * For each of the ten variants (Burrow's two app.css blocks, the eight
      preset blocks), every ContrastPairs row of `Theming.ledger/2` equals the
      ratio the guards compute, read straight from the CSS the guards' way
      (`ThemeBlocks` + `ThemeBlockAssertions.resolve!/2`, `WcagContrast`, the
      worst `PaintedComposite` pixel at the block's own `--subtle`), floored
      to two decimals, with the guards' floor and verdict. Today every one
      passes, so every one must.
    * Neither guard keeps a literal pair or floor of its own: both read
      ContrastPairs.

  Named mutation (stage commit): (c) put a literal `{"--x", "--y"}` pair back
  in `theme_presets_guard_test.exs` and the second test goes red.
  """
  use ExUnit.Case, async: true

  alias Platform.Accounts.ThemePreference
  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming
  alias Platform.Theming.ContrastPairs
  alias Platform.Theming.Ledger
  alias Platform.Theming.Presets

  import Platform.Design.ThemeBlockAssertions, only: [resolve!: 2]

  @app Path.expand("../../..", __DIR__)
  @presets_css Path.join(@app, "assets/css/theme_presets.css")
  @app_css Path.join(@app, "assets/css/app.css")
  @guards Path.join(@app, "test/platform/design")
  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  setup_all do
    presets_css = File.read!(@presets_css)
    app_css = File.read!(@app_css)
    blocks = ThemeBlocks.preset_blocks(presets_css)

    variants =
      for %{id: id} <- ThemePreference.presets(), mode <- ["light", "dark"] do
        block =
          if id == "burrow",
            do: ThemeBlocks.burrow_block(app_css, mode),
            else: Enum.find(blocks, &(&1.id == id and &1.mode == mode))

        {id, mode, block}
      end

    {:ok, variants: variants}
  end

  test "the ledger's ContrastPairs rows equal the guards' ratios in all ten variants", %{
    variants: variants
  } do
    assert length(variants) == 12
    assert Enum.all?(variants, fn {_, _, b} -> b end)

    mismatches =
      for {id, mode, block} <- variants,
          ledger = Theming.ledger(Presets.get(id), mode),
          expected = ContrastPairs.rows(id),
          {want, got} <- Enum.zip(expected, Enum.take(ledger, length(expected))),
          guard = guard_ratio(block, want),
          {got.label, got.ratio, got.floor, got.pass?} !=
            {want.label, Ledger.floor2(guard), want.floor, guard >= want.floor} do
        "#{id} #{mode} #{want.label}: ledger #{got.label} #{got.ratio} (floor #{got.floor}), " <>
          "guard #{Float.round(guard, 4)} (floor #{want.floor})"
      end

    assert mismatches == [], Enum.join(mismatches, "\n")

    # The row set is the guards': 16 solid text pairs, 6 painted, 3 rings.
    assert length(ContrastPairs.rows(nil)) == 25

    failing =
      for {id, mode, _} <- variants,
          row <- Enum.take(Theming.ledger(Presets.get(id), mode), 25),
          not row.pass?,
          do: "#{id} #{mode} #{row.label} #{row.ratio}"

    assert failing == [],
           "the guards pass today; the ledger must too:\n" <> Enum.join(failing, "\n")

    # High contrast's full-strength text is held to 7:1, the rest to 4.5:1.
    assert ContrastPairs.text_floor("high-contrast") == 7.0
    assert ContrastPairs.text_floor("burrow") == 4.5
    assert ContrastPairs.text_floor(nil) == 4.5
  end

  test "neither guard keeps a literal pair or floor: both read ContrastPairs" do
    for f <- ["theme_presets_guard_test.exs", "burrow_palette_guard_test.exs"] do
      src = File.read!(Path.join(@guards, f))

      literal_pairs = Regex.scan(~r/\{\s*"--[a-z0-9-]+",\s*"--[a-z0-9-]+"\s*\}/, src)
      assert literal_pairs == [], "#{f} declares its own pairs: #{inspect(literal_pairs)}"

      literal_floors = Regex.scan(~r/@\w+\s+\d+\.\d+\s*$/m, src)
      assert literal_floors == [], "#{f} declares its own floor: #{inspect(literal_floors)}"

      assert src =~ "ContrastPairs.text_pairs()" or src =~ "ContrastPairs.preset_text_pairs()",
             "#{f} does not read its pairs from ContrastPairs"
    end
  end

  # The guards' measurement of one row, from the CSS.
  defp guard_ratio(block, %{paint: :solid, fg: fg, bg: bg}),
    do: W.contrast(resolve!(block, fg), resolve!(block, bg))

  defp guard_ratio(block, %{paint: {:painted, strength}, fg: fg, bg: bg}) do
    pct = if strength == :subtle, do: subtle_strength(block), else: strength
    {r, _} = PaintedComposite.contrast_min(resolve!(block, fg), resolve!(block, bg), pct)
    r
  end

  defp subtle_strength(block) do
    [_, pct] = Regex.run(@subtle_form, ThemeBlocks.declaration(block.decls, "--subtle"))
    String.to_integer(pct)
  end
end
