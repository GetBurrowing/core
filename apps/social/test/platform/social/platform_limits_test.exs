defmodule Platform.Social.PlatformLimitsTest do
  @moduledoc "Per-platform limits, the fold, the X thread split and the deterministic flags (task 01a16c4f)."
  use ExUnit.Case, async: true

  alias Platform.Social.PlatformLimits

  @connected %{approval_mode: "approve_first", status: "connected"}

  defp keys(platform, post), do: platform |> PlatformLimits.flags(post) |> Enum.map(& &1.key)

  describe "limits" do
    test "every account platform has limits with a label, max body and fold" do
      for platform <- Platform.Social.Account.platforms() do
        limits = PlatformLimits.get(platform)
        assert is_binary(limits.label)
        assert is_integer(limits.max_body)
        assert is_integer(limits.fold)
      end
    end

    test "the documented numbers" do
      assert PlatformLimits.get("linkedin").max_body == 3000
      assert PlatformLimits.get("x").max_body == 280
      assert PlatformLimits.get("instagram").max_body == 2200
      assert PlatformLimits.get("tiktok").max_body == 2200
      assert PlatformLimits.get("youtube").max_title == 100
      assert PlatformLimits.get("instagram").hashtag_cap == 30
      assert PlatformLimits.get("linkedin").fold == 210
      assert PlatformLimits.get("instagram").fold == 125
      assert PlatformLimits.get("youtube").fold == 100
      assert PlatformLimits.get("tiktok").fold == 80
      refute PlatformLimits.get("instagram").links_clickable?
      assert PlatformLimits.get("linkedin").links_clickable?
    end
  end

  describe "count/2" do
    test "X counts a URL as 23 and an emoji as 2" do
      assert PlatformLimits.count("x", "see https://example.com/a/very/long/path/indeed") ==
               4 + 23

      assert PlatformLimits.count("x", "hi 👋") == 5
      assert PlatformLimits.count("linkedin", "hi 👋") == 4
    end
  end

  describe "fold/2" do
    test "cuts at the platform's fold count, never past it" do
      for platform <- ~w(linkedin instagram youtube tiktok) do
        fold = PlatformLimits.get(platform).fold
        body = String.duplicate("abcd ", 200)

        {visible, true} = PlatformLimits.fold(platform, body)
        assert String.length(visible) <= fold
        assert String.length(visible) >= fold - 20

        exact = String.duplicate("a", fold)
        assert {^exact, false} = PlatformLimits.fold(platform, exact)
        assert {_, true} = PlatformLimits.fold(platform, exact <> "a")
      end
    end

    test "cuts at the platform's line count" do
      assert {"one\ntwo\nthree", true} = PlatformLimits.fold("linkedin", "one\ntwo\nthree\nfour")
      assert {"one\ntwo", true} = PlatformLimits.fold("instagram", "one\ntwo\nthree")
    end

    test "backs off to a word boundary" do
      body = String.duplicate("x", 200) <> " " <> String.duplicate("y", 50)
      {visible, true} = PlatformLimits.fold("linkedin", body)
      assert visible == String.duplicate("x", 200)
    end
  end

  describe "thread/1" do
    test "a body within 280 is one unnumbered post" do
      assert [%{text: "hello", total: 1}] = PlatformLimits.thread("hello")
    end

    test "a 600-character body becomes 3 numbered posts, each within 280" do
      body = (1..100 |> Enum.map_join(" ", fn _ -> "words" end)) <> "."
      assert String.length(body) == 600

      posts = PlatformLimits.thread(body)
      assert length(posts) == 3

      for {post, i} <- Enum.with_index(posts, 1) do
        assert String.ends_with?(post.text, " #{i}/3")
        assert post.count <= 280
      end

      assert posts |> Enum.map_join(" ", &String.replace(&1.text, ~r/ \d+\/3$/, "")) == body
    end

    test "prefers to end a post at a sentence" do
      sentence = "This sentence is exactly about fifty characters ok."
      body = Enum.map_join(1..8, " ", fn _ -> sentence end)
      [first | _] = PlatformLimits.thread(body)
      assert first.text =~ ~r/ok\. 1\/\d$/
    end

    test "a word longer than a post is cut" do
      posts = PlatformLimits.thread(String.duplicate("a", 600))
      assert Enum.all?(posts, &(&1.count <= 280))
      assert length(posts) == 3
    end
  end

  describe "flags/2" do
    test "a clean post has no flags" do
      assert keys("linkedin", %{body: "hi", account: @connected}) == []
    end

    test "over the limit, with the count" do
      [flag] = PlatformLimits.flags("linkedin", %{body: String.duplicate("a", 3012)})
      assert flag.key == "over_limit"
      assert flag.text =~ "3,012 / 3,000"
    end

    test "X thread needs N posts instead of over_limit" do
      body = 1..100 |> Enum.map_join(" ", fn _ -> "words" end)

      assert [%{key: "thread_needed", text: "X thread needs 3 posts"}] =
               PlatformLimits.flags("x", %{body: body})
    end

    test "image or video without alt text" do
      media = [
        %{content_type: "image/png", alt: ""},
        %{content_type: "image/png", alt: "A chart"},
        %{content_type: "video/mp4", duration_s: 10}
      ]

      texts =
        "linkedin"
        |> PlatformLimits.flags(%{media: media})
        |> Enum.filter(&(&1.key == "missing_alt"))
        |> Enum.map(& &1.text)

      assert texts == ["1 image without alt text", "1 video without alt text"]
    end

    test "a link on Instagram, in the body or the link field" do
      assert "link_not_clickable" in keys("instagram", %{body: "go to https://example.com"})
      assert "link_not_clickable" in keys("instagram", %{link_url: "https://example.com"})
      refute "link_not_clickable" in keys("linkedin", %{body: "go to https://example.com"})
    end

    test "missing YouTube title, and a title over 100" do
      video = [%{content_type: "video/mp4", alt: "clip"}]
      assert "missing_title" in keys("youtube", %{media: video})
      assert "missing_title" in keys("youtube", %{media: video, title: "  "})

      assert "title_over_limit" in keys("youtube", %{
               media: video,
               title: String.duplicate("t", 101)
             })

      assert keys("youtube", %{media: video, title: "Fine", account: @connected}) == []
    end

    test "account disconnected and draft_only" do
      assert "account_disconnected" in keys("x", %{account: %{status: "reauth_needed"}})
      assert "account_disconnected" in keys("x", %{account: %{status: nil}})

      [flag] = PlatformLimits.flags("x", %{account: %{@connected | approval_mode: "draft_only"}})
      assert flag.key == "posts_by_hand"
      assert flag.text =~ "You post this yourself"
    end

    test "too many hashtags" do
      body = Enum.map_join(1..31, " ", &"#tag#{&1}")
      assert "too_many_hashtags" in keys("instagram", %{body: body})
      refute "too_many_hashtags" in keys("instagram", %{body: "#one #two"})
    end

    test "media rules come from MediaRules, one flag each" do
      assert [%{key: "media_rule", text: "TikTok needs media" <> _}] =
               PlatformLimits.flags("tiktok", %{body: "hi"})
    end

    test "string keys work too" do
      assert "missing_title" in keys("youtube", %{
               "media" => [%{"content_type" => "video/mp4", "alt" => "x"}]
             })
    end

    test "no flag is a score" do
      all =
        for platform <- PlatformLimits.platforms(),
            flag <- PlatformLimits.flags(platform, %{body: String.duplicate("a ", 2000)}),
            do: flag.text

      refute Enum.any?(all, &(&1 =~ ~r/score|viral|quality|\d+%/i))
    end
  end
end
