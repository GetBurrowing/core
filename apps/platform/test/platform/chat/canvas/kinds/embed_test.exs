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

    test "accepts width + min_scale (typical mockup case)" do
      assert Embed.validate_props(%{
               "srcdoc" => @valid_srcdoc,
               "width" => 1080,
               "min_scale" => 0.5
             }) == :ok
    end

    test "accepts width at boundaries (320, 2400)" do
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "width" => 320}) == :ok
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "width" => 2400}) == :ok
    end

    test "accepts min_scale at boundaries (0.0, 1.0)" do
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "min_scale" => 0.0}) == :ok
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "min_scale" => 1.0}) == :ok
    end

    test "rejects width = 100 (below 320)" do
      assert {:error, reason} =
               Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "width" => 100})

      assert reason =~ "between 320 and 2400"
    end

    test "rejects width = 3000 (above 2400)" do
      assert {:error, reason} =
               Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "width" => 3000})

      assert reason =~ "between 320 and 2400"
    end

    test "rejects min_scale = 1.5 (above 1.0)" do
      assert {:error, reason} =
               Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "min_scale" => 1.5})

      assert reason =~ "between 0.0 and 1.0"
    end

    test "rejects negative min_scale" do
      assert {:error, reason} =
               Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "min_scale" => -0.1})

      assert reason =~ "between 0.0 and 1.0"
    end

    test "accepts width nil (use default 1080) — backwards compat" do
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "width" => nil}) == :ok
    end

    test "accepts existing nodes without width or min_scale (backwards compat)" do
      # This is the critical backwards-compat case: pre-existing canvases
      # authored before width/min_scale existed must continue to validate.
      assert Embed.validate_props(%{"srcdoc" => @valid_srcdoc, "height" => 500}) == :ok
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

    test "wrapper carries phx-hook and declared-width data attribute" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc, "width" => 1080}
        })

      assert html =~ ~s|phx-hook="EmbedCanvasScale"|
      assert html =~ ~s|data-declared-width="1080"|
    end

    test "wrapper defaults declared-width to 1080 when prop is absent" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc}
        })

      assert html =~ ~s|data-declared-width="1080"|
    end

    test "wrapper carries declared-height attribute" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc, "height" => 800, "width" => 1280}
        })

      assert html =~ ~s|data-declared-height="800"|
      assert html =~ ~s|data-declared-width="1280"|
    end

    test "wrapper omits min-scale value when prop is absent" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc}
        })

      # When min_scale is nil, the attribute either renders empty or is dropped;
      # either way, no concrete numeric value is present.
      refute html =~ ~r/data-min-scale="[0-9]/
    end

    test "wrapper carries min-scale when supplied" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc, "min_scale" => 0.5}
        })

      assert html =~ ~s|data-min-scale="0.5"|
    end

    test "wrapper has the `group` class so hover states cascade to expand button" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc}
        })

      assert html =~ ~r/class="[^"]*\bgroup\b[^"]*"/
    end

    test "renders an expand button with data-embed-expand attribute" do
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc}
        })

      assert html =~ ~s|data-embed-expand|
      assert html =~ ~s|aria-label="Expand canvas to full screen"|
    end

    test "iframe width matches declared design width (not 100%)" do
      # Critical for transform: scale() — the iframe must render at its
      # declared natural width, then be visually scaled by the hook.
      html =
        render_node(%{
          "id" => "embed-1",
          "type" => "embed",
          "props" => %{"srcdoc" => @valid_srcdoc, "width" => 1280}
        })

      assert html =~ "width: 1280px"
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

    test "schema/0 advertises width and min_scale props with correct ranges" do
      schema = Embed.schema()
      width = schema["properties"]["width"]
      min_scale = schema["properties"]["min_scale"]

      assert width["type"] == "integer"
      assert width["minimum"] == 320
      assert width["maximum"] == 2400

      assert min_scale["type"] == "number"
      assert min_scale["minimum"] == 0.0
      assert min_scale["maximum"] == 1.0

      # Neither is required — both are optional opt-ins.
      refute "width" in schema["required"]
      refute "min_scale" in schema["required"]
    end
  end
end
