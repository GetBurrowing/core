defmodule Platform.Design.DevicePanelContrastGuardTest do
  @moduledoc """
  The "Sound and video" panel's paint (task 01a1f4c5 stage 2; design
  direction canvas 01a1f4c7, which asks for every pair to clear AA in both
  themes, measured against `app.css`, not the canvas). Held in every preset
  variant, light and dark.

  | pair                                                       | floor |
  |------------------------------------------------------------|-------|
  | title, section label, device name: base-content / base-100 | 4.5   |
  | tags, empty line: --subtle / base-100                      | 4.5   |
  | hovered / focused row: base-content / base-200             | 4.5   |
  | hovered / focused row tag: --subtle / base-200             | 4.5   |
  | device-switched strap: info-content / info                 | 4.5   |
  | meter fill: info / base-200 (its track)                    | 3     |
  | selected check: base-content / base-100                    | 3     |
  | blocked / failed icon: error / base-100                    | 3     |
  | caret and phone trigger glyph: base-content / base-200     | 3     |
  | lobby mic-check warning icon: warning / base-100 (stage 3) | 3     |

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, so its
  pairs are PAINTED: the worst pixel `Platform.Design.PaintedComposite`
  allows. Every other token is opaque and measured with
  `WcagContrast.contrast/2`.

  Canvas conflict, recorded: the canvas allows "base-content at reduced
  emphasis" for secondary lines; the repo's slot for that is `text-subtle`
  (`--subtle`), so that is what the panel uses and what is measured here.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)

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

    {:ok, blocks: blocks}
  end

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)
  defp ratio(b, ink, ground), do: W.contrast(c(b, ink), c(b, ground))

  defp subtle_on(b, ground) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    pct =
      case Regex.run(@subtle_form, value) do
        [_, n] -> String.to_integer(n)
        nil -> flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard")
      end

    {r, _} = PaintedComposite.contrast_min(c(b, "--color-base-content"), c(b, ground), pct)
    r
  end

  defp pairs(b) do
    [
      {"label / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"tag (subtle) / base-100", subtle_on(b, "--color-base-100"), @aa_text},
      {"row hover / base-200", ratio(b, "--color-base-content", "--color-base-200"), @aa_text},
      {"tag hover (subtle) / base-200", subtle_on(b, "--color-base-200"), @aa_text},
      {"strap info-content / info", ratio(b, "--color-info-content", "--color-info"), @aa_text},
      {"meter info / base-200", ratio(b, "--color-info", "--color-base-200"), @non_text},
      {"check / base-100", ratio(b, "--color-base-content", "--color-base-100"), @non_text},
      {"error icon / base-100", ratio(b, "--color-error", "--color-base-100"), @non_text},
      {"caret glyph / base-200", ratio(b, "--color-base-content", "--color-base-200"), @non_text},
      {"warning icon / base-100", ratio(b, "--color-warning", "--color-base-100"), @non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "every pair clears its floor in every variant; the table prints", %{blocks: blocks} do
    assert length(blocks) == 12
    rows = for b <- blocks, do: {b, pairs(b)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nDevice panel AA table (WCAG 2.x; subtle rows on the worst pixel):\n" <>
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

  @panel Path.expand("../../../lib/platform_web/components/meetings/device_panel.ex", __DIR__)
  @hook Path.expand("../../../assets/js/hooks/meeting_device_panel.js", __DIR__)

  test "the panel and hook paint only the measured slots" do
    src = File.read!(@panel) <> File.read!(@hook)

    # The slots measured above are the ones used.
    for token <-
          ~w(bg-base-100 border-edge text-base-content text-subtle bg-info text-info-content bg-scrim) do
      assert src =~ token, "expected #{token} in the panel or hook"
    end

    # Never orange on the selected device or anywhere in the panel; never a
    # dimmed base-content; never neutral text (fails AA on base-100 in dark).
    refute src =~ ~r/(?<![-\w])(text|bg|border|ring)-primary(?![-\w])/
    refute src =~ "btn-primary"
    refute src =~ ~r/text-base-content\/\d+/
    refute src =~ ~r/(?<![-\w])text-neutral(?![-\w])/
  end
end
