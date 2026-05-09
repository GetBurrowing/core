defmodule Platform.Chat.Canvas.VersionWriteHookTest do
  @moduledoc """
  Integration: every successful canvas mutation writes a `canvas_versions`
  row in the same path; rejected mutations write nothing (task 019e0ac0,
  stage 2).
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Version
  alias Platform.Chat.Canvas.Versions
  alias Platform.Repo

  setup do
    # Run persistence synchronously so test asserts don't race the async
    # Task.Supervisor write the server normally schedules.
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, false) end)

    {:ok, space} =
      Chat.create_space(%{
        name: "VersionHook #{System.unique_integer([:positive])}",
        slug: "vhook-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Hook Author",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  defp count_versions(canvas_id) do
    import Ecto.Query

    Repo.aggregate(from(v in Version, where: v.canvas_id == ^canvas_id), :count)
  end

  describe "create_canvas writes initial version" do
    test "create_canvas/1 produces a v1 row with ops=nil", %{space: s, participant: p} do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Vc1"
        })

      assert count_versions(canvas.id) == 1

      [v1] = Versions.list_for_canvas(canvas.id)
      assert v1.revision == 1
      assert Version.ops(v1) == nil
      assert is_map(v1.document)
      assert is_map(v1.written_by)
    end

    test "create_canvas_with_message/3 produces a v1 row with caller attribution",
         %{space: s, participant: p} do
      {:ok, canvas, _message} =
        Chat.create_canvas_with_message(s.id, p.id, %{"title" => "Vc2"})

      assert count_versions(canvas.id) == 1
      [v1] = Versions.list_for_canvas(canvas.id)
      assert v1.written_by["display_name"] == p.display_name
      assert v1.written_by["type"] in ["user", "agent"]
    end
  end

  describe "patch_canvas writes a row per successful patch" do
    setup %{space: s, participant: p} do
      {:ok, canvas, _msg} = Chat.create_canvas_with_message(s.id, p.id, %{"title" => "P"})
      on_exit(fn -> CanvasServer.stop(canvas.id) end)
      %{canvas: canvas}
    end

    test "3 successful patches → 4 total versions, document matches", %{canvas: canvas} do
      assert count_versions(canvas.id) == 1

      ops_for = fn n ->
        [
          {:append_child, "root",
           %{
             "id" => "t-#{n}",
             "type" => "text",
             "props" => %{"value" => "step #{n}"},
             "children" => []
           }}
        ]
      end

      assert {:ok, 2} = CanvasServer.apply_patches(canvas.id, ops_for.(1), 1)
      assert {:ok, 3} = CanvasServer.apply_patches(canvas.id, ops_for.(2), 2)
      assert {:ok, 4} = CanvasServer.apply_patches(canvas.id, ops_for.(3), 3)

      assert count_versions(canvas.id) == 4

      versions = Versions.list_for_canvas(canvas.id)
      assert Enum.map(versions, & &1.revision) == [4, 3, 2, 1]

      v4 = Versions.get(canvas.id, 4)
      ops = Version.ops(v4)
      assert is_list(ops)
      assert match?([["append_child", "root", _]], ops)

      # Document on v4 reflects the post-patch state — three text children.
      children = v4.document["root"]["children"]
      assert length(children) == 3
      assert Enum.map(children, & &1["id"]) == ["t-1", "t-2", "t-3"]
    end

    test "rejected patch (target_deleted) writes ZERO version rows", %{canvas: canvas} do
      assert count_versions(canvas.id) == 1

      # Target a node that doesn't exist — server rejects with target_deleted.
      bad_op = [{:set_props, "no-such-node", %{"value" => "x"}}]

      assert {:conflict, %{reason: :target_deleted}} =
               CanvasServer.apply_patches(canvas.id, bad_op, 1)

      assert count_versions(canvas.id) == 1
    end
  end
end
