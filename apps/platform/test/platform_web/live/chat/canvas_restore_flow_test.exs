defmodule PlatformWeb.Chat.CanvasRestoreFlowTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  alias Platform.Chat
  alias Platform.Chat.Canvas.{Server, Version, Versions}

  test "existing chat history shares confirmed restore and its optimistic conflict gate", %{
    conn: conn
  } do
    user = create_user!()
    org = Platform.Tenancy.get_org_by_slug!("globex")
    plain_member!(user, org)
    space = channel!(%{org_id: org.id})
    p = add_user!(space.id, user.id)

    doc = %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "text",
        "type" => "text",
        "props" => %{"value" => "Original chat document"}
      }
    }

    {:ok, canvas, _} =
      Chat.create_canvas_with_message(space.id, p.id, %{title: "Shared restore", document: doc})

    {:ok, 2} =
      Server.apply_patches(
        canvas.id,
        [{:set_props, "text", %{"value" => "Current chat document"}}],
        1
      )

    on_exit(fn -> Server.stop(canvas.id) end)
    {:ok, view, _} = live(login(conn, user.id), ~p"/chat/#{space.slug}")
    render_click(view, "canvas_open", %{"canvas-id" => canvas.id})
    render_click(view, "canvas_versions_toggle")
    render_click(view, "canvas_versions_restore_prompt", %{"revision" => "1"})
    render_click(view, "canvas_versions_restore_cancel")
    assert {:ok, %{revision: 2}} = Server.describe(canvas.id)
    render_click(view, "canvas_versions_restore_prompt", %{"revision" => "1"})

    {:ok, 3} =
      Server.apply_patches(
        canvas.id,
        [{:set_props, "text", %{"value" => "Concurrent chat edit"}}],
        2
      )

    render_click(view, "canvas_versions_restore_confirm", %{"revision" => "1"})
    assert {:ok, %{revision: 3}} = Server.describe(canvas.id)
    refute Versions.get(canvas.id, 4)
    render_click(view, "canvas_versions_restore_prompt", %{"revision" => "1"})
    render_click(view, "canvas_versions_restore_confirm", %{"revision" => "1"})
    assert {:ok, %{revision: 4}} = Server.describe(canvas.id)
    assert Version.ops(Versions.get(canvas.id, 4)) == [["restore_from_revision", 1]]
    assert Versions.get(canvas.id, 3).document["root"]["props"]["value"] == "Concurrent chat edit"

    assert Versions.get(canvas.id, 4).document["root"]["props"]["value"] ==
             "Original chat document"
  end
end
