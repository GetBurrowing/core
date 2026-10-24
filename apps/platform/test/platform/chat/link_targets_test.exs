defmodule Platform.Chat.LinkTargetsTest do
  @moduledoc """
  Redesign rung 13 stage 1: the one link parser. Hosts are built from
  `PlatformWeb.Endpoint` config; foreign hosts use example.com / example.test.
  """
  use ExUnit.Case, async: true

  alias Platform.Chat.ContentRenderer
  alias Platform.Chat.LinkTargets

  defp origin do
    uri = PlatformWeb.Endpoint.struct_url()
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp own_host, do: PlatformWeb.Endpoint.struct_url().host

  defp targets(content), do: LinkTargets.from_content(content)

  defp kinds(content), do: content |> targets() |> Enum.map(& &1.kind)

  describe "kinds" do
    test "a same-host canvas URL is :canvas with its id" do
      id = Ecto.UUID.generate()

      assert [%{kind: :canvas, id: ^id, version: nil}] = targets("#{origin()}/canvases/#{id}")
      assert [%{kind: :canvas, id: ^id}] = targets("#{origin()}/canvases/#{id}/")
    end

    test "a same-host prototype URL is :prototype with its version, numbered or latest" do
      id = Ecto.UUID.generate()

      assert [%{kind: :prototype, id: ^id, version: 3}] = targets("#{origin()}/proto/#{id}/3/")

      assert [%{kind: :prototype, id: ^id, version: :latest}] =
               targets("#{origin()}/proto/#{id}/latest/screens/a.html")

      assert [%{kind: :link}] = targets("#{origin()}/proto/#{id}/0/")
    end

    test "a same-host attachment URL and a bare relative path are :attachment" do
      id = Ecto.UUID.generate()

      assert [%{kind: :attachment, id: ^id}] = targets("#{origin()}/chat/attachments/#{id}")
      assert [%{kind: :attachment, id: ^id}] = targets("/chat/attachments/#{id}")
      assert [%{kind: :attachment, id: ^id}] = targets("[clip](/chat/attachments/#{id})")
    end

    test "image and video extensions, any host, case-insensitive" do
      assert kinds("https://example.com/a/photo.PNG") == [:image]
      assert kinds("https://example.com/a.jpeg https://example.com/b.avif") == [:image, :image]
      assert kinds("https://example.com/clip.mp4") == [:video]
      assert kinds("https://example.com/clip.MOV") == [:video]
      assert kinds("#{origin()}/images/logo.webp") == [:image]
    end

    test "any other http(s) URL is :link" do
      assert [%{kind: :link, url: "https://example.com/pricing/plans"}] =
               targets("https://example.com/pricing/plans")

      assert kinds("#{origin()}/chat/some-space") == [:link]
    end
  end

  describe "host matching is exact" do
    test "a foreign host's /canvases/<uuid> is a :link, never a :canvas" do
      id = Ecto.UUID.generate()
      assert kinds("https://example.test/canvases/#{id}") == [:link]
    end

    test "a look-alike suffix host is not this install" do
      id = Ecto.UUID.generate()
      assert kinds("https://#{own_host()}.evil.example/canvases/#{id}") == [:link]
      assert kinds("https://evil-#{own_host()}/canvases/#{id}") == [:link]
    end

    test "the userinfo trick is not this install" do
      id = Ecto.UUID.generate()
      assert kinds("https://#{own_host()}@evil.example/canvases/#{id}") == [:link]

      uri = PlatformWeb.Endpoint.struct_url()

      refute LinkTargets.in_app?(
               "#{uri.scheme}://#{uri.host}:#{uri.port}@evil.example/canvases/#{id}"
             )
    end

    test "a lenient-parse port (host:port.evil) is not this install" do
      id = Ecto.UUID.generate()
      uri = PlatformWeb.Endpoint.struct_url()

      refute LinkTargets.in_app?("http://#{uri.host}:#{uri.port}.evil.example/canvases/#{id}")
    end

    test "a different port on the same host is not this install" do
      id = Ecto.UUID.generate()
      uri = PlatformWeb.Endpoint.struct_url()

      assert kinds("#{uri.scheme}://#{uri.host}:#{uri.port + 1}/canvases/#{id}") == [:link]
    end

    test "host comparison ignores case" do
      id = Ecto.UUID.generate()
      uri = PlatformWeb.Endpoint.struct_url()
      url = "#{uri.scheme}://#{String.upcase(uri.host)}:#{uri.port}/canvases/#{id}"

      assert kinds(url) == [:canvas]
    end
  end

  describe "dangerous schemes" do
    test "javascript: and data: hrefs are neutralized before classification and give no target" do
      html =
        ContentRenderer.sanitized_html(
          "[click](javascript:alert(1)) and [x](data:text/html,<script>alert(1)</script>)"
        )

      assert html =~ "#blocked:"
      assert LinkTargets.extract(html) == []
      assert LinkTargets.classify("#blocked:alert(1)") == nil
      assert LinkTargets.classify("javascript:alert(1)") == nil
      assert LinkTargets.classify("data:text/html,x") == nil
    end
  end

  describe "bare line vs mid-sentence" do
    test "a link alone on its line is bare; one inside a sentence is not" do
      bare = "intro text\nhttps://example.com/pricing/plans"
      mid = "see https://example.com/pricing/plans for details"

      assert [%{bare_line?: true}] = targets(bare)
      assert [%{bare_line?: false}] = targets(mid)
      assert [%{bare_line?: true}] = targets("<https://example.com/a>")
    end

    test "strip_bare_lines drops only the bare occurrence and keeps the sender's words" do
      url = "https://example.com/pricing/plans"

      html = ContentRenderer.sanitized_html("Have a look\n#{url}")
      stripped = LinkTargets.strip_bare_lines(html, [url], [])
      assert stripped =~ "Have a look"
      refute stripped =~ url

      html = ContentRenderer.sanitized_html("see #{url} for details")
      assert LinkTargets.strip_bare_lines(html, [url], []) == html

      assert LinkTargets.strip_bare_lines(ContentRenderer.sanitized_html(url), [url], []) == ""
    end
  end

  describe "dedupe and cap" do
    test "the same target twice gives one target, whatever the spelling" do
      id = Ecto.UUID.generate()

      content =
        "#{origin()}/canvases/#{id}\nand again #{origin()}/canvases/#{id}/ " <>
          "and [here](/canvases/#{id})"

      assert [%{kind: :canvas}] = targets(content)
      assert length(targets("https://example.com/a https://EXAMPLE.com/a")) == 1
    end

    test "at most 3 card targets per message; the rest stay text links" do
      content = Enum.map_join(1..5, "\n", &"https://example.com/page-#{&1}")
      ts = targets(content)

      assert length(ts) == LinkTargets.card_cap()
      assert Enum.map(ts, & &1.url) == Enum.map(1..3, &"https://example.com/page-#{&1}")

      rendered = content |> ContentRenderer.render_message() |> Phoenix.HTML.safe_to_string()
      assert rendered =~ ~s(href="https://example.com/page-5")
    end

    test "attachment links are not counted against the card cap" do
      ids = for _ <- 1..4, do: Ecto.UUID.generate()
      content = Enum.map_join(ids, "\n", &"/chat/attachments/#{&1}")
      assert length(targets(content <> "\nhttps://example.com/a")) == 5
    end
  end

  test "links inside code are not targets" do
    id = Ecto.UUID.generate()
    assert targets("`/chat/attachments/#{id}`") == []
    assert targets("```\n/chat/attachments/#{id}\n```") == []
  end
end
