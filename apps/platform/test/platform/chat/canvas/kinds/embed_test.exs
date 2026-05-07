defmodule Platform.Chat.Canvas.Kinds.EmbedTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Chat.Canvas.Kinds.Embed

  @valid_srcdoc "<!doctype html><html><body><p>hello</p></body></html>"

  describe "validate_props/1" do
    test "accepts a small valid srcdoc with no height" do
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc}) == :ok
    end

    test "accepts a valid srcdoc + valid height" do
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "height" => 600}) == :ok
    end

    test "accepts srcdoc just under 256 KB" do
      # 256 KB - 100 bytes of safe filler
      filler = String.duplicate("a", 256 * 1024 - 100)
      srcdoc = "<!doctype html><body>" <> filler <> "</body>"
      assert byte_size(srcdoc) < 256 * 1024
      assert Embed.validate_props(%{"srcdoc" => srcdoc}) == :ok
    end

    test "rejects srcdoc just over 256 KB" do
      filler = String.duplicate("a", 256 * 1024 + 1)
      assert {:error, reason} = Embed.validate_props(%{"srcdoc" => filler})
      assert reason =~ "256KB"
      assert reason =~ "exceeds"
    end

    test "rejects srcdoc containing <script>" do
      srcdoc = "<!doctype html><body><script>alert(1)</script></body>"
      assert {:error, reason} = Embed.validate_props(%{"srcdoc" => srcdoc})
      assert reason =~ "<script"
      assert reason =~ "may not contain"
    end

    test "rejects srcdoc containing uppercase <SCRIPT> (case-insensitive)" do
      srcdoc = "<!doctype html><body><SCRIPT>alert(1)</SCRIPT></body>"
      assert {:error, reason} = Embed.validate_props(%{"srcdoc" => srcdoc})
      assert reason =~ "<script"
    end

    test "rejects srcdoc containing mixed-case <ScRiPt" do
      srcdoc = "<!doctype html><body><ScRiPt src=evil.js></ScRiPt></body>"
      assert {:error, reason} = Embed.validate_props(%{"srcdoc" => srcdoc})
      assert reason =~ "<script"
    end

    test "rejects height = 50 (below minimum)" do
      assert {:error, reason} =
               Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "height" => 50})

      assert reason =~ "between 100 and 2000"
    end

    test "rejects height = 2500 (above maximum)" do
      assert {:error, reason} =
               Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "height" => 2500})

      assert reason =~ "between 100 and 2000"
    end

    test "accepts height nil (use default 400)" do
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "height" => nil}) == :ok
    end

    test "accepts height at boundaries (100, 2000)" do
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "height" => 100}) == :ok
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "height" => 2000}) == :ok
    end
  end

  describe "render/1" do
    defp render_node(node) do
      assigns = %{node: node}

      ~H"""
      <Embed.render node={@node} />
      """
      |> rendered_to_string()
    end

    test "produces an <iframe> with explicit empty-string sandbox attribute" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc, "height" => 500}
        })

      assert html =~ "<iframe"
      # The critical security contract: sandbox attribute present with empty value.
      assert html =~ ~s|sandbox=""|
      # Must NOT render with a non-empty sandbox token list.
      refute html =~ ~r/sandbox="[^"]+"/
    end

    test "uses the supplied height in the inline style" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc, "height" => 750}
        })

      assert html =~ "height: 750px"
    end

    test "falls back to default height (400) when none supplied" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc}
        })

      assert html =~ "height: 400px"
    end

    test "HEEx-escapes a srcdoc that tries to break out of the attribute" do
      malicious = ~s|"></iframe><img src=x onerror=alert(1)>|

      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => malicious}
        })

      # Single iframe in the rendered output — the malicious chunk did not
      # become a sibling element.
      iframe_count =
        Regex.scan(~r/<iframe\b/, html) |> length()

      assert iframe_count == 1

      # The escape boundary should not have produced a real <img> tag.
      refute html =~ "<img"

      # The malicious quote must be entity-escaped inside the srcdoc attr.
      assert html =~ "&quot;"
    end
  end

  describe "kind metadata" do
    test "name/0 returns \"embed\"" do
      assert Embed.name() == "embed"
    end

    test "children/0 returns :none" do
      assert Embed.children() == :none
    end

    test "schema/0 marks srcdoc as required" do
      schema = Embed.schema()
      assert "srcdoc" in schema["required"]
      assert schema["properties"]["srcdoc"]["type"] == "string"
      assert schema["properties"]["height"]["type"] == "integer"
      assert schema["properties"]["height"]["minimum"] == 100
      assert schema["properties"]["height"]["maximum"] == 2000
    end
  end
end
