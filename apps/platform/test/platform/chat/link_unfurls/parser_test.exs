defmodule Platform.Chat.LinkUnfurls.ParserTest do
  @moduledoc """
  Link unfurls stage 2 (task 01a1a944): the page and oEmbed parsers on
  fixture bodies (test/support/fixtures/link_unfurls). No network.
  """
  use ExUnit.Case, async: true

  alias Platform.Chat.LinkUnfurls.{OEmbed, Parser}

  @dir Path.expand("../../../support/fixtures/link_unfurls", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@dir, name))
  defp parse(name, url \\ "https://example.com/posts/calm"), do: Parser.parse(fixture(name), url)

  test "an OpenGraph article: OG wins over title and meta description; wide image dims" do
    p = parse("og_article.html")
    assert p.title == "Designing calm notifications & quiet apps"

    assert p.description ==
             "Why most apps over-notify, and a three-tier model that respects attention."

    assert p.image_url == "https://cdn.example.com/hero/calm.jpg"
    assert {p.image_width, p.image_height} == {1200, 630}
    assert p.site_name == "Example Journal"
    assert p.og_type == "article"
    assert p.author == "A. Writer"
    assert p.duration_seconds == nil
  end

  test "a Twitter-card-only page" do
    p = parse("twitter_only.html")
    assert p.title == "Shipped link previews today"
    assert p.description == "Every card now tells you what you get."
    assert p.image_url == "https://img.example.org/card.png"
    assert p.twitter_card == "summary_large_image"
  end

  test "only <title> and meta description: both used, whitespace collapsed" do
    p = parse("title_only.html")
    assert p.title == "Office orders | Example Catering"
    assert p.description == "Order lunch for the whole office."
    assert p.image_url == nil
  end

  test "a page with no metadata parses to all nil" do
    assert parse("no_metadata.html") == Parser.empty()
  end

  test "a relative og:image is resolved against the final page url" do
    p = parse("relative_image.html", "https://example.com/blog/2026/post.html")
    assert p.image_url == "https://example.com/blog/img/cover.png"
  end

  test "a data: og:image and a javascript: twitter:image are both dropped" do
    p = parse("data_image.html")
    # Positive control: the same page's title was read.
    assert p.title == "Data image page"
    assert p.image_url == nil
  end

  test "a stated ISO-8601 duration is read; none is invented" do
    assert parse("video_page.html").duration_seconds == 12 * 60 + 4
    assert Parser.iso8601_duration("PT1H2M3S") == 3723
    assert Parser.iso8601_duration("garbage") == nil
  end

  test "title and description are capped at 300 and 500" do
    long = String.duplicate("a", 900)

    html =
      ~s(<html><head><meta property="og:title" content="#{long}"><meta property="og:description" content="#{long}"></head></html>)

    p = Parser.parse(html, "https://example.com/")
    assert String.length(p.title) == 300
    assert String.length(p.description) == 500
  end

  test "garbage input never raises" do
    assert Parser.parse(<<0, 255, 1>>, "https://example.com/") == Parser.empty()
  end

  describe "oEmbed" do
    test "the fixed provider table; nothing else gets an endpoint" do
      assert {"youtube", "https://www.youtube.com/oembed?format=json&url=" <> _} =
               OEmbed.endpoint("https://www.youtube.com/watch?v=abc123")

      assert {"youtube", _} = OEmbed.endpoint("https://youtu.be/abc123")

      assert {"vimeo", "https://vimeo.com/api/oembed.json?url=" <> _} =
               OEmbed.endpoint("https://vimeo.com/76979871")

      assert {"x", "https://publish.twitter.com/oembed?url=" <> _} =
               OEmbed.endpoint("https://x.com/a/status/1")

      assert OEmbed.endpoint("https://github.com/acme/api/pull/7") == nil
      assert OEmbed.endpoint("https://example.com/watch?v=1") == nil
    end

    test "YouTube: title, channel, 480x360 thumbnail, video, no duration" do
      o = OEmbed.parse(fixture("youtube_oembed.json"), "youtube")
      assert o.title == "How we rebuilt our deploy pipeline in a weekend"
      assert o.author == "Example Channel"
      assert o.thumbnail_url == "https://i.ytimg.com/vi/abc123/hqdefault.jpg"
      assert {o.thumbnail_width, o.thumbnail_height} == {480, 360}
      assert o.type == "video"
      assert o.duration_seconds == nil
    end

    test "Vimeo gives a duration" do
      assert OEmbed.parse(fixture("vimeo_oembed.json"), "vimeo").duration_seconds == 724
    end

    test "a relative or non-http thumbnail is dropped; non-JSON is nil" do
      assert OEmbed.parse(~s({"thumbnail_url":"/x.jpg"}), "x").thumbnail_url == nil

      assert OEmbed.parse(~s({"thumbnail_url":"data:image/png;base64,AA"}), "x").thumbnail_url ==
               nil

      assert OEmbed.parse("<html>", "x") == nil
    end
  end
end
