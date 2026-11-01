defmodule Platform.Design.ReplyChipContrastGuardTest do
  @moduledoc """
  Holds the paint of the composer's 'Replying to <author>' chip (task
  01a174f5 stage 2, `Partials.Composer.reply_chip/1`) in all ten preset
  variants (Burrow, Midnight, Sand, Forest, High contrast; light and dark),
  with no exemption. Modelled on `message_attention_contrast_guard_test.exs`:
  slots are read from a RENDER of the real component, tokens from app.css and
  theme_presets.css, and `--subtle` is painted on the worst pixel
  `PaintedComposite` allows.

  | pair                                                       | floor |
  |------------------------------------------------------------|-------|
  | author: its text slot on the chip fill                     | 4.5   |
  | excerpt: its text slot on the chip fill (painted subtle)   | 4.5   |
  | 'Replying to' lead: its text slot on the chip fill         | 4.5   |
  | x glyph: its text slot on the chip fill                    | 3     |
  | x glyph: its text slot on its desktop hover fill           | 3     |

  The chip fill is opaque (`bg-base-200`, no alpha), so it is the ground
  whatever the composer's glass behind it paints.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

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

    {:ok, blocks: blocks, html: chip_html()}
  end

  defp chip_html do
    assigns = %{
      target: %{
        message_id: "msg-1",
        space_id: "space-1",
        author: "Agent A",
        preview: "The viewer fix is in review.",
        agent_slot: "teal"
      }
    }

    rendered_to_string(~H"""
    <PlatformWeb.ChatLive.Partials.Composer.reply_chip target={@target} />
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

  # The unprefixed `bg-<slot>`; an alpha fill would need painting, so refuse it.
  defp fill_slot(classes, what) do
    slot = one(for("bg-" <> v <- classes, do: v), what)
    refute String.contains?(slot, "/"), "#{what}: #{slot} is translucent; paint it first"
    slot
  end

  defp hover_fill(classes, what) do
    one(for("lg:hover:bg-" <> v <- classes, do: v), what)
  end

  defp text_slot(classes, what) do
    case for("text-" <> s <- classes, s in ["subtle", "base-content"], do: s) do
      [s] ->
        s

      other ->
        flunk("#{what}: expected one text-subtle or text-base-content, got #{inspect(other)}")
    end
  end

  # The nearest text slot: the node's own, else its parent's (the author and
  # lead inherit nothing else).
  defp slots(html) do
    chip = node!(html, ~s([data-role="compose-reply-chip"]))
    author = node!(html, ~s([data-role="compose-reply-author"]))
    # The chip is the shared ReplyQuote block since stage 3; its lead line
    # carries its own role.
    lead = node!(html, ~s([data-role="compose-reply-lead"]))
    preview = node!(html, ~s([data-role="compose-reply-preview"]))
    cancel = node!(html, ~s([data-role="compose-reply-cancel"]))

    %{
      fill: fill_slot(classes(chip), "chip fill"),
      author: text_slot(classes(author), "author"),
      lead: text_slot(classes(lead), "lead"),
      preview: text_slot(classes(preview), "excerpt"),
      x: text_slot(classes(cancel), "x glyph"),
      x_hover: hover_fill(classes(cancel), "x hover fill")
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

  test "the chip's text and x clear their floors in all ten variants; the table prints", ctx do
    assert length(ctx.blocks) == 12
    s = slots(ctx.html)

    # The decision the stage holds: author base-content, excerpt subtle, on base-200.
    assert s.fill == "base-200"
    assert s.author == "base-content"
    assert s.preview == "subtle"

    pairs = [
      {"author #{s.author} / #{s.fill}", s.author, s.fill, @aa_text},
      {"excerpt #{s.preview} / #{s.fill}", s.preview, s.fill, @aa_text},
      {"lead #{s.lead} / #{s.fill}", s.lead, s.fill, @aa_text},
      {"x #{s.x} / #{s.fill}", s.x, s.fill, @aa_non_text},
      {"x #{s.x} / hover #{s.x_hover}", s.x, s.x_hover, @aa_non_text}
    ]

    rows =
      for b <- ctx.blocks, do: {b, for({l, ink, g, f} <- pairs, do: {l, ratio(b, ink, g), f})}

    IO.puts(
      "\nReply chip AA table:\n| Variant | " <>
        Enum.map_join(pairs, " | ", &elem(&1, 0)) <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", &f2(elem(&1, 1))) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f2(r)} < #{floor}"
      end

    assert failures == []
  end
end
