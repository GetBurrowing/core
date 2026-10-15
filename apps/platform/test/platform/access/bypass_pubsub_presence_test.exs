defmodule Platform.Access.BypassPubsubPresenceTest do
  use Platform.DataCase, async: false

  alias Phoenix.LiveView.Socket
  alias Platform.Access.{Grants, Scope}
  alias Platform.Chat
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Tasks
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.CanvasHooks

  setup do
    World.external_world()
  end

  test "a deny removes an internal viewer's presence subscription candidate", ctx do
    scope = Scope.for_user(ctx.int)

    assert ChatLive.presence_subscribe_space_ids([ctx.a, ctx.b], ctx.int.id, scope) ==
             [ctx.a.id, ctx.b.id]

    assert {:ok, _} =
             Grants.deny(%{principal: ctx.int, permission: "chat.read", resource: ctx.a})

    scope = Scope.for_user(ctx.int)
    assert ChatLive.presence_subscribe_space_ids([ctx.a, ctx.b], ctx.int.id, scope) == [ctx.b.id]
  end

  test "canvas search and find hide a denied canvas while retaining a sibling", ctx do
    {:ok, denied} =
      Chat.create_canvas(%{
        "space_id" => ctx.a.id,
        "created_by" => ctx.p_a_int.id,
        "title" => "ZQX-BYPASS-CANVAS"
      })

    {:ok, sibling} =
      Chat.create_canvas(%{
        "space_id" => ctx.a.id,
        "created_by" => ctx.p_a_int.id,
        "title" => "ZQX-BYPASS-CANVAS sibling"
      })

    scope = Scope.for_user(ctx.int)

    socket = %Socket{
      assigns: %{__changed__: %{}, access_scope: scope, canvases: [denied, sibling]}
    }

    ids =
      Chat.search_canvases([ctx.a.id], "ZQX-BYPASS-CANVAS", access_scope: scope)
      |> Enum.map(& &1.canvas.id)
      |> MapSet.new()

    assert ids == MapSet.new([sibling.id, denied.id])
    assert CanvasHooks.find(socket, denied.id).id == denied.id

    assert {:ok, _} =
             Grants.deny(%{principal: ctx.int, permission: "canvas.read", resource: denied})

    scope = Scope.for_user(ctx.int)
    socket = %Socket{socket | assigns: %{socket.assigns | access_scope: scope}}

    assert Enum.map(
             Chat.search_canvases([ctx.a.id], "ZQX-BYPASS-CANVAS", access_scope: scope),
             & &1.canvas.id
           ) == [sibling.id]

    assert CanvasHooks.find(socket, denied.id) == nil
    assert CanvasHooks.find(socket, sibling.id).id == sibling.id
  end

  test "the Tasks badge count drops an assigned task in a denied project", ctx do
    {:ok, project} = Tasks.create_project(%{name: "Presence badge Q", org_id: ctx.org_a.id})

    {:ok, _task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "ZQX-BYPASS-BOARD",
        status: "in_progress",
        assignee_id: ctx.int.id,
        assignee_type: "user"
      })

    assert Tasks.count_in_progress_for_user(ctx.int.id) == 1

    assert {:ok, _} =
             Grants.deny(%{principal: ctx.int, permission: "tasks.read", resource: project})

    assert Tasks.count_in_progress_for_user(ctx.int.id) == 0
  end
end
