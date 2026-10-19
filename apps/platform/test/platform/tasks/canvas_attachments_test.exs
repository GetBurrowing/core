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

  Task 019fb581 stage 3 added the second conjunct — the caller must also be
  able to TOUCH THE TASK — so this file now covers:

    * the task gate on both writes, and its precedence over the canvas checks
    * each of the six `Platform.Tasks.TaskAccess` grants producing an attach
    * a soft-deleted task, which used to attach fine and now reports
      `:task_not_found`
    * denial telemetry, once per denial
    * the ADR-0046 design step left OPEN by a denied attach
  """

  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Ecto.UUID
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachment
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tenancy

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

  # ── Task-gate helpers (task 019fb581 stage 3) ────────────────────────────
  #
  # Both writes now carry TWO independent conjuncts. A test whose subject is
  # the canvas half has to satisfy the task half explicitly, or it stops
  # testing what its name says: every actor would be denied at the first
  # door and the canvas assertions would pass vacuously.
  #
  # `:assignee` is the cheapest of the six grants to mint, and which grant
  # resolved is irrelevant to the canvas half — `TaskAccess` proves the six
  # paths in `task_access_test.exs`, and the block below proves this call
  # site passes each of them through.
  defp grant_task_access(task, {kind, id}) do
    task
    |> Ecto.Changeset.change(assignee_id: id, assignee_type: Atom.to_string(kind))
    |> Repo.update!()
  end

  defp org!(slug), do: Tenancy.get_org_by_slug!(slug)

  defp task_in!(org, attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "CA Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    {:ok, task} =
      Tasks.create_task(Map.merge(%{project_id: project.id, title: "CA Task"}, attrs))

    %{project: project, task: task}
  end

  defp denial_rows(task), do: Audit.list(resource_type: "task", resource_id: task.id)

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

  describe "detach_canvas/3" do
    test "removes the row and returns :ok", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert :ok = CanvasAttachments.detach_canvas(:system, ctx.task.id, canvas.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "returns {:error, :not_found} when the pair doesn't exist", ctx do
      assert {:error, :not_found} =
               CanvasAttachments.detach_canvas(:system, ctx.task.id, UUID.generate())
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

      assert :ok = CanvasAttachments.detach_canvas(:system, ctx.task.id, canvas_a.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 1
    end
  end

  # ── The detach gate (task 019fb581 stage 3) ──────────────────────────────
  #
  # Detach is the second write that mutates the grant graph. It was reachable
  # by any runtime that knew two ids: `execute("task_detach_canvas", …)`
  # ignored its context entirely.
  describe "detach_canvas/3 authorizes the detacher against the task" do
    test "an agent with no binding to the task is denied and the row survives", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas({:agent, UUID.generate()}, ctx.task.id, canvas.id)

      assert Repo.aggregate(CanvasAttachment, :count) == 1
    end

    # The shape the LiveView strip's × button takes: a human who participates
    # in the task's execution space. `PlatformWeb.TasksLive` passes
    # `{:user, current_user_id}` and this is the grant it lands on.
    test "a user participating in the task's execution space may detach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      user = create_user!()
      {:ok, exec_space} = ExecutionSpace.find_or_create(ctx.task.id)
      add_user!(exec_space.id, user.id)

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert :ok = CanvasAttachments.detach_canvas({:user, user.id}, ctx.task.id, canvas.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    # Detach has NO canvas conjunct: it revokes a read grant rather than
    # conferring one. A task-bound agent that could never read this canvas
    # may still unstaple it.
    test "a canvas the detacher cannot read is still detachable from a task they own", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      agent_id = UUID.generate()
      grant_task_access(ctx.task, {:agent, agent_id})

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      # Positive control: this actor genuinely fails the canvas door.
      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas(
                 {:agent, agent_id},
                 ctx.task.id,
                 create_canvas(ctx.space, ctx.participant).id,
                 attached_by: attached_by(ctx)
               )

      assert :ok = CanvasAttachments.detach_canvas({:agent, agent_id}, ctx.task.id, canvas.id)
    end

    test "a nonexistent task reports :task_not_found, not :not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.detach_canvas(:system, UUID.generate(), canvas.id)
    end

    test "a malformed task id reports :task_not_found rather than raising", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.detach_canvas(:system, "higginshigginsxx", canvas.id)
    end

    test "an unidentified actor is denied, not treated as :system", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas(nil, ctx.task.id, canvas.id)

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
  # Every actor in this block holds a task grant, minted by
  # `grant_task_access/2`. Task 019fb581 stage 3 put the task door FIRST, so
  # without it each of these would be denied before the canvas is ever
  # loaded and the block would assert nothing about the canvas at all.
  describe "attach_canvas/4 authorizes the attacher against the canvas" do
    test "a user who participates in the canvas's space may attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      user_id = UUID.generate()
      create_participant(ctx.space.id, %{participant_id: user_id})
      grant_task_access(ctx.task, {:user, user_id})

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

      grant_task_access(ctx.task, {:agent, agent_id})

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "a user with no grant on the canvas is rejected and no row is written", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      user_id = UUID.generate()
      grant_task_access(ctx.task, {:user, user_id})

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas({:user, user_id}, ctx.task.id, canvas.id,
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

      grant_task_access(ctx.task, {:agent, agent_id})

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, ctx.task.id, canvas.id,
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
      user_id = UUID.generate()
      grant_task_access(ctx.task, {:user, user_id})

      # Attributing the attach to a genuine participant does NOT let a
      # non-participant through.
      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas({:user, user_id}, ctx.task.id, canvas.id,
                 attached_by: %{kind: "user", id: ctx.participant.id}
               )
    end

    # Ordering: a canvas that does not exist reports absence, so the denial
    # does not become a richer existence oracle than the read door already is.
    test "a nonexistent canvas reports :canvas_not_found ahead of :canvas_forbidden", ctx do
      user_id = UUID.generate()
      grant_task_access(ctx.task, {:user, user_id})

      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(
                 {:user, user_id},
                 ctx.task.id,
                 UUID.generate(),
                 attached_by: attached_by(ctx)
               )
    end
  end

  # ── The attach gate (task 019fb581 stage 3) ──────────────────────────────
  #
  # The reported hole. Before this stage `attach_canvas/4` checked only that
  # the task EXISTED, so any principal holding a canvas could staple it onto
  # any task in the system — a different project, a different org — and mint
  # the `:task_reader` grant that comes with it for everyone who can read
  # that task.
  describe "attach_canvas/4 authorizes the attacher against the task" do
    setup do
      %{org_a: org!("globex"), org_b: org!("initech")}
    end

    test "an agent with no binding to the task is denied and no row is written", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      agent_id = UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: agent_id})

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert CanvasAttachments.list_task_canvases(ctx.task.id) == []
    end

    # CROSS-PROJECT. The agent is genuinely bound to a task — just not this
    # one. Without the second task the denial could be explained by "this
    # agent has no grants at all" rather than by the grant being scoped.
    test "a binding on one task does not carry to another task in the same org", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      agent_id = UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: agent_id})

      %{task: mine} = task_in!(ctx.org_a, %{assignee_type: "agent", assignee_id: agent_id})
      %{task: theirs} = task_in!(ctx.org_a)

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, mine.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, theirs.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    # CROSS-ORG. Same shape one tenancy boundary out.
    test "a binding in one org does not carry into another org", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      agent_id = UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: agent_id})

      %{task: mine} = task_in!(ctx.org_a, %{assignee_type: "agent", assignee_id: agent_id})
      %{task: theirs} = task_in!(ctx.org_b)

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, mine.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, theirs.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    # All six `TaskAccess` grants reach the insert. `task_access_test.exs`
    # proves the resolver; this proves THIS call site does not filter the
    # resolver's answer down to a subset — e.g. by accepting only `{:ok, _,
    # :system}` and denying the rest.
    test "each of the six grants produces a successful attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      opts = [attached_by: attached_by(ctx)]

      # 1. :system
      %{task: t_system} = task_in!(ctx.org_a)
      assert {:ok, _} = CanvasAttachments.attach_canvas(:system, t_system.id, canvas.id, opts)

      # 2. :assignee
      assignee = UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: assignee})

      %{task: t_assignee} =
        task_in!(ctx.org_a, %{assignee_type: "agent", assignee_id: assignee})

      assert {:ok, _} =
               CanvasAttachments.attach_canvas({:agent, assignee}, t_assignee.id, canvas.id, opts)

      # 3. :phase_assignee
      phase_agent = UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: phase_agent})
      %{task: t_phase} = task_in!(ctx.org_a)

      {:ok, t_phase} =
        Tasks.set_phase_assignees(t_phase, %{
          "review" => %{"assignee_id" => phase_agent, "assignee_type" => "agent"}
        })

      assert {:ok, _} =
               CanvasAttachments.attach_canvas({:agent, phase_agent}, t_phase.id, canvas.id, opts)

      # 4. :space_member — the grant stage 2 mints for the pre-plan designer.
      space_agent = UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: space_agent})
      %{task: t_space} = task_in!(ctx.org_a)
      {:ok, exec_space} = ExecutionSpace.find_or_create(t_space.id)
      add_agent!(exec_space.id, space_agent)

      assert {:ok, _} =
               CanvasAttachments.attach_canvas({:agent, space_agent}, t_space.id, canvas.id, opts)

      # 5. :sponsor
      sponsor = create_user!()
      create_participant(ctx.space.id, %{participant_id: sponsor.id})
      %{task: t_sponsor} = task_in!(ctx.org_a, %{sponsor_user_id: sponsor.id})

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(
                 {:user, sponsor.id},
                 t_sponsor.id,
                 canvas.id,
                 opts
               )

      # 6. :project_member
      member = create_user!()
      plain_member!(member, ctx.org_a)
      create_participant(ctx.space.id, %{participant_id: member.id})
      %{task: t_member} = task_in!(ctx.org_a)

      assert {:ok, _} =
               CanvasAttachments.attach_canvas({:user, member.id}, t_member.id, canvas.id, opts)
    end

    test "an unidentified actor is denied at the task door, not treated as :system", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(nil, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    # ORDERING. The task door runs first, so a caller who may not touch the
    # task learns nothing about the canvas — not even whether it exists.
    test "a task denial precedes the canvas checks", ctx do
      user_id = UUID.generate()

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(
                 {:user, user_id},
                 ctx.task.id,
                 UUID.generate(),
                 attached_by: attached_by(ctx)
               )
    end

    # BEHAVIOUR CHANGE INHERITED FROM STAGE 1, pinned rather than left for a
    # later stage to trip over. `ensure_task_exists/1` did not filter
    # `deleted_at`; `TaskAccess.load/1` does, so this used to attach fine.
    test "a soft-deleted task reports :task_not_found even for a grant holder", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      %{task: task} = task_in!(ctx.org_a)

      task
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :task_not_found} =
               CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "a denied attach writes exactly one audit row naming the tool", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      agent_id = UUID.generate()

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas({:agent, agent_id}, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert [event] = denial_rows(ctx.task)
      assert event.event_type == "platform.tasks.access_denied"
      assert event.actor_type == "agent"
      assert event.actor_id == agent_id
      assert event.resource_id == ctx.task.id
      assert event.metadata["tool"] == "task_attach_canvas"
    end

    test "a denied detach is attributed to task_detach_canvas, not to attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas({:agent, UUID.generate()}, ctx.task.id, canvas.id)

      assert [event] = denial_rows(ctx.task)
      assert event.metadata["tool"] == "task_detach_canvas"
    end

    test "a granted attach emits no denial", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(:system, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert denial_rows(ctx.task) == []
    end
  end

  # ── The design step stays coherent under denial (ADR-0046 member 7) ──────
  #
  # `tap_settle_design_step/1` runs on the `{:ok, %CanvasAttachment{}}` arm
  # only. A denial returns before the insert, so the settler is never
  # reached and the step is left OPEN for its normal deadline to expire it
  # to `failed`. It is not half-settled and not stranded ambiguously.
  describe "a denied attach leaves the pre-plan design step OPEN" do
    test "planning_step is still designing and no design outcome was recorded", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      task =
        ctx.task
        |> Ecto.Changeset.change(planning_step: "designing", planning_step_outcomes: %{})
        |> Repo.update!()

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas({:agent, UUID.generate()}, task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      reloaded = Repo.get!(Platform.Tasks.Task, task.id)
      assert reloaded.planning_step == "designing"
      refute Map.has_key?(reloaded.planning_step_outcomes, "design")
    end

    # Positive control for the assertion above: the SAME setup with a granted
    # actor does settle, so "still designing" cannot pass because the settler
    # is inert in this fixture.
    test "the same attach from a granted actor does settle the step", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      task =
        ctx.task
        |> Ecto.Changeset.change(planning_step: "designing", planning_step_outcomes: %{})
        |> Repo.update!()

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      reloaded = Repo.get!(Platform.Tasks.Task, task.id)
      refute reloaded.planning_step == "designing"
      assert Map.has_key?(reloaded.planning_step_outcomes, "design")
    end
  end
end
