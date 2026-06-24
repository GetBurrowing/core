defmodule Platform.Tasks.CanvasAttachmentsTest do
  @moduledoc """
  Stage 2 of task 019ef734 (`task_attach_canvas`): context module on top of
  the `task_canvas_attachments` join table.

  Covers:

    * attach happy path (insert)
    * attach idempotent on `(task_id, canvas_id)` — same id, updated fields
    * detach happy path
    * detach of an absent pair returns `:not_found`
    * list returns rows in `inserted_at` ASC
    * list surfaces a soft-deleted canvas as `canvas: nil`
    * attach against a nonexistent canvas → `:canvas_not_found`
    * attach against a nonexistent task → `:task_not_found`
  """

  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Ecto.UUID
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachment
  alias Platform.Tasks.CanvasAttachments

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  defp create_space(attrs \\ %{}) do
    default = %{name: "CanvasAttachments Space", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: UUID.generate(),
      display_name: "Alice",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_canvas(space, participant, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Test canvas #{System.unique_integer([:positive])}"
        },
        overrides
      )

    {:ok, canvas} = Chat.create_canvas(attrs)
    canvas
  end

  setup do
    {:ok, project} = Tasks.create_project(%{name: "CanvasAttachments Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Attach a canvas"})

    space = create_space()
    participant = create_participant(space.id)

    %{
      project: project,
      task: task,
      space: space,
      participant: participant
    }
  end

  defp attached_by(%{participant: participant}) do
    %{kind: "user", id: participant.id}
  end

  describe "attach_canvas/3" do
    test "inserts a row and returns {:ok, %CanvasAttachment{}}", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, %CanvasAttachment{} = attachment} =
               CanvasAttachments.attach_canvas(ctx.task.id, canvas.id,
                 note: "first take",
                 attached_by: attached_by(ctx)
               )

      assert attachment.task_id == ctx.task.id
      assert attachment.canvas_id == canvas.id
      assert attachment.note == "first take"
      assert attachment.attached_by_kind == "user"
      assert attachment.attached_by_id == ctx.participant.id

      assert Repo.get(CanvasAttachment, attachment.id)
    end

    test "is idempotent on (task_id, canvas_id) — same id, updated note", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, first} =
               CanvasAttachments.attach_canvas(ctx.task.id, canvas.id,
                 note: "first",
                 attached_by: attached_by(ctx)
               )

      other_participant = create_participant(ctx.space.id, %{display_name: "Bob"})

      assert {:ok, second} =
               CanvasAttachments.attach_canvas(ctx.task.id, canvas.id,
                 note: "second",
                 attached_by: %{kind: "user", id: other_participant.id}
               )

      assert second.id == first.id
      assert second.note == "second"
      assert second.attached_by_id == other_participant.id

      # Only one row exists for the pair.
      assert Repo.aggregate(CanvasAttachment, :count) == 1
    end

    test "rejects a nonexistent canvas with :canvas_not_found", ctx do
      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(ctx.task.id, UUID.generate(),
                 attached_by: attached_by(ctx)
               )

      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "rejects a soft-deleted canvas with :canvas_not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {:ok, _} = Chat.delete_canvas(canvas)

      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "rejects a nonexistent task with :task_not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.attach_canvas(UUID.generate(), canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "surfaces a missing :attached_by as a changeset error", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               CanvasAttachments.attach_canvas(ctx.task.id, canvas.id)

      errors = errors_on(changeset)
      assert errors[:attached_by_kind] == ["can't be blank"]
      assert errors[:attached_by_id] == ["can't be blank"]
    end
  end

  describe "detach_canvas/2" do
    test "removes the row and returns :ok", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas.id, attached_by: attached_by(ctx))

      assert :ok = CanvasAttachments.detach_canvas(ctx.task.id, canvas.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "returns {:error, :not_found} when the pair doesn't exist", ctx do
      assert {:error, :not_found} =
               CanvasAttachments.detach_canvas(ctx.task.id, UUID.generate())
    end

    test "only removes the matching pair, not other attachments on the task", ctx do
      canvas_a = create_canvas(ctx.space, ctx.participant)
      canvas_b = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas_a.id, attached_by: attached_by(ctx))

      {:ok, _} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas_b.id, attached_by: attached_by(ctx))

      assert :ok = CanvasAttachments.detach_canvas(ctx.task.id, canvas_a.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 1
    end
  end

  describe "list_task_canvases/1" do
    test "returns rows in inserted_at ASC", ctx do
      canvas_a = create_canvas(ctx.space, ctx.participant, %{"title" => "first"})
      canvas_b = create_canvas(ctx.space, ctx.participant, %{"title" => "second"})
      canvas_c = create_canvas(ctx.space, ctx.participant, %{"title" => "third"})

      {:ok, a} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas_a.id, attached_by: attached_by(ctx))

      # Force ordering — bump inserted_at on the first row backward in time
      # so we can prove the list is ordered by inserted_at, not by id.
      shift_inserted_at(a, -60)

      {:ok, _b} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas_b.id, attached_by: attached_by(ctx))

      {:ok, _c} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas_c.id, attached_by: attached_by(ctx))

      entries = CanvasAttachments.list_task_canvases(ctx.task.id)
      assert length(entries) == 3

      titles = Enum.map(entries, fn %{canvas: c} -> c.title end)
      assert titles == ["first", "second", "third"]
    end

    test "surfaces a soft-deleted canvas as canvas: nil (does not drop the row)", ctx do
      canvas_live = create_canvas(ctx.space, ctx.participant, %{"title" => "alive"})
      canvas_gone = create_canvas(ctx.space, ctx.participant, %{"title" => "doomed"})

      {:ok, _} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas_live.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas_gone.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _} = Chat.delete_canvas(canvas_gone)

      entries = CanvasAttachments.list_task_canvases(ctx.task.id)
      assert length(entries) == 2

      by_canvas_id =
        Map.new(entries, fn %{attachment: a} = entry -> {a.canvas_id, entry} end)

      assert by_canvas_id[canvas_live.id].canvas.title == "alive"
      assert by_canvas_id[canvas_gone.id].canvas == nil

      # The stale attachment row is still there so callers can detach it.
      assert by_canvas_id[canvas_gone.id].attachment.canvas_id == canvas_gone.id
    end

    test "returns [] for a task with no attachments", ctx do
      assert CanvasAttachments.list_task_canvases(ctx.task.id) == []
    end

    test "envelope carries kind from the canvas document's root type", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(ctx.task.id, canvas.id, attached_by: attached_by(ctx))

      [entry] = CanvasAttachments.list_task_canvases(ctx.task.id)
      # Default canvas document has a root `stack` node.
      assert entry.canvas.kind == "stack"
    end
  end

  # Walk an attachment's inserted_at backward by `seconds` so we can prove
  # ordering is by timestamp, not by uuidv7 sequence.
  defp shift_inserted_at(%CanvasAttachment{} = attachment, seconds) do
    shifted = DateTime.add(attachment.inserted_at, seconds, :second)

    {1, _} =
      Repo.update_all(
        from(a in CanvasAttachment, where: a.id == ^attachment.id),
        set: [inserted_at: shifted]
      )

    :ok
  end

  # Phoenix's conventional changeset-error helper.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
