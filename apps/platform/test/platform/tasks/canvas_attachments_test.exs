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

  describe "attach_canvas/4" do
    test "inserts a row and returns {:ok, %CanvasAttachment{}}", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, %CanvasAttachment{} = attachment} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
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
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
                 note: "first",
                 attached_by: attached_by(ctx)
               )

      other_participant = create_participant(ctx.space.id, %{display_name: "Bob"})

      assert {:ok, second} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
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
               CanvasAttachments.attach_canvas(:system, ctx.task.id, UUID.generate(),
                 attached_by: attached_by(ctx)
               )

      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "rejects a soft-deleted canvas with :canvas_not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {:ok, _} = Chat.delete_canvas(canvas)

      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "rejects a nonexistent task with :task_not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.attach_canvas(:system, UUID.generate(), canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "surfaces a missing :attached_by as a changeset error", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id)

      errors = errors_on(changeset)
      assert errors[:attached_by_kind] == ["can't be blank"]
      assert errors[:attached_by_id] == ["can't be blank"]
    end
  end

  # ADR-0046 member 7 stage 4 — the success path now taps
  # `Platform.Design.PreplanStep.settle/2`. These are the async-safe half of
  # that guard set: DB state only, no `Application` env. The raising-settler
  # case needs a module-level env override and so lives in the `async: false`
  # `Platform.Design.PreplanStepTest` instead, alongside the rest of the design
  # step's guards.
  describe "attach_canvas/4 — the ADR-0046 design-step hook" do
    test "settles an open design step and returns the attachment unchanged", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {:ok, designing} = Tasks.set_planning_step(ctx.task, :designing)
      assert designing.planning_step == "designing"

      assert {:ok, %CanvasAttachment{canvas_id: attached_canvas_id}} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
                 note: "design direction",
                 attached_by: attached_by(ctx)
               )

      assert attached_canvas_id == canvas.id

      reloaded = Repo.get!(Platform.Tasks.Task, ctx.task.id)
      assert reloaded.planning_step == "planning"
      assert reloaded.planning_step_outcomes["design"]["outcome"] == "complete"
      assert reloaded.planning_step_outcomes["design"]["canvas_id"] == canvas.id
    end

    # Paired control for the assertion above: an attachment on a task that is
    # NOT designing must leave the planning fields exactly as they were, so the
    # hook cannot be a blanket writer.
    test "is inert on a task with no open design step", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      reloaded = Repo.get!(Platform.Tasks.Task, ctx.task.id)
      assert reloaded.planning_step == "planning"
      assert reloaded.planning_step_outcomes == %{}
    end
  end

  describe "detach_canvas/2" do
    test "removes the row and returns :ok", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

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
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas_a.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas_b.id,
          attached_by: attached_by(ctx)
        )

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
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas_a.id,
          attached_by: attached_by(ctx)
        )

      # Force ordering — bump inserted_at on the first row backward in time
      # so we can prove the list is ordered by inserted_at, not by id.
      shift_inserted_at(a, -60)

      {:ok, _b} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas_b.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _c} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas_c.id,
          attached_by: attached_by(ctx)
        )

      entries = CanvasAttachments.list_task_canvases(ctx.task.id)
      assert length(entries) == 3

      titles = Enum.map(entries, fn %{canvas: c} -> c.title end)
      assert titles == ["first", "second", "third"]
    end

    test "surfaces a soft-deleted canvas as canvas: nil (does not drop the row)", ctx do
      canvas_live = create_canvas(ctx.space, ctx.participant, %{"title" => "alive"})
      canvas_gone = create_canvas(ctx.space, ctx.participant, %{"title" => "doomed"})

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas_live.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas_gone.id,
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
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

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

  # ── Reverse lookup (task 019e2c4b stage 1) ───────────────────────────────
  # `Platform.Chat.CanvasAccess` rides on this to resolve the `:task_reader`
  # grant, so the `task: nil` degradation is load-bearing rather than
  # cosmetic: a grant must not outlive the task that conferred it.
  describe "list_canvas_tasks/1" do
    test "returns the tasks a canvas is attached to, inserted_at ASC", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, other_task} = Tasks.create_task(%{project_id: ctx.project.id, title: "Second task"})

      {:ok, first} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      {:ok, second} =
        CanvasAttachments.attach_canvas(:system, other_task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      :ok = shift_inserted_at(first, -60)

      assert [entry_a, entry_b] = CanvasAttachments.list_canvas_tasks(canvas.id)
      assert entry_a.attachment.id == first.id
      assert entry_b.attachment.id == second.id

      assert entry_a.task == %{
               id: ctx.task.id,
               title: ctx.task.title,
               status: ctx.task.status,
               project_id: ctx.project.id
             }
    end

    test "surfaces a soft-deleted task as task: nil", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, attachment} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _deleted} = Tasks.soft_delete_task(ctx.task)

      assert [%{attachment: %CanvasAttachment{id: id}, task: nil}] =
               CanvasAttachments.list_canvas_tasks(canvas.id)

      assert id == attachment.id
    end

    test "returns [] for an unattached, unknown or malformed canvas id", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert CanvasAttachments.list_canvas_tasks(canvas.id) == []
      assert CanvasAttachments.list_canvas_tasks(UUID.generate()) == []
      assert CanvasAttachments.list_canvas_tasks("higginshigginsxx") == []
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  # The 16-character case is the load-bearing one: `Ecto.UUID.cast/1` accepts
  # any 16-byte binary, so a test built from "higgins" alone is green against
  # the bug these guards fix.
  describe "UUID boundary: attach_canvas/4 ids are raw MCP tool arguments" do
    test "a malformed task id reports :task_not_found rather than raising", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.attach_canvas(:system, "higginshigginsxx", canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "a malformed canvas id reports :canvas_not_found rather than raising", ctx do
      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, "higginshigginsxx",
                 attached_by: attached_by(ctx)
               )
    end
  end

  # ── Attacher authorization (task 019e2c4b stage 2) ───────────────────────
  #
  # `Platform.Chat.CanvasAccess`'s `:task_reader` grant reads: you may read a
  # canvas if it is attached to a task in an org you belong to. So an
  # unauthorized attach is a self-service grant — staple a stranger's canvas
  # onto a task in your own org and your whole org can read it. Attaching
  # therefore requires already holding a read grant on the canvas.
  describe "attach_canvas/4 authorizes the attacher against the canvas" do
    test "a user who participates in the canvas's space may attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      user_id = UUID.generate()
      create_participant(ctx.space.id, %{participant_id: user_id})

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas({:user, user_id}, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "an agent that participates in the canvas's space may attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      agent_id = UUID.generate()

      create_participant(ctx.space.id, %{
        participant_type: "agent",
        participant_id: agent_id
      })

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "a user with no grant on the canvas is rejected and no row is written", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas({:user, UUID.generate()}, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert CanvasAttachments.list_task_canvases(ctx.task.id) == []
    end

    test "an agent outside the canvas's space is rejected", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      other_space = create_space()
      agent_id = UUID.generate()

      create_participant(other_space.id, %{
        participant_type: "agent",
        participant_id: agent_id
      })

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "an unidentified actor is rejected, not treated as :system", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas(nil, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "the :system actor is unaffected by the gate", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    # Attribution is caller-supplied metadata; the actor is who is asking.
    # They legitimately differ — `DesignTaskDirection` attaches as `:system`
    # while attributing to the responsible designer — so attribution must
    # never be readable as authorization.
    test "attribution is not the authorization subject", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      # Attributing the attach to a genuine participant does NOT let a
      # non-participant through.
      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas({:user, UUID.generate()}, ctx.task.id, canvas.id,
                 attached_by: %{kind: "user", id: ctx.participant.id}
               )
    end

    # Ordering: a canvas that does not exist reports absence, so the denial
    # does not become a richer existence oracle than the read door already is.
    test "a nonexistent canvas reports :canvas_not_found ahead of :canvas_forbidden", ctx do
      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(
                 {:user, UUID.generate()},
                 ctx.task.id,
                 UUID.generate(),
                 attached_by: attached_by(ctx)
               )
    end
  end
end
