defmodule Platform.Design.InboxListContrastGuardTest do
  @moduledoc """
  Holds the phone Inbox list's paint (task 01a1557a-ad2d stage 4,
  `PlatformWeb.Inbox.InboxList`: rows, header and the long-press row sheet) in
  all ten preset variants (Burrow, Midnight, Sand, Forest, High contrast;
  light and dark).

  ## Pairs and floors

  | pair                                                                   | floor |
  |------------------------------------------------------------------------|-------|
  | h1, author slot, unread excerpt: base-content on the list ground       | 4.5   |
  | the same on the pressed ground                                         | 4.5   |
  | read excerpt, time, kind word, empty copy: --subtle on list (painted)  | 4.5   |
  | the same on the pressed ground (painted)                               | 4.5   |
  | 'Step failed' kind dot: error on the list and pressed grounds          | 3     |
  | header chip label: base-content on base-100 (the chip's fill)          | 4.5   |
  | sheet title and items, focused Actions button: base-content on base-100 | 4.5  |
  | back chevron: --subtle on the list ground (painted, non-text)          | 3     |
  | unread dot: primary on the list ground and on the pressed ground       | 3     |

  The grounds come from Saru's Inbox canvas 01a15ec4 (`pal`): the list is
  base-200, a pressed row and the sheet are base-100, and there is no hover
  state anywhere, so there is no hover pair. The guard does not assume those
  slots: it reads the list ground from the root's `bg-*` class, the pressed
  ground from the row's `active:bg-*` class, and the unread dot's and the
  failed kind dot's slots from their `bg-*` classes, then
  measures what it read. A slot edit in `inbox_list.ex` is followed, never
  assumed, and the structural tests below pin the slots the ruling names.

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha over
  the ground, so every pair it is in is PAINTED (the worst pixel
  `Platform.Design.PaintedComposite` allows), never derived. Every other token
  is opaque and measured with `WcagContrast.contrast/2`. The table prints.

  ## 'Step failed' is a dot, not error text

  The status-dot rule: status words in a list are body text, and the dot
  beside them carries the colour. So "Step failed" is subtle like every kind
  word, and the colour is an `aria-hidden` `bg-error` dot beside it, held
  here at the 3:1 non-text floor. `text-error` is refuted in the component's
  code because of that rule, not because of contrast: the error token clears
  4.5:1 in all ten variants since task 01a160c4, and the refute stays.

  ## Not asserted: avatars and kind discs (WCAG 1.4.11)

  1.4.11 Non-text Contrast asks 3:1 of graphical objects "required to
  understand the content". The 42px avatar and the kind-icon disc are not: the
  author slot names the source and the kind word names the kind, both in text
  that this guard holds at 4.5. Both are `aria-hidden` (asserted below from
  source). The chip's border is not the control's only identifier either: its
  label is text. If the author slot or the kind word ever leaves the row, the
  avatar or disc becomes the only carrier and this exemption stops holding.

  ## Hypotheses (planner estimates), with verdicts measured here

    * H-subtle: --subtle on base-200 is the tightest TEXT pair in the dark
      variants.
    * H-dot: primary on base-100 is the tightest NON-TEXT pair in the light
      variants, and sand light is the likeliest failure.

  Both are printed with a verdict by the table test.

  ## Structure (anti-vacuity first)

  The component source is read and shown to be the phone list (non-empty,
  contains `inbox-phone`) before anything is refuted in it. Then: no
  `text-base-content/<n>`, no hex literal, no `[data-theme` selector, no
  `hover:`, no `text-[Npx]` under 12; the root paints `bg-base-200` and the
  row `active:bg-base-100`; every avatar and disc is `aria-hidden`.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.ThemeBlocks, as: Blocks

  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @source_path Path.expand(
                 "../../../lib/platform_web/live/inbox/inbox_list.ex",
                 __DIR__
               )

  @aa_text 4.5
  @aa_non_text 3.0

  # The surface the chip and the sheet paint (Saru `pal`).
  @raised "--color-base-100"

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

    source = File.read!(@source_path)

    # The code below the moduledoc: the moduledoc may NAME what it forbids
    # ("no `hover:` utility"), and a refute over prose would red on the doc.
    code =
      case String.split(source, "use Phoenix.Component", parts: 2) do
        [_doc, code] -> code
        _ -> flunk("inbox_list.ex: no `use Phoenix.Component`; the split point moved")
      end

    {:ok, blocks: blocks, source: source, code: code}
  end

  # ── source reading ─────────────────────────────────────────────────────

  # Every opening tag (component or element) carrying `data-role="<role>"`.
  defp tags_with_role(source, role) do
    ~r/<[a-z.]+\b(?:(?!>)[\s\S])*?data-role="#{role}"(?:(?!>)[\s\S])*?>/
    |> Regex.scan(source)
    |> Enum.map(&hd/1)
  end

  defp tag_with_role(source, role) do
    case tags_with_role(source, role) do
      [tag] -> tag
      other -> flunk("expected exactly one element with data-role=#{role}, got #{length(other)}")
    end
  end

  defp class_list(tag) do
    case Regex.run(~r/\bclass="([^"]+)"/, tag) do
      [_, classes] -> String.split(classes, ~r/\s+/, trim: true)
      nil -> flunk("no static class attribute in #{tag}")
    end
  end

  defp one(list, what) do
    assert length(list) == 1, "expected exactly one #{what}, got #{inspect(list)}"
    hd(list)
  end

  # The slots the component paints, read from its own classes.
  defp slots(source) do
    root = source |> tag_with_role("inbox-phone") |> class_list()
    row = source |> tag_with_role("inbox-row") |> class_list()
    dot = source |> tag_with_role("inbox-row-unread-dot") |> class_list()
    kind_dot = source |> tag_with_role("inbox-row-kind-dot") |> class_list()

    %{
      list: one(for("bg-" <> s <- root, do: s), "list ground"),
      pressed: one(for("active:bg-" <> s <- row, do: s), "pressed ground"),
      dot: one(for("bg-" <> s <- dot, do: s), "dot fill"),
      failed: one(for("bg-" <> s <- kind_dot, do: s), "kind dot fill")
    }
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)
  defp tok(slot), do: "--color-#{slot}"
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

  # {label, ratio, floor, kind} for one variant.
  defp pairs(b, s) do
    list = tok(s.list)
    pressed = tok(s.pressed)
    body = "--color-base-content"
    err = tok(s.failed)

    [
      {"body / #{s.list} (list)", ratio(b, body, list), @aa_text, :text},
      {"body / #{s.pressed} (pressed)", ratio(b, body, pressed), @aa_text, :text},
      {"subtle / #{s.list} (painted)", subtle_on(b, list), @aa_text, :text},
      {"subtle / #{s.pressed} (painted)", subtle_on(b, pressed), @aa_text, :text},
      {"kind dot #{s.failed} / #{s.list}", ratio(b, err, list), @aa_non_text, :non_text},
      {"kind dot #{s.failed} / #{s.pressed}", ratio(b, err, pressed), @aa_non_text, :non_text},
      {"chip label / base-100", ratio(b, body, @raised), @aa_text, :text},
      {"sheet + Actions / base-100", ratio(b, body, @raised), @aa_text, :text},
      {"chevron subtle / #{s.list} (painted)", subtle_on(b, list), @aa_non_text, :non_text},
      {"dot #{s.dot} / #{s.list}", ratio(b, tok(s.dot), list), @aa_non_text, :non_text},
      {"dot #{s.dot} / #{s.pressed}", ratio(b, tok(s.dot), pressed), @aa_non_text, :non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  defp tightest(rows, filter) do
    for {b, ps} <- rows, {label, r, _floor, kind} <- ps, filter.(b, kind) do
      {label, b, r}
    end
    |> Enum.min_by(&elem(&1, 2))
  end

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints",
       %{blocks: blocks, source: source} do
    assert length(blocks) == 12
    s = slots(source)

    rows = for b <- blocks, do: {b, pairs(b, s)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))
    floors = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 2))

    dark_text? = fn b, k -> k == :text and b.mode == "dark" end
    light_non_text? = fn b, k -> k == :non_text and b.mode == "light" end
    {sub_label, sub_b, sub_r} = tightest(rows, dark_text?)
    {dot_label, dot_b, dot_r} = tightest(rows, light_non_text?)

    IO.puts(
      "\nPhone Inbox AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n| floor | " <>
        Enum.map_join(floors, " | ", &f4/1) <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <>
            Enum.map_join(ps, " | ", fn {_, r, _, _} -> f4(r) end) <> " |"
        end) <>
        "\nH-subtle: tightest dark text pair is #{sub_label} #{f4(sub_r)} " <>
        "(#{sub_b.id} #{sub_b.mode}) -> " <>
        if(String.starts_with?(sub_label, "subtle / base-200"), do: "HOLDS", else: "FAILS") <>
        "\nH-dot: tightest light non-text pair is #{dot_label} #{f4(dot_r)} " <>
        "(#{dot_b.id} #{dot_b.mode}) -> " <>
        if(String.starts_with?(dot_label, "dot primary / base-100"),
          do: "HOLDS",
          else: "FAILS"
        ) <>
        "; sand light the likeliest failure -> " <>
        if(dot_b.id == "burrow-sand" and dot_r < @aa_non_text, do: "HOLDS", else: "FAILS")
    )

    failures =
      for {b, ps} <- rows, {label, r, floor, _} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "the guard measured the grounds and slots it read from source",
       %{blocks: blocks, source: source} do
    s = slots(source)
    labels = blocks |> hd() |> pairs(s) |> Enum.map(&elem(&1, 0))

    assert "body / #{s.list} (list)" in labels
    assert "body / #{s.pressed} (pressed)" in labels
    assert "kind dot #{s.failed} / #{s.list}" in labels
    assert "dot #{s.dot} / #{s.pressed}" in labels
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "anti-vacuity: the source read is the phone Inbox list", %{source: source} do
    assert byte_size(source) > 0
    assert source =~ "inbox-phone"
    assert source =~ ~s(data-role="inbox-row")
  end

  test "no text-base-content/<n>, hex literal, data-theme selector, hover: or sub-12px text",
       %{code: source} do
    # Anti-vacuity: the code slice is the list's markup, not an empty tail.
    assert byte_size(source) > 1000
    assert source =~ "inbox-phone"
    # Positive controls: the patterns below can match in this file's own
    # vocabulary (a body class, an arbitrary size and an active: variant).
    assert source =~ "text-base-content"
    assert Regex.match?(~r/text-\[\d+px\]/, source)
    assert source =~ "active:bg-"

    refute source =~ "text-base-content/"
    refute Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, source)
    refute source =~ "[data-theme"
    refute source =~ "hover:"
    # The status-dot rule: kind words are body text and the dot carries the
    # colour, so the failed kind word is never error text (whatever the
    # error token's contrast).
    refute source =~ "text-error"

    small =
      for [_, n] <- Regex.scan(~r/text-\[(\d+)px\]/, source),
          String.to_integer(n) < 12,
          do: n

    assert small == []
  end

  test "the list ground is base-200, the pressed row base-100, the failed kind dot error",
       %{source: source} do
    s = slots(source)
    assert s.list == "base-200"
    assert s.pressed == "base-100"
    assert s.failed == "error"
    assert s.dot == "primary"
  end

  test "the failed kind dot is aria-hidden: the word carries the meaning", %{source: source} do
    assert source |> tag_with_role("inbox-row-kind-dot") =~ ~s(aria-hidden="true")
  end

  test "avatars and kind discs are aria-hidden (decorative; no floor)", %{source: source} do
    avatars = tags_with_role(source, "inbox-row-avatar")
    # Positive control: both avatar forms (person/agent and kind disc).
    assert length(avatars) == 2

    for tag <- avatars do
      assert tag =~ ~s(aria-hidden="true"), tag
    end
  end
end
