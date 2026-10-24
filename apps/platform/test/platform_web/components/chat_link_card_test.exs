defmodule PlatformWeb.Components.ChatLinkCardTest do
  @moduledoc """
  Link previews stage 1, at the component: no card paints the globe, an
  outside link in prose is an inline chip, a locked card stays type-only, and
  a Burrow card shows its badge, hint and type tile (or cover).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Platform.Chat.{ContentRenderer, LinkSites}
  alias PlatformWeb.Components.ChatLinkCard

  defp link(url, opts \\ []) do
    preview = LinkSites.describe(url)

    %{
      kind: :link,
      url: url,
      bare_line?: Keyword.get(opts, :bare, true),
      host: URI.parse(url).host,
      path: URI.parse(url).path || "",
      preview: preview,
      display: Keyword.get(opts, :display, :card)
    }
  end

  defp canvas(extra \\ %{}) do
    Map.merge(
      %{
        kind: :canvas,
        url: "/canvases/x",
        bare_line?: true,
        canvas_id: "c1",
        space_id: "s1",
        title: "Burrow redesign masters",
        space_name: "design",
        badge: "Canvas",
        hint: nil,
        cover: nil,
        tagline: nil
      },
      extra
    )
  end

  defp prototype(extra \\ %{}) do
    Map.merge(
      %{
        kind: :prototype,
        url: "/proto/p1/3/",
        bare_line?: true,
        prototype_id: "p1",
        name: "Send button feel",
        version: 3,
        open_url: "/proto/p1/3/",
        badge: "Prototype · v3",
        hint: "6 options · tap to open",
        cover: nil,
        tagline: nil
      },
      extra
    )
  end

  defp cards(cards), do: render_component(&ChatLinkCard.link_cards/1, msg_id: "m1", cards: cards)

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(html, sel), do: html |> doc() |> LazyHTML.query(sel)
  defp text(html, sel), do: html |> q(sel) |> LazyHTML.text() |> String.trim()

  test "no card, internal or external, paints the globe" do
    html =
      cards([
        canvas(),
        prototype(),
        link("https://github.com/acme/rate-kit"),
        link("https://example.com/catering/office-orders"),
        link("https://www.youtube.com/watch?v=abc")
      ])

    assert Enum.count(q(html, "[data-role=link-card]")) == 5
    refute html =~ "globe"
    assert Enum.count(q(html, "[data-role=link-site-tile]")) == 3
    assert Enum.count(q(html, "[data-role=link-card-tile][data-type]")) == 2
  end

  test "an outside card shows the smart title, meta and site tile" do
    html = cards([link("https://github.com/acme/api/pull/7")])
    assert text(html, "[data-role=link-card-title]") =~ "Pull request #7"
    assert text(html, "[data-role=link-card-meta]") =~ "GitHub · acme/api"
    assert Enum.count(q(html, "[data-role=link-site-tile][data-site=github] svg")) == 1
  end

  test "an unknown host gets its monogram on the hashed slot" do
    html = cards([link("https://example.com/a/b-c")])
    slot = LinkSites.slot_for("example.com")

    assert [tile] =
             q(html, "[data-role=link-site-tile][data-monogram-slot=#{slot}]") |> Enum.to_list()

    assert LazyHTML.text(tile) =~ "E"
  end

  test "a video page keeps a full card with a Video label" do
    html = cards([link("https://www.youtube.com/watch?v=abc", bare: false)])
    assert text(html, "[data-role=link-card-kind]") =~ "Video"
  end

  test "a chip-display card is not a card; its index survives for the next card" do
    html =
      cards([link("https://example.com/x/y-z", bare: false, display: :chip), canvas()])

    assert Enum.count(q(html, "[data-role=link-card]")) == 1
    assert Enum.count(q(html, "#link-card-m1-1[data-kind=canvas]")) == 1
    assert cards([link("https://example.com/x/y-z", bare: false, display: :chip)]) =~ ~r/\A\s*\z/
  end

  describe "chips in prose" do
    defp render(content, card_list) do
      content
      |> ContentRenderer.render_message(chips: ChatLinkCard.chips("m1", card_list))
      |> Phoenix.HTML.safe_to_string()
    end

    test "a bare URL inside a sentence becomes a chip with the smart title" do
      url = "https://github.com/acme/api/issues/42"
      html = render("see #{url} for details", [link(url, bare: false, display: :chip)])

      assert [chip] =
               q(html, ~s(button[data-role=link-chip][phx-click=viewer_open][phx-value-card="0"]))
               |> Enum.to_list()

      assert LazyHTML.text(chip) =~ "Issue #42"
      assert html =~ "for details"
      assert Enum.count(q(html, "a")) == 0
      assert Enum.count(q(html, "[data-role=link-chip] [data-site=github]")) == 1
    end

    test "the sender's own link text is kept as the chip label" do
      url = "https://example.com/x/office-orders"
      html = render("order [from here](#{url}) today", [link(url, bare: false, display: :chip)])
      assert text(html, "[data-role=link-chip-label]") == "from here"
    end

    test "a chip title is never mention-decorated" do
      url = "https://x.com/ops_daily/status/1"
      html = render("lol #{url} right", [link(url, bare: false, display: :chip)])
      assert text(html, "[data-role=link-chip-label]") == "Post by @ops_daily"
      assert Enum.count(q(html, "[data-role=link-chip] .text-primary")) == 0
    end

    test "with no cards the anchor stays an anchor" do
      html = render("see https://example.com/x for details", nil)
      assert Enum.count(q(html, "a[href='https://example.com/x']")) == 1
      assert Enum.count(q(html, "[data-role=link-chip]")) == 0
    end
  end

  test "a locked card stays type-only" do
    html = cards([%{kind: :locked, type: :prototype, url: "/proto/secret/1/", bare_line?: true}])
    assert text(html, "[data-kind=locked]") =~ "Prototype · You don't have access"
    assert Enum.count(q(html, "[data-kind=locked] [data-role=link-card-title]")) == 0
    assert Enum.count(q(html, "[data-kind=locked] [data-role=link-card-hint]")) == 0
    refute html =~ "secret"
  end

  describe "Burrow cards" do
    test "the prototype count hint and the type line" do
      html = cards([prototype()])
      assert text(html, "[data-role=link-card-hint]") =~ "6 options · tap to open"
      assert text(html, "[data-role=link-card-meta]") =~ "Prototype · v3"
      assert text(html, "[data-role=link-card-title]") =~ "Send button feel"
    end

    test "a canvas card without a hint says tap to open; a Mockup badge carries the space" do
      html = cards([canvas()])
      assert text(html, "[data-role=link-card-meta]") =~ "Canvas · #design"
      assert text(html, "[data-role=link-card-hint]") =~ "Tap to open"
      assert cards([canvas(%{badge: "Mockup"})]) =~ "Mockup · #design"
    end

    test "a cover replaces the type tile" do
      html = cards([canvas(%{cover: %{src: "/chat/attachments/abc", tier: :first_image}})])

      assert Enum.count(
               q(
                 html,
                 "[data-role=link-card-cover][data-tier=first_image] img[src='/chat/attachments/abc'][loading=lazy]"
               )
             ) == 1

      assert Enum.count(q(html, "[data-role=link-card-tile]")) == 0
    end

    test "a stage-2 tagline is the one description line when present" do
      html =
        cards([canvas(%{tagline: "Mobile and desktop masters", hint: "2 options · tap to open"})])

      assert text(html, "[data-role=link-card-hint]") =~ "Mobile and desktop masters"
      refute html =~ "2 options"
    end

    test "each type paints its own agent slot, and every card presses" do
      html = cards([canvas(), prototype()])
      assert html =~ "var(--ag-purple-tint)"
      assert html =~ "var(--ag-orange-tint)"
      assert Enum.count(q(html, "[data-role=link-card].active\\:scale-\\[0\\.97\\]")) == 2
    end
  end
end
