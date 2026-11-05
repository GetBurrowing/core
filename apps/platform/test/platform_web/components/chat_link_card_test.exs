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

  defp locked, do: %{kind: :locked, type: :prototype, url: "/proto/secret/1/", bare_line?: true}

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
    html = cards([locked()])
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

  describe "one card anatomy, no glow (link unfurls stage 1, direction canvas 01a1a945)" do
    # The class tokens of the ONE element `sel` matches, so an absence is
    # asserted on the same element whose presence is shown alongside it.
    defp tokens(html, sel) do
      assert [node] = html |> q(sel) |> Enum.to_list()
      assert [class] = LazyHTML.attribute(node, "class")
      String.split(class)
    end

    for {kind, slot} <- [canvas: "purple", prototype: "orange"] do
      test "the #{kind} card has no shadow and keeps its tinted #{slot} border" do
        html = cards([unquote(kind)()])
        classes = tokens(html, "[data-role=link-card][data-kind=#{unquote(kind)}]")

        # Positive control: the same class list is non-empty and carries the tint.
        assert classes != []

        assert "border-[color-mix(in_oklab,var(--ag-#{unquote(slot)})_40%,var(--color-edge))]" in classes

        assert Enum.filter(classes, &String.starts_with?(&1, "shadow-")) == []
        refute html =~ "shadow-"
      end
    end

    test "canvas, prototype, link and locked cards share a 12px inset and gap on base-100" do
      html = cards([canvas(), prototype(), link("https://github.com/acme/api/pull/7"), locked()])

      for kind <- ~w(canvas prototype link locked) do
        classes = tokens(html, "[data-role=link-card][data-kind=#{kind}]")
        assert "p-3" in classes, "#{kind}: no p-3 in #{inspect(classes)}"
        assert "gap-3" in classes, "#{kind}: no gap-3"
        assert "bg-base-100" in classes, "#{kind}: not on base-100"

        for old <- ~w(p-2 p-2.5 bg-base-200) do
          refute old in classes, "#{kind}: still carries #{old}"
        end
      end
    end

    test "only the outside-link card turns primary, and only on desktop hover" do
      html = cards([canvas(), prototype(), link("https://github.com/acme/api/pull/7")])
      assert "lg:hover:border-primary" in tokens(html, "[data-kind=link]")

      for kind <- ~w(canvas prototype link) do
        primary = tokens(html, "[data-kind=#{kind}]") |> Enum.filter(&(&1 =~ "primary"))
        assert Enum.all?(primary, &(&1 == "lg:hover:border-primary")), inspect(primary)
      end
    end

    test "the inline chip pads 4px left, 12px right, 2px vertically" do
      url = "https://github.com/acme/api/issues/42"

      html =
        "see #{url} for details"
        |> ContentRenderer.render_message(
          chips: ChatLinkCard.chips("m1", [link(url, bare: false, display: :chip)])
        )
        |> Phoenix.HTML.safe_to_string()

      classes = tokens(html, "[data-role=link-chip]")
      for t <- ~w(pl-1 pr-3 py-0.5 bg-base-300 border-edge), do: assert(t in classes, t)
      for t <- ~w(pl-0.5 pr-2.5 py-px), do: refute(t in classes, t)
    end
  end

  describe "unfurled outside-link cards (link unfurls stage 4, direction canvas 01a1a945)" do
    @yt %{
      url: "https://www.youtube.com/watch?v=abc123",
      title: "How we rebuilt our deploy pipeline in a weekend",
      description: "A walkthrough of the migration.",
      image_url: "https://i.ytimg.com/vi/abc123/hqdefault.jpg",
      image_width: 480,
      image_height: 360,
      site_name: "YouTube",
      author: "Example Channel",
      provider: "youtube",
      twitter_card: nil,
      media_kind: "video",
      duration_seconds: nil
    }

    defp unfurled(url, unfurl), do: Map.put(link(url), :unfurl, unfurl)
    defp one(html, sel), do: html |> q(sel) |> Enum.count()

    test "a video leads with its image: 180px cap, lazy, no referrer; site and channel line" do
      html = cards([unfurled(@yt.url, @yt)])
      card = "#link-card-m1-0[data-unfurled=true][data-layout=wide]"
      assert one(html, card) == 1

      assert one(
               html,
               card <>
                 " img[data-role=link-card-image][loading=lazy][referrerpolicy=no-referrer][alt='']"
             ) == 1

      assert "max-h-[180px]" in tokens(html, "[data-role=link-card-image]")
      assert "object-cover" in tokens(html, "[data-role=link-card-image]")
      assert "aspect-video" in tokens(html, "[data-role=link-card-media]")

      assert text(html, "[data-role=link-card-site] > .truncate") ==
               "youtube.com · Example Channel"

      assert text(html, "[data-role=link-card-author]") =~ "Example Channel"
      assert text(html, "[data-role=link-card-title]") == @yt.title
      assert "p-3" in tokens(html, "[data-role=link-card-body]")
      refute html =~ "shadow-"
    end

    test "the duration chip only when the provider stated one (POSITIVE CONTROL: Vimeo)" do
      assert one(cards([unfurled(@yt.url, @yt)]), "[data-role=link-card-duration]") == 0

      vimeo = %{@yt | provider: "vimeo", duration_seconds: 724, site_name: "Vimeo"}
      html = cards([unfurled("https://vimeo.com/76979871", vimeo)])
      assert text(html, "[data-role=link-card-duration]") == "12:04"
      assert "font-mono" in tokens(html, "[data-role=link-card-duration]")
      assert "text-[11px]" in tokens(html, "[data-role=link-card-duration]")
      assert ChatLinkCard.format_duration(3723) == "1:02:03"
    end

    test "a wide article image leads; a square image is the 40px tile, not a lead image" do
      article = %{@yt | media_kind: "article", image_width: 1200, image_height: 630, author: nil}
      html = cards([unfurled("https://example.com/posts/calm", article)])
      assert one(html, "[data-layout=wide] [data-role=link-card-image]") == 1
      assert one(html, "[data-role=link-card-author]") == 0

      square = %{article | image_width: 400, image_height: 400}
      html = cards([unfurled("https://example.org/team/profile", square)])
      assert one(html, "[data-unfurled=true][data-layout=tile]") == 1
      assert one(html, "[data-role=link-card-image]") == 0
      assert "size-10" in tokens(html, "[data-role=link-card-tile-image]")
      assert "p-3" in tokens(html, "[data-role=link-card][data-kind=link]")
    end

    test "the site line is the host without www and the author, never the stored site_name" do
      # From the YouTube oEmbed fixture: provider_name "YouTube", channel "Example Channel".
      html = cards([unfurled(@yt.url, @yt)])

      assert text(html, "[data-role=link-card-site] > .truncate") ==
               "youtube.com · Example Channel"

      refute text(html, "[data-role=link-card-site] > .truncate") =~ "YouTube"

      blog = %{@yt | media_kind: "article", site_name: "The GitHub Blog", author: nil}
      html = cards([unfurled("https://github.blog/news/2026/link-cards", blog)])
      assert text(html, "[data-role=link-card-site] > .truncate") == "github.blog"
    end

    test "a GitHub PR with a wide summary_large_image card still takes the tile, with the site mark" do
      gh = %{
        @yt
        | url: "https://github.com/acme/api/pull/91",
          title: "Fix unfurl padding and drop the card glow by octo · Pull Request #91",
          image_url: "https://opengraph.githubassets.com/abc/acme/api/pull/91",
          image_width: 1200,
          image_height: 600,
          twitter_card: "summary_large_image",
          site_name: "GitHub",
          author: nil,
          provider: nil,
          media_kind: "other"
      }

      # The ratio rule alone would make it wide (POSITIVE CONTROL for the host rule).
      assert ChatLinkCard.wide?(gh)

      for url <- [
            "https://github.com/acme/api/pull/91",
            "https://www.github.com/acme/api/pull/91"
          ] do
        html = cards([unfurled(url, gh)])
        assert one(html, "[data-unfurled=true][data-layout=tile]") == 1
        assert one(html, "[data-role=link-card-image]") == 0
        assert one(html, "[data-role=link-card-tile-image]") == 0

        assert one(html, "[data-role=link-card] > [data-role=link-site-tile][data-site=github]") ==
                 1

        assert text(html, "[data-role=link-card-site] > .truncate") == "github.com"
      end
    end

    test "an X post with a 1920x1080 image takes the tile, its image square-cropped" do
      x = %{
        @yt
        | url: "https://x.com/example_dev/status/1854",
          title: "Shipped link previews today.",
          image_url: "https://pbs.example.com/media/wide.jpg",
          image_width: 1920,
          image_height: 1080,
          twitter_card: "summary_large_image",
          site_name: "X (formerly Twitter)",
          author: "Example Dev",
          provider: "x",
          media_kind: "other"
      }

      assert ChatLinkCard.wide?(x)

      for url <- [
            "https://x.com/example_dev/status/1854",
            "https://twitter.com/example_dev/status/1854",
            "https://www.twitter.com/example_dev/status/1854",
            "https://mobile.twitter.com/example_dev/status/1854"
          ] do
        html = cards([unfurled(url, x)])
        assert one(html, "[data-unfurled=true][data-layout=tile]") == 1, url
        assert one(html, "[data-role=link-card-image]") == 0, url
        assert one(html, "[data-role=link-card-tile-image] img.object-cover") == 1, url
      end

      assert text(
               cards([unfurled("https://x.com/example_dev/status/1854", x)]),
               "[data-role=link-card-site]"
             ) ==
               "x.com · Example Dev"
    end

    test "unknown size leads only when the page declared summary_large_image" do
      unknown = %{@yt | media_kind: "other", image_width: nil, image_height: nil}
      assert ChatLinkCard.wide?(unknown) == false
      assert ChatLinkCard.wide?(%{unknown | twitter_card: "summary_large_image"})
      assert ChatLinkCard.wide?(%{unknown | image_url: nil, media_kind: "video"}) == false
    end

    test "without :unfurl the card is today's card, unfurled false, with no skeleton" do
      html = cards([link("https://github.com/acme/api/pull/7")])
      assert one(html, "#link-card-m1-0[data-unfurled=false]") == 1
      assert text(html, "[data-role=link-card-title]") =~ "Pull request #7"
      refute html =~ "animate-pulse"
      refute html =~ "skeleton"
    end

    test "the remove control is only in the author's DOM, outside the card's button" do
      card = unfurled(@yt.url, @yt)
      own = render_component(&ChatLinkCard.link_cards/1, msg_id: "m1", cards: [card], own?: true)
      other = render_component(&ChatLinkCard.link_cards/1, msg_id: "m1", cards: [card])

      assert one(
               own,
               ~s(button[data-role=link-card-remove][aria-label="Remove preview"][phx-click=link_unfurl_hide][phx-value-message_id=m1])
             ) == 1

      assert one(own, "[data-role=link-card] [data-role=link-card-remove]") == 0
      assert one(other, "[data-role=link-card-remove]") == 0
      assert one(other, "[data-role=link-card]") == 1
    end

    test "no card of any kind carries a shadow" do
      html =
        cards([
          canvas(),
          prototype(),
          link("https://example.com/a/b"),
          unfurled(@yt.url, @yt),
          locked()
        ])

      for node <- html |> q("[data-role=link-card]") |> Enum.to_list() do
        [class] = LazyHTML.attribute(node, "class")
        assert class |> String.split() |> Enum.filter(&String.starts_with?(&1, "shadow-")) == []
      end

      assert html |> q("[data-role=link-card]") |> Enum.count() == 5
    end
  end
end
