defmodule Platform.Chat.Canvas.PatchPathAttributionTest do
  @moduledoc """
  Task 019fed8d stage 2 — a `canvas_patch` performed by an agent must record
  that agent on the resulting `canvas_versions` row.

  The defect this pins: `ToolHandlers.patch/2` called the 3-arity
  `apply_patches`, which forwards an empty attribution map, which
  `attribution_from_fields/1` turns into `%{"type" => "unknown"}` — while the
  create and restore paths both passed a real identity. On the canvas that
  surfaced it, revision 1 (create) carried its author and revision 2 (patch)
  did not, six minutes apart in the same session.

  **These tests must exercise the PATCH path.** A test that asserts attribution
  on `canvas_create` passes against the defect and always did; that is why the
  gap survived a suite with existing attribution coverage.

  Persistence is forced synchronous via `:canvas_persist_sync`. The version row
  is normally written by an async `Task.Supervisor` job in
  `Canvas.Server.do_persist`, so a test that read the row immediately would see
  no row at all — indistinguishable from the bug it is meant to catch.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.ToolHandlers
  alias Platform.Chat.Canvas.Versions

  setup do
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, false) end)

    {:ok, space} =
      Chat.create_space(%{
        name: "Patch Attribution #{System.unique_integer([:positive])}",
        slug: "patchattr-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    agent_id = Ecto.UUID.generate()

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_id,
        display_name: "Patching Agent",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Attribution subject"
      })

    on_exit(fn -> CanvasServer.stop(canvas.id) end)

    %{space: space, participant: participant, agent_id: agent_id, canvas: canvas}
  end

  defp append_op(label) do
    [
      [
        "append_child",
        "root",
        %{
          "id" => "n-#{label}-#{System.unique_integer([:positive])}",
          "type" => "text",
          "props" => %{"value" => "patched #{label}"},
          "children" => []
        }
      ]
    ]
  end

  defp written_by(canvas_id, revision) do
    case Versions.get(canvas_id, revision) do
      nil ->
        flunk(
          "no canvas_versions row for revision #{revision} of #{canvas_id}. " <>
            "Persistence is meant to be synchronous under :canvas_persist_sync — " <>
            "an absent row here is a missing write, not a slow one."
        )

      version ->
        version.written_by
    end
  end

  describe "canvas_patch by an agent" do
    test "records the calling agent on the version row it produces", ctx do
      %{canvas: canvas, participant: participant, agent_id: agent_id} = ctx

      assert {:ok, %{revision: revision}} =
               ToolHandlers.patch(
                 %{
                   "canvas_id" => canvas.id,
                   "base_revision" => 1,
                   "operations" => append_op("agent")
                 },
                 %{agent_id: agent_id}
               )

      attribution = written_by(canvas.id, revision)

      # Exact equality throughout. A substring or `=~` assertion on a name
      # cannot distinguish the right value from a longer wrong one.
      assert attribution["type"] == "agent"
      assert attribution["slug"] == agent_id
      assert attribution["display_name"] == participant.display_name
      assert attribution["id"] == participant.id
    end

    test "the same document mutated through apply_patches/3 still records unknown", ctx do
      # NEGATIVE CONTROL, and the reason the assertion above is not true by
      # construction: the 3-arity entry point is deliberately retained (other
      # callers and tests depend on it), so an attribution-less write is still
      # reachable and still records `unknown`. If this ever goes green with
      # "agent", the test above stopped discriminating and is proving nothing.
      %{canvas: canvas} = ctx

      ops = [
        {:append_child, "root",
         %{
           "id" => "control-#{System.unique_integer([:positive])}",
           "type" => "text",
           "props" => %{"value" => "unattributed"},
           "children" => []
         }}
      ]

      assert {:ok, revision} = CanvasServer.apply_patches(canvas.id, ops, 1)

      assert written_by(canvas.id, revision) == %{"type" => "unknown"}
    end
  end

  describe "identity-less writes are system, not unknown" do
    test "Chat.patch_canvas/3 with a :system actor records system", ctx do
      # `unknown` and `system` render differently downstream, so a write we
      # chose not to attribute must not be recorded the same way as one whose
      # author we failed to resolve. This is the posture the triage callers
      # were changed to state explicitly.
      %{canvas: canvas} = ctx

      ops = [
        {:append_child, "root",
         %{
           "id" => "sys-#{System.unique_integer([:positive])}",
           "type" => "text",
           "props" => %{"value" => "system write"},
           "children" => []
         }}
      ]

      assert {:ok, _canvas} = Chat.patch_canvas(:system, canvas, ops)

      [latest | _] = Versions.list_for_canvas(canvas.id)

      # Assert the type slot, not the whole map: the write path normalizes
      # through `attribution_from_fields/1`, which fills `id` and
      # `display_name` with nil. The claim under test is which of the two
      # identity-less values got recorded, and those two differ only here.
      assert latest.written_by["type"] == "system"
      refute latest.written_by["type"] == "unknown"
    end
  end
end
