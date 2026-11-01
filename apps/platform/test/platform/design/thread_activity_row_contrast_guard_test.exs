defmodule Platform.Design.ThreadActivityRowContrastGuardTest do
  @moduledoc """
  Holds the thread-activity row's paint (task 01a174f5 stage 3, design canvas
  01a175ca) in all ten variants (Burrow, Midnight, Sand, Forest, High
  contrast; light and dark).

  The row has no ground of its own: at rest it shows the log's base-100
  (`#chat-message-scroller` is `bg-base-100`), and pressed (phone) or hovered
  (lg) it fills base-200.

  ## Pairs and floors

  | pair                                                   | floor |
  |--------------------------------------------------------|-------|
  | count / excerpt: base-content on base-100 (rest)       | 4.5   |
  | count / excerpt: base-content on base-200 (pressed)    | 4.5   |
  | glyph / label: --subtle on base-100 (painted)          | 4.5   |
  | glyph / label: --subtle on base-200 (painted)          | 4.5   |
  | focus ring: --focus-ring on base-100                   | 3     |
  | agent avatar initial: primary on base-300              | 4.5   |
  | human avatar initial: avatar-fallback-N ink on its bg  | 4.5   |

  The avatar is `aria-hidden` (the row's accessible name carries the
  replier), so its initial is measured at the text floor because the glyph is
  text, as the chat list guard does for its disc. The agent disc is the
  component's `bg-base-300 text-primary` per variant; the human discs are the
  eight theme-independent `.avatar-fallback-N` pairs in app.css, sliced and
  counted before they are measured.

  `--subtle` is alpha over its ground, so its pairs are PAINTED on the worst
  pixel `Platform.Design.PaintedComposite` allows. Every other token is opaque
  and measured with `WcagContrast.contrast/2`. The table prints.

  ## Anti-vacuity

  Ten blocks are asserted before any ratio is read. The component source is
  read for the token classes the pairs assume, so a markup change that moves a
  ground or an ink cannot leave this table measuring the old one. The floor
  comparison is shown to bite on a pair that must fail (base-100 on itself),
  and the fallback slice is asserted at exactly eight non-empty rules.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @component_path Path.expand(
                    "../../../lib/platform_web/components/thread_activity_row.ex",
                    __DIR__
                  )
  @avatar_path Path.expand(
                 "../../../lib/platform_web/components/avatar_components.ex",
                 __DIR__
               )
  @scroller_path Path.expand(
                   "../../../lib/platform_web/live/chat/partials/composer.ex",
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

    fallbacks =
      app_css
      |> CssRules.rules()
      |> Enum.filter(&(&1.at == [] and Regex.match?(~r/^\.avatar-fallback-\d+$/, &1.selector)))

    {:ok,
     blocks: blocks,
     fallbacks: fallbacks,
     source: File.read!(@component_path),
     avatar_source: File.read!(@avatar_path),
     scroller_source: File.read!(@scroller_path)}
  end

  # ── measurement ────────────────────────────────────────────────────────

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
      {"base-content / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"base-content / base-200 (pressed)", ratio(b, "--color-base-content", "--color-base-200"),
       @aa_text},
      {"subtle / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"subtle / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"focus ring / base-100", ratio(b, "--focus-ring", "--color-base-100"), @non_text},
      {"agent initial: primary / base-300", ratio(b, "--color-primary", "--color-base-300"),
       @aa_text}
    ]
  end

  defp decl!(rule, prop) do
    case Regex.run(~r/(?:^|;|\s)#{prop}:\s*([^;]+);/, rule.body) do
      [_, v] -> W.parse!(v)
      nil -> flunk("#{rule.selector}: no #{prop}")
    end
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    assert length(blocks) == 12

    rows = for b <- blocks, do: {b, pairs(b)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    mins =
      for {label, i} <- Enum.with_index(labels) do
        {label, rows |> Enum.map(fn {_, ps} -> elem(Enum.at(ps, i), 1) end) |> Enum.min()}
      end

    IO.puts(
      "\nThread-activity row AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end) <>
        "\n| minimum | " <> Enum.map_join(mins, " | ", fn {_, r} -> f4(r) end) <> " |"
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "human avatar initials: every avatar-fallback-N ink on its own disc", %{fallbacks: rules} do
    # Sliced and counted before any body is read: eight tones, none empty.
    assert length(rules) == 8
    assert Enum.all?(rules, &(String.trim(&1.body) != ""))

    measured =
      for r <- rules do
        {r.selector, W.contrast(decl!(r, "color"), decl!(r, "background"))}
      end

    IO.puts(
      "\nHuman avatar initials (theme-independent): " <>
        Enum.map_join(measured, ", ", fn {s, r} -> "#{s} #{f4(r)}" end) <>
        "; minimum #{measured |> Enum.map(&elem(&1, 1)) |> Enum.min() |> f4()}"
    )

    assert for({s, r} <- measured, r < @aa_text, do: "#{s} #{f4(r)}") == []
  end

  # ── anti-vacuity ───────────────────────────────────────────────────────

  test "the floor comparison bites: a pair that must fail does", %{blocks: blocks} do
    for b <- blocks do
      assert ratio(b, "--color-base-100", "--color-base-100") < @non_text
      # And painting at 0% strength would be the ground itself: the painted
      # path must be reading a real, non-zero --subtle.
      assert subtle_pct(b) > 0
    end
  end

  test "the markup paints the grounds and inks this table measures",
       %{source: src, avatar_source: avatar, scroller_source: scroller} do
    # The log ground the row sits on.
    assert scroller =~ ~s(id="chat-message-scroller")
    assert scroller =~ "overscroll-contain bg-base-100"
    assert scroller =~ ~s(id="thread-activity")

    # Rest has no ground; press and lg hover fill base-200; the focus ring.
    assert src =~ "active:bg-base-200"
    assert src =~ "lg:hover:bg-base-200"
    assert src =~ "focus-visible:ring-focus-ring"
    refute src =~ ~r/(?<![\w:-])bg-(?!base-200\b)/

    # Inks: subtle glyph and label, base-content count and excerpt, and no
    # other text colour, nor an opacity-suffixed one.
    assert src =~ ~s("w-8 shrink-0 text-center text-subtle")
    assert src =~ ~s(class="shrink-0 whitespace-nowrap text-subtle")
    assert src =~ ~s(class="font-semibold tabular-nums text-base-content")
    assert src =~ ~s(class="min-w-0 truncate text-base-content")
    refute src =~ ~r/text-(base-content|subtle)\/\d/

    # The avatar discs measured above are the ones the component paints.
    assert avatar =~ ~S{attr(:fallback_class, :any, default: "bg-base-300 text-primary")}
    assert avatar =~ ~S|"avatar-fallback-#{Platform.Avatars.fallback_tone(seed)}"|
    refute src =~ "fallback_class"
  end
end
