defmodule Platform.Design.ReplyQuoteContrastGuardTest do
  @moduledoc """
  Holds the paint of the main-log reply quote (task 01a174f5 stage 3,
  `PlatformWeb.Components.ReplyQuote`, design canvas 01a174f6) in all ten
  preset variants (Burrow, Midnight, Sand, Forest, High contrast; light and
  dark). Modelled on `reply_chip_contrast_guard_test.exs`: slots are read
  from a RENDER of the real component (the log's jump button, an agent quote
  and a person quote, plus the deleted and no-access states), tokens from
  app.css and theme_presets.css, and `--subtle` is painted on the worst pixel
  `PaintedComposite` allows.

  | pair                                                     | floor  |
  |----------------------------------------------------------|--------|
  | author: its text slot on the quote fill                  | 4.5    |
  | excerpt: its text slot on the quote fill (painted subtle) | 4.5   |
  | deleted / no-access line: its text slot on the fill      | 4.5    |
  | agent bar: `--ag-<slot>` on the fill, all ten slots       | 3      |
  | person bar: its slot on the fill                         | MEASURED, not held |

  The person bar (`base-300`) is MEASURED and printed but not held to 3:1:
  the bar is `aria-hidden` decoration, the stage spec says to record a
  failing number as a finding rather than invent a colour, and the quote's
  author name (held at 4.5 above) carries who is quoted.

  The fill is opaque (`bg-base-200`, no alpha), so it is the ground whatever
  row tint (an agent row's `--ag-tint`, the own-row band) sits behind it.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Agents.ColorPalette
  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @root Path.expand("../../..", __DIR__)
  @app_css_path Path.join(@root, "assets/css/app.css")
  @presets_path Path.join(@root, "assets/css/theme_presets.css")

  @aa_text 4.5
  @aa_non_text 3.0

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

    {:ok, blocks: blocks, html: quotes_html()}
  end

  defp quotes_html do
    visible = %{
      status: :visible,
      message_id: "msg-1",
      author: "Agent A",
      preview: "The viewer fix is in review."
    }

    assigns = %{
      agent: Map.put(visible, :agent_slot, "teal"),
      person: %{visible | author: "Member", message_id: "msg-2"} |> Map.put(:agent_slot, nil),
      deleted: %{status: :deleted},
      none: %{status: :no_access}
    }

    rendered_to_string(~H"""
    <div id="agent"><PlatformWeb.Components.ReplyQuote.reply_quote quote={@agent} jump={true} /></div>
    <div id="person">
      <PlatformWeb.Components.ReplyQuote.reply_quote quote={@person} jump={true} />
    </div>
    <div id="deleted">
      <PlatformWeb.Components.ReplyQuote.reply_quote quote={@deleted} jump={true} />
    </div>
    <div id="none"><PlatformWeb.Components.ReplyQuote.reply_quote quote={@none} jump={true} /></div>
    """)
  end

  defp node!(html, selector) do
    case html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list() do
      [node | _] -> node
      [] -> flunk("the render has no #{selector}")
    end
  end

  defp classes(node), do: node |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)

  defp one(list, what) do
    assert length(list) == 1, "expected exactly one #{what}, got #{inspect(list)}"
    hd(list)
  end

  defp fill_slot(classes, what) do
    slot = one(for("bg-" <> v <- classes, do: v), what)
    refute String.contains?(slot, "/"), "#{what}: #{slot} is translucent; paint it first"
    slot
  end

  defp text_slot(classes, what) do
    case for("text-" <> s <- classes, s in ["subtle", "base-content"], do: s) do
      [s] ->
        s

      other ->
        flunk("#{what}: expected one text-subtle or text-base-content, got #{inspect(other)}")
    end
  end

  defp slots(html) do
    agent_quote = node!(html, ~s(#agent [data-role="reply-quote"]))
    person_quote = node!(html, ~s(#person [data-role="reply-quote"]))

    # Positive controls on the render itself: the visible quotes are the jump
    # buttons, the agent one points --ag at its slot, the person one has none,
    # and the deleted / no-access blocks are not buttons.
    assert html =~ ~r/<button[^>]*data-role="reply-quote"[^>]*data-agent-slot="teal"/
    assert LazyHTML.attribute(person_quote, "data-agent-slot") == []
    assert Enum.to_list(LazyHTML.query(LazyHTML.from_fragment(html), ~s(#deleted button))) == []
    assert Enum.to_list(LazyHTML.query(LazyHTML.from_fragment(html), ~s(#none button))) == []

    agent_bar = classes(node!(html, ~s(#agent [data-role="reply-quote-bar"])))
    person_bar = classes(node!(html, ~s(#person [data-role="reply-quote-bar"])))

    %{
      fill: fill_slot(classes(agent_quote), "agent quote fill"),
      person_fill: fill_slot(classes(person_quote), "person quote fill"),
      author:
        text_slot(classes(node!(html, ~s(#agent [data-role="reply-quote-author"]))), "author"),
      preview:
        text_slot(classes(node!(html, ~s(#agent [data-role="reply-quote-preview"]))), "excerpt"),
      deleted:
        text_slot(classes(node!(html, ~s(#deleted [data-role="reply-quote-deleted"]))), "deleted"),
      none:
        text_slot(
          classes(node!(html, ~s(#none [data-role="reply-quote-no-access"]))),
          "no access"
        ),
      agent_bar: one(for("bg-" <> v <- agent_bar, do: v), "agent bar"),
      person_bar: one(for("bg-" <> v <- person_bar, do: v), "person bar")
    }
  end

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp ratio(b, "subtle", ground) do
    g = PaintedComposite.from_bytes(PaintedComposite.bytes(c(b, "--color-#{ground}")))
    {r, _} = PaintedComposite.contrast_min(c(b, "--color-base-content"), g, subtle_pct(b))
    r
  end

  defp ratio(b, ink, ground), do: W.contrast(c(b, "--color-#{ink}"), c(b, "--color-#{ground}"))

  defp f2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  test "the quote's text clears 4.5:1 on base-200 in all ten variants; the table prints", ctx do
    assert length(ctx.blocks) == 10
    s = slots(ctx.html)

    # The decisions the stage holds (canvas 01a174f6 palette).
    assert s.fill == "base-200"
    assert s.person_fill == "base-200"
    assert s.author == "base-content"
    assert s.preview == "subtle"
    assert s.deleted == "subtle"
    assert s.agent_bar == "(--ag)"
    assert s.person_bar == "base-300"

    pairs = [
      {"author #{s.author}", s.author},
      {"excerpt #{s.preview}", s.preview},
      {"deleted #{s.deleted}", s.deleted},
      {"no-access #{s.none}", s.none}
    ]

    rows = for b <- ctx.blocks, do: {b, for({l, ink} <- pairs, do: {l, ratio(b, ink, s.fill)})}

    IO.puts(
      "\nReply quote text on #{s.fill}:\n| Variant | " <>
        Enum.map_join(pairs, " | ", &elem(&1, 0)) <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", &f2(elem(&1, 1))) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows,
          {label, r} <- ps,
          r < @aa_text,
          do: "#{b.id} #{b.mode}: #{label} #{f2(r)}"

    assert failures == []
  end

  test "the agent-slot bar clears 3:1 on base-200 for all ten slots in all ten variants", ctx do
    s = slots(ctx.html)
    ids = ColorPalette.ids()
    assert length(ids) == 10

    rows =
      for b <- ctx.blocks do
        {b, for(id <- ids, do: {id, W.contrast(c(b, "--ag-#{id}"), c(b, "--color-#{s.fill}"))})}
      end

    IO.puts(
      "\nReply quote agent bar (--ag-<slot>) on #{s.fill}:\n| Variant | " <>
        Enum.join(ids, " | ") <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", &f2(elem(&1, 1))) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows,
          {id, r} <- ps,
          r < @aa_non_text,
          do: "#{b.id} #{b.mode}: #{id} #{f2(r)}"

    assert failures == []
  end

  test "the person bar (base-300 on base-200) is measured in all ten variants and printed", ctx do
    s = slots(ctx.html)

    rows = for b <- ctx.blocks, do: {b, ratio(b, s.person_bar, s.fill)}
    assert length(rows) == 10

    under = for {b, r} <- rows, r < @aa_non_text, do: "#{b.id} #{b.mode} #{f2(r)}"

    IO.puts(
      "\nReply quote person bar #{s.person_bar} on #{s.fill} (floor #{@aa_non_text}, measured, not held):\n" <>
        Enum.map_join(rows, "\n", fn {b, r} -> "| #{b.id} #{b.mode} | #{f2(r)} |" end) <>
        "\nunder #{@aa_non_text}: #{length(under)} of 10 #{inspect(under)}"
    )

    # Every ratio is a real measurement (a token that failed to resolve would
    # have raised in `resolve!/2`).
    assert Enum.all?(rows, fn {_b, r} -> is_float(r) and r >= 1.0 end)
  end
end
