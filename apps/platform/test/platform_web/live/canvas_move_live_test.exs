defmodule PlatformWeb.CanvasMoveLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  alias Platform.{Chat, Tenancy}
  alias Platform.Chat.Canvas.Server
  alias Platform.Files.BrowserActions

  test "mounted standalone reader loses the old body and reauthorizes after move", %{conn: conn} do
    org = Tenancy.get_org_by_slug!("globex")
    mover = create_user!()
    reader = create_user!()
    plain_member!(mover, org)
    plain_member!(reader, org)
    source = channel!(%{kind: "group", org_id: org.id})
    dest = channel!(%{kind: "group", org_id: org.id})
    author = add_user!(source.id, mover.id)
    add_user!(source.id, reader.id)
    add_user!(dest.id, mover.id)

    {:ok, canvas} =
      Chat.create_canvas(%{space_id: source.id, created_by: author.id, title: "Private original"})

    on_exit(fn -> Server.stop(canvas.id) end)
    conn = login(conn, reader.id)
    path = "/canvases/#{canvas.id}"
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "[data-role=canvas-body]")

    assert {:ok, _} =
             BrowserActions.execute(mover, {:canvas, canvas.id}, :move, %{space_id: dest.id})

    assert_redirect(view, path)
    {:ok, denied, _} = live(conn, path)
    assert has_element?(denied, "[data-error=forbidden]")
    refute has_element?(denied, "[data-role=canvas-body]")
  end

  test "space chat drops the moved canvas from streamed messages and local cache", %{conn: conn} do
    org = Tenancy.get_org_by_slug!("globex")
    mover = create_user!()
    reader = create_user!()
    plain_member!(mover, org)
    plain_member!(reader, org)
    source = channel!(%{kind: "group", org_id: org.id})
    dest = channel!(%{kind: "group", org_id: org.id})
    author = add_user!(source.id, mover.id)
    add_user!(source.id, reader.id)
    add_user!(dest.id, mover.id)

    {:ok, canvas, message} =
      Chat.create_canvas_with_message(source.id, author.id, %{title: "Moved live document"})

    on_exit(fn -> Server.stop(canvas.id) end)
    {:ok, view, _} = live(login(conn, reader.id), "/chat/#{source.id}")
    assert has_element?(view, "[data-message-id='#{message.id}'] [data-canvas-id='#{canvas.id}']")

    assert {:ok, _} =
             BrowserActions.execute(mover, {:canvas, canvas.id}, :move, %{space_id: dest.id})

    _ = render(view)
    refute has_element?(view, "[data-message-id='#{message.id}'] [data-canvas-id='#{canvas.id}']")
    Chat.publish_canvas_updated(canvas)
    _ = render(view)
    refute has_element?(view, "[data-message-id='#{message.id}'] [data-canvas-id='#{canvas.id}']")
    assert {:ok, moved} = Platform.Repo.get(Chat.Canvas, canvas.id) |> then(&{:ok, &1})
    state = :sys.get_state(view.pid)
    assert PlatformWeb.ChatLive.CanvasHooks.find(state.socket, moved.id) == nil
    send(view.pid, {:canvas_updated, canvas})
    _ = render(view)
    refute has_element?(view, "[data-message-id='#{message.id}'] [data-canvas-id='#{canvas.id}']")
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.canvases_by_id, canvas.id)
  end

  test "meeting removal clears both picker and active document without choosing a different canvas" do
    canvas = %{id: Ecto.UUID.generate(), space_id: Ecto.UUID.generate()}
    kept = %{id: Ecto.UUID.generate(), space_id: canvas.space_id}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        meeting_canvases: [canvas, kept],
        meeting_canvas: canvas,
        selected_canvas_id: canvas.id
      }
    }

    assert {:noreply, removed} =
             PlatformWeb.MeetingLive.handle_info({:canvas_deleted, canvas}, socket)

    assert removed.assigns.meeting_canvases == [kept]
    assert removed.assigns.meeting_canvas == nil
    assert removed.assigns.selected_canvas_id == nil
  end

  test "a destination reader's deny survives arrival and later lifecycle updates", %{conn: conn} do
    org = Tenancy.get_org_by_slug!("globex")
    mover = create_user!()
    denied = create_user!()
    initially_allowed = create_user!()
    plain_member!(mover, org)
    plain_member!(denied, org)
    plain_member!(initially_allowed, org)
    source = channel!(%{kind: "group", org_id: org.id})
    dest = channel!(%{kind: "group", org_id: org.id})
    author = add_user!(source.id, mover.id)
    add_user!(dest.id, mover.id)
    add_user!(dest.id, denied.id)
    add_user!(dest.id, initially_allowed.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        space_id: source.id,
        created_by: author.id,
        title: "Hidden on arrival"
      })

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: denied,
        permission: "canvas.read",
        resource: canvas
      })

    on_exit(fn -> Server.stop(canvas.id) end)
    {:ok, view, _} = live(login(conn, denied.id), "/chat/#{dest.id}")
    {:ok, allowed_view, _} = live(login(conn, initially_allowed.id), "/chat/#{dest.id}")

    assert {:ok, moved} =
             BrowserActions.execute(mover, {:canvas, canvas.id}, :move, %{space_id: dest.id})

    _ = render(view)
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.canvases_by_id, canvas.id)
    _ = render(allowed_view)
    assert Map.has_key?(:sys.get_state(allowed_view.pid).socket.assigns.canvases_by_id, canvas.id)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: initially_allowed,
        permission: "canvas.read",
        resource: moved
      })

    Chat.publish_canvas_updated(moved)
    _ = render(allowed_view)
    refute Map.has_key?(:sys.get_state(allowed_view.pid).socket.assigns.canvases_by_id, canvas.id)
    _ = render(view)
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.canvases_by_id, canvas.id)

    assert {:ok, _} =
             BrowserActions.execute(mover, {:canvas, canvas.id}, :rename, %{title: "Still hidden"})

    _ = render(view)
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.canvases_by_id, canvas.id)
    {:ok, standalone, _} = live(login(conn, denied.id), "/canvases/#{canvas.id}")
    refute has_element?(standalone, "[data-role=canvas-body]")
    assert has_element?(standalone, "[data-error=not_found]")
  end
end
