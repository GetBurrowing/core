defmodule PlatformWeb.Components.Canvases.PrototypeFrameTest do
  @moduledoc """
  The rendered `prototype` canvas node (task 01a1316b-4e46 stage 2): the
  sandboxed iframe, the version stamp, the pinned chip, the removed-version
  panel and org scoping. Driven through `render_component/2`, which runs the
  LiveComponent's real `update/2` against the database.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Chat.Canvas.Kinds.Prototype, as: Kind
  alias Platform.Prototypes
  alias Platform.Prototypes.Version
  alias Platform.Repo
  alias PlatformWeb.Components.Canvases.PrototypeFrame

  setup do
    scratch_storage!("prototype_frame_test")
    set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})

    org_id = tenant_org_id("proto-frame-#{System.unique_integer([:positive])}")
    agent = agent!()

    {:ok, %{prototype: p}} =
      Prototypes.publish(
        agent_publisher(agent),
        %{org_id: org_id, name: "Checkout flow"},
        {:files, bundle_files("v1")}
      )

    {:ok, %{prototype: p}} =
      Prototypes.publish(agent_publisher(agent), %{prototype: p}, {:files, bundle_files("v2")})

    canvas = canvas_in_org!(org_id)

    {:ok, prototype: p, org_id: org_id, canvas: canvas, agent: agent}
  end

  defp canvas_in_org!(org_id) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Proto #{n}",
        slug: "proto-#{n}",
        kind: "channel",
        org_id: org_id
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{"space_id" => space.id, "created_by" => author.id, "title" => "P"})

    canvas
  end

  defp proto_node(prototype_id, extra \\ %{}),
    do: %{
      "id" => "proto",
      "type" => "prototype",
      "props" => Map.merge(%{"prototype_id" => prototype_id}, extra)
    }

  defp render_frame(node, canvas_id, viewer \\ nil) do
    render_component(PrototypeFrame,
      id: "frame-test",
      node: node,
      canvas_id: canvas_id,
      viewer: viewer
    )
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  describe "room bridge (task 01a1316b-84fa stage 2)" do
    test "the iframe sits inside a CanvasRoomBridge element carrying the room key", ctx do
      html = render_frame(proto_node(ctx.prototype.id), ctx.canvas.id)

      [bridge] = Enum.to_list(find(html, ~s([phx-hook="CanvasRoomBridge"])))
      assert LazyHTML.attribute(bridge, "data-canvas-id") == [ctx.canvas.id]
      assert LazyHTML.attribute(bridge, "data-node-id") == ["proto"]
      assert [id] = LazyHTML.attribute(bridge, "id")
      assert id =~ "frame-test"
      assert [_iframe] = Enum.to_list(LazyHTML.query(bridge, "iframe"))
    end

    test "with no canvas id there is no bridge", ctx do
      html = render_frame(proto_node(ctx.prototype.id), nil)
      assert Enum.to_list(find(html, ~s([phx-hook="CanvasRoomBridge"]))) == []
    end
  end

  describe "fullscreen" do
    test "toggling keeps the bridge element and iframe, adds fullscreen classes and a close control",
         ctx do
      {:ok, view, html} =
        live_isolated(build_conn(), __MODULE__.Host,
          session: %{"canvas_id" => ctx.canvas.id, "node" => proto_node(ctx.prototype.id)}
        )

      bridge = ~s([phx-hook="CanvasRoomBridge"])

      assert has_element?(
               view,
               ~s([data-role="prototype-canvas"][phx-hook="PrototypeFullscreen"])
             )

      [before_id] = find(html, bridge) |> LazyHTML.attribute("id")
      refute has_element?(view, ~s([data-role="prototype-fullscreen-close"]))
      refute has_element?(view, ~s([data-role="prototype-canvas"].fixed))
      assert has_element?(view, ~s([data-role="prototype-open"]))

      view |> element(~s([data-role="prototype-fullscreen"])) |> render_click()

      assert has_element?(view, ~s([data-role="prototype-canvas"].fixed.inset-0.z-50.h-dvh))
      assert has_element?(view, ~s([data-role="prototype-fullscreen-close"]))
      assert has_element?(view, ~s([data-role="prototype-open"]))
      [after_id] = find(render(view), bridge) |> LazyHTML.attribute("id")
      assert after_id == before_id
      assert has_element?(view, "#{bridge} iframe")

      view |> element(~s([data-role="prototype-fullscreen-close"])) |> render_click()
      refute has_element?(view, ~s([data-role="prototype-canvas"].fixed))
      [back_id] = find(render(view), bridge) |> LazyHTML.attribute("id")
      assert back_id == before_id
    end

    test "Escape closes it", ctx do
      {:ok, view, _} =
        live_isolated(build_conn(), __MODULE__.Host,
          session: %{"canvas_id" => ctx.canvas.id, "node" => proto_node(ctx.prototype.id)}
        )

      view |> element(~s([data-role="prototype-fullscreen"])) |> render_click()
      assert has_element?(view, ~s([phx-window-keydown="fullscreen"][phx-key="Escape"]))

      view
      |> element(~s([phx-window-keydown="fullscreen"]))
      |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, ~s([data-role="prototype-canvas"].fixed))
    end
  end

  describe "latest version" do
    test "frames the latest version with sandbox allow-scripts and nothing else", ctx do
      html = render_frame(proto_node(ctx.prototype.id), ctx.canvas.id)

      [iframe] = Enum.to_list(find(html, "iframe"))
      assert LazyHTML.attribute(iframe, "sandbox") == ["allow-scripts"]
      assert LazyHTML.attribute(iframe, "src") == ["/proto/#{ctx.prototype.id}/2/"]
      refute html =~ "allow-same-origin"
      refute html =~ "allow-popups"
      refute html =~ "allow-top-navigation"
      refute html =~ "allow-forms"
    end

    test "the bar shows the title and the mono stamp, and no pinned chip", ctx do
      html = render_frame(proto_node(ctx.prototype.id), ctx.canvas.id)

      [stamp] = Enum.to_list(find(html, ~s([data-role="prototype-version-stamp"])))
      assert String.trim(LazyHTML.text(stamp)) =~ ~r/\Av2 · \d{1,2} [A-Z][a-z]{2} \d{2}:\d{2}Z\z/
      assert stamp |> LazyHTML.attribute("class") |> hd() =~ "font-mono"
      assert stamp |> LazyHTML.attribute("class") |> hd() =~ "shrink-0"
      assert html =~ "Checkout flow"
      assert Enum.to_list(find(html, ~s([data-role="prototype-pinned-chip"]))) == []

      assert Enum.to_list(
               find(html, ~s([data-role="prototype-open"][href="/proto/#{ctx.prototype.id}/2/"]))
             ) != []
    end

    test "the kind's height and width props reach the frame, embed defaults otherwise", ctx do
      html = render_frame(proto_node(ctx.prototype.id), ctx.canvas.id)
      [frame] = Enum.to_list(find(html, ~s([data-role="prototype-frame"])))
      assert LazyHTML.attribute(frame, "data-declared-width") == ["#{Kind.default_width()}"]
      assert LazyHTML.attribute(frame, "data-declared-height") == ["#{Kind.default_height()}"]

      html =
        render_frame(
          proto_node(ctx.prototype.id, %{"height" => 600, "width" => 800}),
          ctx.canvas.id
        )

      [frame] = Enum.to_list(find(html, ~s([data-role="prototype-frame"])))
      assert LazyHTML.attribute(frame, "data-declared-width") == ["800"]
      assert LazyHTML.attribute(frame, "data-declared-height") == ["600"]
    end
  end

  describe "pinned version" do
    test "an older pinned version shows the info chip and frames that version", ctx do
      html = render_frame(proto_node(ctx.prototype.id, %{"version" => 1}), ctx.canvas.id)

      [chip] = Enum.to_list(find(html, ~s([data-role="prototype-pinned-chip"])))
      assert LazyHTML.text(chip) =~ "v1 pinned · latest v2"
      assert chip |> LazyHTML.attribute("class") |> hd() =~ "chip-info"
      [iframe] = Enum.to_list(find(html, "iframe"))
      assert LazyHTML.attribute(iframe, "src") == ["/proto/#{ctx.prototype.id}/1/"]
    end

    test "the pinned bar sizes by its OWN width, not the viewport's", ctx do
      # Member 2's review: at a 1280px viewport the viewport `sm:` rule showed
      # the full chip inside a ~330px inline preview, 426px of content, and
      # Open and the menu left the card. Every width rule in the bar must be
      # a container query on the bar.
      html = render_frame(proto_node(ctx.prototype.id, %{"version" => 1}), ctx.canvas.id)

      [bar] = Enum.to_list(find(html, ~s([data-role="prototype-bar"])))
      bar_class = bar |> LazyHTML.attribute("class") |> hd()
      assert bar_class |> String.split() |> Enum.member?("@container")

      bar_html = LazyHTML.to_html(bar)

      refute bar_html =~ ~r/(?<![@\w-])(sm|md|lg|xl):/,
             "a viewport breakpoint in the bar: #{bar_html}"

      # Below the bar's @sm (24rem) the chip is not shown at all ...
      [chip] = Enum.to_list(find(html, ~s([data-role="prototype-pinned-chip"])))
      chip_classes = chip |> LazyHTML.attribute("class") |> hd() |> String.split()
      assert "hidden" in chip_classes
      assert "@sm:inline-flex" in chip_classes
      assert "whitespace-nowrap" in chip_classes

      # ... from @sm it reads "latest v2", and only from @lg the full text.
      [long] = Enum.to_list(find(html, ~s([data-role="prototype-pinned-chip"] > span)))
      assert LazyHTML.text(long) =~ "v1 pinned"

      assert long |> LazyHTML.attribute("class") |> hd() |> String.split() == [
               "hidden",
               "@lg:inline"
             ]

      # With the chip hidden, the stamp carries the info colour and says
      # "pinned" to a screen reader, so the exception never disappears. The
      # stamp itself still never truncates.
      [stamp] = Enum.to_list(find(html, ~s([data-role="prototype-version-stamp"])))
      stamp_classes = stamp |> LazyHTML.attribute("class") |> hd() |> String.split()
      assert "text-info" in stamp_classes
      assert "@sm:text-neutral" in stamp_classes
      assert "whitespace-nowrap" in stamp_classes and "shrink-0" in stamp_classes
      refute "truncate" in stamp_classes

      assert LazyHTML.attribute(stamp, "aria-label") == [
               "Version 1, pinned (latest is v2), show versions"
             ]

      # The title is the one thing that gives way; Open and the menu never do.
      [title] = Enum.to_list(find(html, ~s([data-role="prototype-title"])))
      assert title |> LazyHTML.attribute("class") |> hd() =~ "min-w-0 flex-1 truncate"

      for role <- ~w(prototype-open prototype-menu-button) do
        [el] = Enum.to_list(find(html, ~s([data-role="#{role}"])))

        assert el
               |> LazyHTML.attribute("class")
               |> hd()
               |> String.split()
               |> Enum.member?("shrink-0")
      end
    end

    test "pinning the latest version is not an exception: no chip", ctx do
      html = render_frame(proto_node(ctx.prototype.id, %{"version" => 2}), ctx.canvas.id)
      assert Enum.to_list(find(html, ~s([data-role="prototype-pinned-chip"]))) == []
      assert Enum.to_list(find(html, "iframe")) != []
    end
  end

  describe "removed version" do
    test "a retention-removed version renders the panel, not an iframe", ctx do
      {1, _} =
        Repo.update_all(
          from(v in Version, where: v.prototype_id == ^ctx.prototype.id and v.version == 1),
          set: [removed_at: DateTime.utc_now()]
        )

      html = render_frame(proto_node(ctx.prototype.id, %{"version" => 1}), ctx.canvas.id)

      assert Enum.to_list(find(html, "iframe")) == []
      [panel] = Enum.to_list(find(html, ~s([data-role="prototype-removed"])))
      assert LazyHTML.text(panel) =~ "This version was removed after 90 days. Latest is v2."
      assert LazyHTML.text(panel) =~ "View v2"
    end
  end

  describe "org scoping" do
    test "a canvas in another org's space does not frame the prototype", ctx do
      other_org = tenant_org_id("proto-frame-other-#{System.unique_integer([:positive])}")
      other_canvas = canvas_in_org!(other_org)

      html = render_frame(proto_node(ctx.prototype.id), other_canvas.id)

      assert Enum.to_list(find(html, "iframe")) == []
      refute html =~ ctx.prototype.id
      refute html =~ "Checkout flow"
      assert html =~ "This prototype is not available."

      # Positive control: the same node in the prototype's own org frames it.
      assert Enum.to_list(
               find(render_frame(proto_node(ctx.prototype.id), ctx.canvas.id), "iframe")
             ) !=
               []
    end

    test "an unknown id and a missing canvas render the same neutral panel", ctx do
      unknown = render_frame(proto_node(Ecto.UUID.generate()), ctx.canvas.id)
      no_canvas = render_frame(proto_node(ctx.prototype.id), nil)

      for html <- [unknown, no_canvas] do
        assert html =~ "This prototype is not available."
        assert Enum.to_list(find(html, "iframe")) == []
      end
    end
  end

  describe "version list and pin" do
    test "the stamp opens the version list; Pin appears only with a viewer", ctx do
      {:ok, view, _html} =
        live_isolated(build_conn(), __MODULE__.Host,
          session: %{"canvas_id" => ctx.canvas.id, "node" => proto_node(ctx.prototype.id)}
        )

      view |> element(~s([data-role="prototype-version-stamp"])) |> render_click()
      assert has_element?(view, ~s([data-role="prototype-version-row"][data-version="1"]))
      assert has_element?(view, ~s([data-role="prototype-version-row"][data-version="2"]))
      assert render(view) =~ "Proto Agent"
      refute has_element?(view, ~s([data-role="prototype-pin"]))

      view |> element(~s([data-role="prototype-menu-button"])) |> render_click()
      assert render(view) =~ "Sealed: no network, no Suite access"
    end
  end

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok, assign(socket, canvas_id: session["canvas_id"], node: session["node"])}
    end

    def render(assigns) do
      ~H"""
      <Platform.Chat.Canvas.Renderer.render_node node={@node} canvas_id={@canvas_id} />
      """
    end
  end
end
