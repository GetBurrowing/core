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
end
