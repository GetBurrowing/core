defmodule Platform.Design.MyTasksContrastGuardTest do
  @moduledoc """
  Holds the phone my-tasks list's paint (task 01a1557a-b20a stage 3,
  `PlatformWeb.Tasks.MyTasksList`) in all ten preset variants (Burrow,
  Midnight, Sand, Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                                  | floor |
  |-------------------------------------------------------|-------|
  | title: base-content on base-200 (the list ground)     | 4.5   |
  | title: base-content on base-100 (the pressed row)     | 4.5   |
  | meta + subtitle: --subtle on base-200 (painted)       | 4.5   |
  | meta + subtitle: --subtle on base-100 (painted)       | 4.5   |
  | All tasks label: base-content on base-200, base-100   | 4.5   |
  | Needs you pill: its text slot on its own fill slot    | 4.5   |

  base-100 is the PRESSED ground only. The list has no hover state (Saru's
  ruling on canvas 01a15db1, rev 2 and later), so there is no hover pair.

  The pill sits on the list's base-200 ground, but it paints its own fill, so
  the text never meets the list ground: its floor is the pill's text slot on
  the pill's fill slot (warning-content on warning as shipped), and base-200
  does not enter the pair. The guard reads both slots from the pill's class
  attribute in `my_tasks_list.ex` and measures THAT pair, so an edit to the
  pill's classes is followed, never assumed.

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha
  over the ground, so every pair it is in is PAINTED (the worst pixel
  `Platform.Design.PaintedComposite` allows), never derived. Every other token
  is opaque and measured with `WcagContrast.contrast/2`. The table prints.

  ## The status dot has no floor (WCAG 1.4.11)

  1.4.11 Non-text Contrast asks 3:1 of graphical objects "required to
  understand the content". The dot is not: the status word on the meta line
  says the same thing in text, which this guard holds at 4.5. The dot is
  `aria-hidden` (asserted below from source), decorative by construction, so
  no floor is asserted for it. If the status word ever leaves the row, the dot
  becomes the only carrier and this exemption stops holding.

  ## Hypotheses (planner estimates), with verdicts measured here

    * H-pill: warning-content on warning clears 4.5 in all ten; Burrow
      light's #fbfaf9 content was the likeliest failure.
    * H-subtle-ground: --subtle on base-200 is the tightest text pair.

  Both are printed with a verdict by the table test.

  ## Structure (anti-vacuity first)

  The component source is read and shown to be the list (non-empty, contains
  `tasks-my-list`) before anything is refuted in it. Then: no
  `text-base-content/<n>`, no hex literal, no `[data-theme` selector, no
  `text-[Npx]` under 12; the pill names exactly one fill slot and one text
  slot; the dot is `aria-hidden`.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @source_path Path.expand(
                 "../../../lib/platform_web/live/tasks/my_tasks_list.ex",
                 __DIR__
               )

  @aa_text 4.5

  # The two grounds the list paints: the list itself and a pressed row.
  @list_ground "--color-base-200"
  @pressed_ground "--color-base-100"

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

  # Utility suffixes that are not colours, so `bg-*` / `text-*` classes with
  # them are not the pill's paint.
  @text_sizes ~w(xs sm base lg xl 2xl 3xl)

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

    {:ok, blocks: blocks, source: File.read!(@source_path)}
  end

  # ── source reading ─────────────────────────────────────────────────────

  # The opening tag of the element carrying `data-role="<role>"`.
  defp tag_with_role(source, role) do
    case Regex.scan(~r/<[a-z.]+\b(?:(?!>)[\s\S])*?data-role="#{role}"(?:(?!>)[\s\S])*?>/, source) do
      [[tag]] -> tag
      other -> flunk("expected exactly one element with data-role=#{role}, got #{length(other)}")
    end
  end

  defp class_list(tag) do
    case Regex.run(~r/\bclass="([^"]+)"/, tag) do
      [_, classes] -> String.split(classes, ~r/\s+/, trim: true)
      nil -> flunk("no static class attribute in #{tag}")
    end
  end

  # {fill slot, text slot} named by the pill's classes, e.g.
  # {"warning", "warning-content"}.
  defp pill_slots(source) do
    classes = source |> tag_with_role("tasks-needs-you") |> class_list()

    fills = for "bg-" <> slot <- classes, do: slot

    texts =
      for "text-" <> slot <- classes,
          slot not in @text_sizes,
          not String.starts_with?(slot, "["),
          do: slot

    assert length(fills) == 1, "the pill must name exactly one fill slot, got #{inspect(fills)}"
    assert length(texts) == 1, "the pill must name exactly one text slot, got #{inspect(texts)}"
    {hd(fills), hd(texts)}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)

  # A Tailwind colour slot as a token: `--color-<slot>`, which every theme
  # block declares for daisyUI slots, else the bare `--<slot>` the block
  # declares for Burrow's own slots (`warning-dim`).
  defp slot(b, name) do
    if Blocks.declaration(b.decls, "--color-#{name}"),
      do: c(b, "--color-#{name}"),
      else: c(b, "--#{name}")
  end

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

  defp pairs(b, {fill, text}) do
    [
      {"title / base-200 (list)", ratio(b, "--color-base-content", @list_ground)},
      {"title / base-100 (pressed)", ratio(b, "--color-base-content", @pressed_ground)},
      {"meta+subtitle / base-200 (painted)", subtle_on(b, @list_ground)},
      {"meta+subtitle / base-100 (painted)", subtle_on(b, @pressed_ground)},
      {"All tasks / base-200", ratio(b, "--color-base-content", @list_ground)},
      {"All tasks / base-100 (pressed)", ratio(b, "--color-base-content", @pressed_ground)},
      {"pill #{text} / #{fill}", W.contrast(slot(b, text), slot(b, fill))}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every text pair clears 4.5 in all ten variants; the table prints",
       %{blocks: blocks, source: source} do
    assert length(blocks) == 10
    pill = pill_slots(source)

    rows = for b <- blocks, do: {b, pairs(b, pill)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    min_of = fn label ->
      rows
      |> Enum.map(fn {b, ps} -> {b, ps |> List.keyfind(label, 0) |> elem(1)} end)
      |> Enum.min_by(&elem(&1, 1))
    end

    {pill_b, pill_min} = min_of.(List.last(labels))

    text_labels = List.delete_at(labels, -1)

    {tight_label, {tight_b, tight_r}} =
      text_labels
      |> Enum.map(&{&1, min_of.(&1)})
      |> Enum.min_by(fn {_, {_, r}} -> r end)

    IO.puts(
      "\nMy-tasks list AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r} -> f4(r) end) <> " |"
        end) <>
        "\nH-pill: min #{f4(pill_min)} (#{pill_b.id} #{pill_b.mode}) -> " <>
        if(pill_min >= @aa_text, do: "HOLDS", else: "FAILS") <>
        "\nH-subtle-ground: tightest text pair is #{tight_label} #{f4(tight_r)} " <>
        "(#{tight_b.id} #{tight_b.mode}) -> " <>
        if(String.starts_with?(tight_label, "meta+subtitle / base-200"),
          do: "HOLDS",
          else: "FAILS"
        )
    )

    failures =
      for {b, ps} <- rows, {label, r} <- ps, r < @aa_text do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{@aa_text}"
      end

    assert failures == []
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "anti-vacuity: the source read is the my-tasks list", %{source: source} do
    assert byte_size(source) > 0
    assert source =~ "tasks-my-list"
    assert source =~ ~s(data-role="tasks-needs-you")
  end

  test "no text-base-content/<n>, hex literal, data-theme selector or sub-12px text",
       %{source: source} do
    assert source =~ "tasks-my-list"
    # Positive controls: the patterns below can match in this file's own
    # vocabulary (a body class and an arbitrary size are present).
    assert source =~ "text-base-content"
    assert Regex.match?(~r/text-\[\d+px\]/, source)

    refute source =~ "text-base-content/"
    refute Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, source)
    refute source =~ "[data-theme"

    small =
      for [_, n] <- Regex.scan(~r/text-\[(\d+)px\]/, source),
          String.to_integer(n) < 12,
          do: n

    assert small == []
  end

  test "the pill names exactly one fill and one text slot, and the guard measures them",
       %{source: source, blocks: blocks} do
    {fill, text} = pill_slots(source)
    [b | _] = blocks
    label = "pill #{text} / #{fill}"
    assert {^label, _} = b |> pairs({fill, text}) |> List.last()
  end

  test "the status dot is aria-hidden (decorative; no floor)", %{source: source} do
    dot = tag_with_role(source, "tasks-my-dot")
    assert dot =~ ~s(aria-hidden="true")
  end
end
