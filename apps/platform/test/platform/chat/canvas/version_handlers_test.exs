defmodule Platform.Chat.Canvas.VersionHandlersTest do
  @moduledoc """
  Tests for `canvas.versions` and `canvas.restore` MCP handlers (task 019e0ac0).
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.VersionHandlers

  setup do
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, false) end)

    {:ok, space} =
      Chat.create_space(%{
        name: "VH #{System.unique_integer([:positive])}",
        slug: "vh-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    agent_participant_id = Ecto.UUID.generate()

    {:ok, agent_participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_participant_id,
        display_name: "AgentIn",
        joined_at: DateTime.utc_now()
      })

    %{space: space, agent_id: agent_participant_id, agent_participant: agent_participant}
  end

  defp create_canvas(space_id, participant_id) do
    {:ok, canvas, _msg} =
      Chat.create_canvas_with_message(space_id, participant_id, %{"title" => "Doc"})

    on_exit(fn -> CanvasServer.stop(canvas.id) end)
    canvas
  end

  defp add_text_op(id, value) do
    [
      {:append_child, "root",
       %{
         "id" => id,
         "type" => "text",
         "props" => %{"value" => value},
         "children" => []
       }}
    ]
  end

  describe "canvas.versions" do
    test "returns versions newest-first with required fields", %{
      space: space,
      agent_id: agent_id,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)

      assert {:ok, 2} = CanvasServer.apply_patches(canvas.id, add_text_op("a", "A"), 1)
      assert {:ok, 3} = CanvasServer.apply_patches(canvas.id, add_text_op("b", "B"), 2)

      assert {:ok, %{canvas_id: cid, versions: vs, next_cursor: nil}} =
               VersionHandlers.versions(
                 %{"canvas_id" => canvas.id},
                 %{agent_id: agent_id}
               )

      assert cid == canvas.id
      assert length(vs) == 3

      [v3, v2, v1] = vs
      assert v3.revision == 3
      assert v2.revision == 2
      assert v1.revision == 1

      assert is_binary(v3.written_at)
      assert is_binary(v3.op_summary)
      assert is_map(v3.written_by)
    end

    test "limit + before_revision pagination", %{
      space: space,
      agent_id: agent_id,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)

      Enum.reduce(1..5, 1, fn n, base ->
        {:ok, new_rev} =
          CanvasServer.apply_patches(canvas.id, add_text_op("n#{n}", "v#{n}"), base)

        new_rev
      end)

      # 6 total versions (1 create + 5 patches).
      assert {:ok, %{versions: page1, next_cursor: cursor}} =
               VersionHandlers.versions(
                 %{"canvas_id" => canvas.id, "limit" => 2},
                 %{agent_id: agent_id}
               )

      assert length(page1) == 2
      assert Enum.map(page1, & &1.revision) == [6, 5]
      assert cursor == 5

      assert {:ok, %{versions: page2, next_cursor: cursor2}} =
               VersionHandlers.versions(
                 %{"canvas_id" => canvas.id, "limit" => 2, "before_revision" => cursor},
                 %{agent_id: agent_id}
               )

      assert Enum.map(page2, & &1.revision) == [4, 3]
      assert cursor2 == 3
    end

    test "404 on missing canvas", %{agent_id: agent_id} do
      assert {:error, %{error: "Canvas not found:" <> _, recoverable: false}} =
               VersionHandlers.versions(
                 %{"canvas_id" => Ecto.UUID.generate()},
                 %{agent_id: agent_id}
               )
    end

    test "403 when agent is not in the space", %{
      space: space,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)
      outsider_agent_id = Ecto.UUID.generate()

      assert {:error, %{error: "Access denied" <> _, recoverable: false}} =
               VersionHandlers.versions(
                 %{"canvas_id" => canvas.id},
                 %{agent_id: outsider_agent_id}
               )
    end
  end

  describe "canvas.restore" do
    test "restores historical document, increments revision, marks ops as restore", %{
      space: space,
      agent_id: agent_id,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)

      # 1 (create) → 2 (a) → 3 (b)
      assert {:ok, 2} = CanvasServer.apply_patches(canvas.id, add_text_op("a", "A"), 1)
      assert {:ok, 3} = CanvasServer.apply_patches(canvas.id, add_text_op("b", "B"), 2)

      v1_doc = Chat.get_canvas(canvas.id).document |> Map.get("root")
      assert length(v1_doc["children"]) == 2

      # Restore to v1 (the empty doc).
      assert {:ok, %{revision: 4, restored_from: 1}} =
               VersionHandlers.restore(
                 %{"canvas_id" => canvas.id, "revision" => 1},
                 %{agent_id: agent_id}
               )

      # Live canvas now reflects v1's document (no children).
      reloaded = Chat.get_canvas(canvas.id)
      assert reloaded.document["root"]["children"] in [nil, []]

      # canvas.versions now shows the restore row tagged accordingly.
      assert {:ok, %{versions: vs}} =
               VersionHandlers.versions(
                 %{"canvas_id" => canvas.id, "limit" => 10},
                 %{agent_id: agent_id}
               )

      [v4 | _] = vs
      assert v4.revision == 4
      assert v4.op_summary =~ "restore from revision 1"
    end

    test "404 on non-existent revision", %{
      space: space,
      agent_id: agent_id,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)

      assert {:error, %{error: "Canvas " <> _, recoverable: false}} =
               VersionHandlers.restore(
                 %{"canvas_id" => canvas.id, "revision" => 999},
                 %{agent_id: agent_id}
               )
    end

    test "403 when agent is not in the space", %{
      space: space,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)
      outsider_agent_id = Ecto.UUID.generate()

      assert {:error, %{error: "Access denied" <> _, recoverable: false}} =
               VersionHandlers.restore(
                 %{"canvas_id" => canvas.id, "revision" => 1},
                 %{agent_id: outsider_agent_id}
               )
    end

    # Task 019e2c4b stage 2. The previous `assert_member/2` gate returned `:ok`
    # when `context.agent_id` was nil, on the theory that such a caller must be
    # the in-app LiveView. Nothing enforced that theory here — this handler is
    # only reached from the federation tool surface — and `agent_id` is not
    # required on an `AgentRuntime`, so nil is reachable for an authenticated
    # remote caller. That was a restore-anything bypass.
    test "403 when the caller carries no identity at all", %{
      space: space,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)

      assert {:ok, 2} = CanvasServer.apply_patches(canvas.id, add_text_op("a", "A"), 1)

      assert {:error, %{error: "Access denied" <> _, recoverable: false}} =
               VersionHandlers.restore(%{"canvas_id" => canvas.id, "revision" => 1}, %{})

      # And the document was not rolled back.
      assert {:ok, %{revision: 2}} = CanvasServer.describe(canvas.id)
    end

    test "a participating USER may restore via :user_id", %{
      space: space,
      agent_participant: ap
    } do
      canvas = create_canvas(space.id, ap.id)
      user_id = Ecto.UUID.generate()

      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user_id,
          display_name: "Human",
          joined_at: DateTime.utc_now()
        })

      assert {:ok, 2} = CanvasServer.apply_patches(canvas.id, add_text_op("a", "A"), 1)

      assert {:ok, _payload} =
               VersionHandlers.restore(
                 %{"canvas_id" => canvas.id, "revision" => 1},
                 %{user_id: user_id}
               )
    end

    test "404 for an unknown canvas id, ahead of any access decision" do
      assert {:error, %{error: error, recoverable: false}} =
               VersionHandlers.restore(
                 %{"canvas_id" => Ecto.UUID.generate(), "revision" => 1},
                 %{agent_id: Ecto.UUID.generate()}
               )

      assert error =~ "not found"
    end
  end
end
