defmodule Platform.Design.MaskChipContrastGuardTest do
  @moduledoc """
  Holds the shell's "Names masked" chip, its desktop popover and its phone
  confirm sheet (task 01a1600d, `PlatformWeb.Components.MaskNamesChip`) to
  AA in all ten painted variants (Burrow, Midnight, Sand, Forest, High
  contrast; light and dark), the way `space_sheet_contrast_guard_test.exs`
  holds rung 7's sheet. The designer's direction canvas 01a1616c measured
  the end time at 4.5:1 on base-200 in all ten; this file enforces it.

  ## Pairs and floors

  | pair                                                       | floor |
  |------------------------------------------------------------|-------|
  | chip label: base-content on base-200 (rest)                 | 4.5   |
  | chip label: base-content on base-100 (pressed, desk hover)  | 4.5   |
  | end time: --subtle on base-200 (painted)                    | 4.5   |
  | end time: --subtle on base-100 (painted)                    | 4.5   |
  | eye-slash icon: base-content on base-200                    | 3     |
  | eye-slash icon: base-content on base-100                    | 3     |
  | confirm body: base-content on base-100                      | 4.5   |
  | confirm body end time: --subtle on base-100 (painted)       | 4.5   |
  | Turn off label: base-content on its base-200 fill           | 4.5   |
  | Turn off label pressed: base-content on base-100            | 4.5   |

  ## Why the icon is the meaningful non-text, and the edge is not

  Below lg the label collapses after four seconds (app.css, the
  `mask-chip-collapse` block), and from then on the eye-slash icon is the
  ONLY thing that identifies the control, so it is held to 3:1 (WCAG
  1.4.11). The 1px `border-edge` around the pill separates it from the
  header but is not needed to identify it (the icon and the fill do that),
  so it is not asserted.

  `--subtle` is alpha over its ground, so its pairs are PAINTED on the worst
  pixel `Platform.Design.PaintedComposite` allows. Every other token is
  opaque and measured with `WcagContrast.contrast/2`. The table prints.

  ## Source guards

  The chip's markup is read and the classes the pairs above assume are
  asserted PRESENT before anything is refuted. The app.css block is parsed
  into its top-level at-rules: the collapse may run only inside the
  below-lg media query, the reduced-motion rule keeps the 4s delay (it
  changes at the same moment, without motion), and the desktop hover lives
  only inside `(hover: hover)`.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @component_path Path.expand(
                    "../../../lib/platform_web/components/mask_names_chip.ex",
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

    {:ok, blocks: blocks, source: File.read!(@component_path), css: app_css}
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
    ink = "--color-base-content"

    [
      {"label / base-200", ratio(b, ink, "--color-base-200"), @aa_text},
      {"label / base-100", ratio(b, ink, "--color-base-100"), @aa_text},
      {"time / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"time / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"icon / base-200", ratio(b, ink, "--color-base-200"), @non_text},
      {"icon / base-100", ratio(b, ink, "--color-base-100"), @non_text},
      {"body / base-100", ratio(b, ink, "--color-base-100"), @aa_text},
      {"body time / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"Turn off / base-200", ratio(b, ink, "--color-base-200"), @aa_text},
      {"Turn off pressed / base-100", ratio(b, ink, "--color-base-100"), @aa_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    # Anti-vacuity: exactly the ten painted variants, each a real ratio.
    assert length(@variants) == 12
    assert length(blocks) == 12

    rows = for b <- blocks, do: {b, pairs(b)}

    for {b, ps} <- rows, {label, r, _} <- ps do
      assert is_number(r) and r > 1, "#{b.id} #{b.mode}: #{label} is #{inspect(r)}"
    end

    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nNames masked chip AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
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

  describe "the component paints the grounds and inks this table measures" do
    defp class_attrs(src), do: Regex.scan(~r/class="([^"]*)"/, src, capture: :all_but_first)

    defp class_of(src, data_role) do
      case Regex.run(~r/data-role="#{data_role}"[^>]*?class="([^"]*)"/s, src) do
        [_, class] -> class
        nil -> flunk("no class beside data-role=#{data_role}")
      end
    end

    test "present first: grounds, inks and the pressed step", %{source: src} do
      assert length(class_attrs(src)) > 0

      chip = Regex.run(~r/data-role="mask-names-chip".*?class="([^"]*)"/s, src) |> List.last()
      assert chip =~ "bg-base-200"
      assert chip =~ "active:bg-base-100"
      assert chip =~ "border-edge"

      assert class_of(src, "mask-chip-label") =~ "text-base-content"
      assert class_of(src, "mask-chip-until") =~ "text-subtle"
      assert class_of(src, "mask-chip-turn-off") =~ "bg-base-200"
      assert src =~ ~s(hero-eye-slash size-4 shrink-0 text-base-content)
      assert src =~ "bg-base-100 p-3"
    end

    test "no hover utility, no opacity ink, no status colour, no literal", %{source: src} do
      classes = class_attrs(src) |> List.flatten()
      # Positive control for the scan below.
      assert length(classes) > 5

      for class <- classes, token <- String.split(class) do
        refute String.contains?(token, "hover:"), "hover utility: #{token}"
        refute String.starts_with?(token, "text-base-content/"), "opacity ink: #{token}"
        refute token in ~w(text-error text-warning text-info bg-warning bg-error bg-info)
      end

      refute src =~ "[data-theme"
      assert Regex.scan(@colour_literal, src) == []
    end
  end

  describe "the app.css block" do
    # Top-level `@media` at-rules as {prelude, body}, braces balanced.
    defp media_blocks(css) do
      css = Regex.replace(~r{/\*.*?\*/}s, css, "")

      ~r/@media\s*([^{]*)\{/
      |> Regex.scan(css, return: :index)
      |> Enum.map(fn [{start, len}, {ps, pl}] ->
        prelude = css |> binary_part(ps, pl) |> String.trim()
        {prelude, body_from(css, start + len, 1, start + len)}
      end)
    end

    defp body_from(css, pos, 0, from), do: binary_part(css, from, pos - from - 1)

    defp body_from(css, pos, depth, from) do
      case binary_part(css, pos, 1) do
        "{" -> body_from(css, pos + 1, depth + 1, from)
        "}" -> body_from(css, pos + 1, depth - 1, from)
        _ -> body_from(css, pos + 1, depth, from)
      end
    end

    defp below_lg?(prelude), do: prelude =~ "(width < 64rem)"

    test "the collapse runs only inside the below-lg media query", %{css: css} do
      uncommented = Regex.replace(~r{/\*.*?\*/}s, css, "")
      total = length(Regex.scan(~r/animation:\s*mask-chip-collapse/, uncommented))
      assert total >= 1, "no rule animates mask-chip-collapse"
      assert uncommented =~ "@keyframes mask-chip-collapse"

      inside =
        for {prelude, body} <- media_blocks(css), below_lg?(prelude) do
          length(Regex.scan(~r/animation:\s*mask-chip-collapse/, body))
        end
        |> Enum.sum()

      assert inside == total, "a mask-chip-collapse animation sits outside (width < 64rem)"
    end

    test "reduced motion keeps the 4s delay below lg", %{css: css} do
      rules =
        for {prelude, body} <- media_blocks(css),
            prelude =~ "prefers-reduced-motion: reduce",
            below_lg?(prelude),
            body =~ ~s([data-role="mask-chip-label"]),
            do: body

      assert [body] = rules
      assert body =~ ~r/animation-delay:\s*4s/
      assert body =~ ~r/animation-duration:\s*0s/
    end

    test "the desktop hover lives only inside (hover: hover) at lg", %{css: css} do
      uncommented = Regex.replace(~r{/\*.*?\*/}s, css, "")
      selector = ~s([data-role="mask-names-chip"]:hover)
      total = length(String.split(uncommented, selector)) - 1
      assert total == 1

      inside =
        for {prelude, body} <- media_blocks(css),
            prelude =~ "(hover: hover)",
            prelude =~ "(width >= 64rem)",
            String.contains?(body, selector),
            do: body

      assert [body] = inside
      assert body =~ "var(--color-base-100)"
      refute body =~ @colour_literal
    end
  end
end
