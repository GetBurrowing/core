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
