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

  describe "scripts: true (task 01a1316b-677a)" do
    @script_doc "<!doctype html><body><button id=inc>+</button><script>1</script></body>"
    @ref %{
      "prototype_id" => "01a1316b-677a-7001-b686-b8fd67455686",
      "version" => 3,
      "sha256" => "abc"
    }

    defp scripted_node(props) do
      %{"id" => "s1", "type" => "embed", "props" => Map.merge(%{"scripts" => true}, props)}
    end

    test "<script is still rejected when scripts is false or absent" do
      assert {:error, reason} = Embed.validate_props(%{"srcdoc" => @script_doc})
      assert reason =~ "may not contain <script"

      assert {:error, reason} =
               Embed.validate_props(%{"srcdoc" => @script_doc, "scripts" => false})

      assert reason =~ "may not contain <script"
    end

    test "<script is accepted when scripts is true" do
      assert Embed.validate_props(%{"srcdoc" => @script_doc, "scripts" => true}) == :ok
    end

    test "the 256 KB cap still holds when scripts is true" do
      big = "<script>" <> String.duplicate("a", 256 * 1024) <> "</script>"
      assert {:error, reason} = Embed.validate_props(%{"srcdoc" => big, "scripts" => true})
      assert reason =~ "256KB"
    end

    test "scripts must be a boolean and prototype_ref a map" do
      assert {:error, _} = Embed.validate_props(%{"srcdoc" => "<p>x</p>", "scripts" => "yes"})

      assert {:error, _} =
               Embed.validate_props(%{"srcdoc" => "<p>x</p>", "prototype_ref" => "forged"})

      assert Embed.validate_props(%{"srcdoc" => "<p>x</p>", "prototype_ref" => @ref}) == :ok
    end

    # The framed (ref present) render is a LiveComponent that reads the
    # database; its seal assertions live in EmbedScriptedFrameTest below.

    test "a scripted node without a valid ref renders the panel and no iframe" do
      for ref <- [
            nil,
            %{},
            %{"prototype_id" => "nope", "version" => 1},
            Map.put(@ref, "version", 0)
          ] do
        props = %{"srcdoc" => @script_doc}
        props = if ref, do: Map.put(props, "prototype_ref", ref), else: props
        html = render_node(scripted_node(props))

        assert html =~ "Scripted embed unavailable", "ref #{inspect(ref)} framed something"
        refute html =~ "<iframe"
        refute html =~ "srcdoc"
        assert html =~ "bg-base-200"
      end
    end
  end
end

defmodule Platform.Chat.Canvas.Kinds.EmbedScriptedFrameTest do
  @moduledoc """
  A `scripts: true` embed with a ref renders through PrototypeFrame (task
  01a18834 stage 1): the shared version bar, the same seal as the
  `prototype` kind, and one phx-hook per element. Driven through a real
  canvas whose embed was written three times (v1..v3).
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument

  setup do
    prev_sync = Application.get_env(:platform, :canvas_persist_sync)
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, prev_sync) end)

    scratch_storage!("embed_scripted_frame_test")
    set_settings!(%{enabled: true, retention_days: 90})

    n = System.unique_integer([:positive])
    org_id = tenant_org_id("embed-scripted-#{n}")

    {:ok, space} =
      Chat.create_space(%{name: "ES #{n}", slug: "es-#{n}", kind: "channel", org_id: org_id})

    editor = user!("Embed Editor")

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: editor.id,
        display_name: editor.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Scripted",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "children" => [
              %{
                "id" => "s1",
                "type" => "embed",
                "props" => %{"srcdoc" => html(1), "scripts" => true}
              }
            ]
          }
        }
      })

    on_exit(fn -> CanvasServer.stop(canvas.id) end)

    for v <- [2, 3] do
      {:ok, _} =
        Chat.patch_canvas({:user, editor.id}, canvas, [{:set_props, "s1", %{"srcdoc" => html(v)}}])
    end

    node = scripted_node(canvas.id)
    %{"prototype_id" => pid, "version" => 3} = node["props"]["prototype_ref"]

    {:ok, canvas: canvas, node: node, prototype_id: pid, editor: editor}
  end

  defp html(v),
    do:
      ~s(<!doctype html><html><body><p>VERSION=#{v}</p><script>document.title="v#{v}"</script></body></html>)

  defp scripted_node(canvas_id) do
    {:ok, %{document: doc}} = CanvasServer.describe(canvas_id)
    CanvasDocument.get_node(doc, "s1")
  end

  defp mount!(ctx, extra \\ %{}) do
    session = Map.merge(%{"canvas_id" => ctx.canvas.id, "node" => ctx.node}, extra)
    {:ok, view, _html} = live_isolated(build_conn(), __MODULE__.Host, session: session)
    view
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  test "the scripted render is PrototypeFrame's root, keyed embed-canvas-scripted-<node>", ctx do
    view = mount!(ctx)

    assert has_element?(
             view,
             ~s(#embed-canvas-scripted-s1[data-role="prototype-canvas"][phx-hook="PrototypeFullscreen"])
           )

    [stamp] = Enum.to_list(find(render(view), ~s([data-role="prototype-version-stamp"])))
    assert String.trim(LazyHTML.text(stamp)) =~ ~r/\Av3 · \d{1,2} [A-Z][a-z]{2} \d{2}:\d{2}Z\z/
    assert has_element?(view, ~s([data-role="prototype-fullscreen"]))

    assert has_element?(
             view,
             ~s([data-role="prototype-open"][href="/proto/#{ctx.prototype_id}/3/"])
           )

    view |> element(~s([data-role="prototype-version-stamp"])) |> render_click()
    rows = find(render(view), ~s([data-role="prototype-version-row"])) |> Enum.to_list()
    assert Enum.flat_map(rows, &LazyHTML.attribute(&1, "data-version")) == ~w(3 2 1)

    scoped = mount!(ctx, %{"dom_id_scope" => "panel"})

    assert has_element?(
             scoped,
             ~s(#embed-canvas-scripted-s1-panel[data-role="prototype-canvas"])
           )
  end

  test "the seal: /proto src, allow-scripts only, no-referrer, and no srcdoc anywhere", ctx do
    html = render(mount!(ctx))

    [iframe] = Enum.to_list(find(html, "iframe"))
    assert LazyHTML.attribute(iframe, "src") == ["/proto/#{ctx.prototype_id}/3/"]
    assert LazyHTML.attribute(iframe, "sandbox") == ["allow-scripts"]
    assert LazyHTML.attribute(iframe, "referrerpolicy") == ["no-referrer"]
    assert LazyHTML.attribute(iframe, "srcdoc") == []
    assert Enum.to_list(find(html, "[data-srcdoc]")) == []
    assert Enum.to_list(find(html, "[srcdoc]")) == []

    refute html =~ "srcdoc"
    refute html =~ "allow-same-origin"
    refute html =~ "<script"
    refute html =~ "&lt;script"
    refute html =~ "VERSION="
  end

  test "one phx-hook per element, and no hooked element wraps the frame's root", ctx do
    html = render(mount!(ctx))

    # Raw tags: an element with two phx-hook attributes would be collapsed by
    # any parser, so count them in the markup itself.
    for tag <- Regex.scan(~r/<[a-zA-Z][^>]*>/, html) |> List.flatten() do
      assert length(Regex.scan(~r/\sphx-hook=/, tag)) <= 1, "two hooks on one element: #{tag}"
    end

    hooks =
      html
      |> find("[phx-hook]")
      |> Enum.flat_map(&LazyHTML.attribute(&1, "phx-hook"))
      |> Enum.sort()

    assert hooks == Enum.sort(~w(PrototypeFullscreen CanvasRoomBridge EmbedCanvasScale))

    [root] = Enum.to_list(find(html, ~s([data-role="prototype-canvas"])))
    assert LazyHTML.attribute(root, "phx-hook") == ["PrototypeFullscreen"]
    assert Enum.to_list(find(html, ~s([phx-hook] [data-role="prototype-canvas"]))) == []

    [room] = Enum.to_list(find(html, ~s([phx-hook="CanvasRoomBridge"])))
    assert LazyHTML.attribute(room, "data-canvas-id") == [ctx.canvas.id]
    assert LazyHTML.attribute(room, "data-node-id") == ["s1"]
  end

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         canvas_id: session["canvas_id"],
         node: session["node"],
         viewer: session["viewer"],
         dom_id_scope: session["dom_id_scope"]
       )}
    end

    def render(assigns) do
      ~H"""
      <Platform.Chat.Canvas.Renderer.render_node
        node={@node}
        canvas_id={@canvas_id}
        viewer={@viewer}
        dom_id_scope={@dom_id_scope}
      />
      """
    end
  end
end
