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
  able to act on THE TASK — and task 01a1559a stage 1 made that conjunct
  `tasks.write` through `Platform.Access.task_target/3`, with a
  `%Platform.Access.Scope{}` as every function's first argument. This file
  covers:

    * the task gate on both writes, and its precedence over the canvas checks
    * a same-org runtime holding `tasks.write` that is bound to nothing on
      the task attaching; a user holding `tasks.write` attaching
    * a cross-org (fenced) runtime, a runtime without `tasks.write` and a
      nil scope all refused, and the fenced runtime's federated envelope
      equal to a random UUID's
    * a soft-deleted task reporting `:task_not_found`
    * `tasks.read` for the list gate
    * attach and detach transitioning nothing on an in-flight task
    * denial telemetry, once per denial
    * the ADR-0046 design step left OPEN by a denied attach
  """

  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures
  import Platform.RuntimeProfileFixtures, only: [runtime!: 3]
  import Platform.TenancyFixtures, only: [tenant_org_id: 1]

  alias Ecto.UUID
  alias Platform.Access.Scope
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachment
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Federation.ToolArguments

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  # Spaces sit in the `globex` org, where the setup task lives. Since task
  # 01a1559a the canvas conjunct is read with the caller's Scope as
  # `:access_scope`, and a canvas outside a fenced caller's org fence reads as
  # not found, so an org-less space would make every fenced caller's canvas
  # check answer `:canvas_not_found` rather than exercise the grant.
  defp create_space(attrs \\ %{}) do
    default = %{
      name: "CanvasAttachments Space",
      slug: unique_slug(),
      kind: "channel",
      org_id: tenant_org_id("globex")
    }

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
    org = Repo.get!(Platform.Tenancy.Org, tenant_org_id("globex"))

    {:ok, project} =
      Tasks.create_project(%{name: "CanvasAttachments Project", org_id: org.id})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Attach a canvas"})

    space = create_space()
    participant = create_participant(space.id)

    %{
      org: org,
      project: project,
      task: task,
      space: space,
      participant: participant
    }
  end

  defp attached_by(%{participant: participant}) do
    %{kind: "user", id: participant.id}
  end

  # ── Task-gate helpers (task 01a1559a stage 1) ────────────────────────────
  #
  # Both writes carry TWO independent conjuncts: `tasks.write` on the task
  # (`Platform.Access.task_target/3`) and, for attach, a read of the canvas.
  # A test whose subject is the canvas half has to satisfy the task half
  # explicitly, or every caller is denied at the first door and the canvas
  # assertions pass vacuously.
  #
  # The callers are real Scopes: a user's (`Scope.for_user/1`) or an agent
  # runtime's (`Scope.for_runtime/1`), whose fence is its OWNER's org
  # membership. `globex` and `initech` are non-root tenant orgs, so an owner
  # who belongs to one of them only is fenced to it.

  # The `task` bundle carries `tasks.read` and `tasks.write`; the default
  # profile carries neither.
  @task_profile AgentRuntime.default_tool_profile() ++ ~w(task)

  defp org!(slug), do: Repo.get!(Platform.Tenancy.Org, tenant_org_id(slug))

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

  defp member!(org) do
    user = create_user!()
    plain_member!(user, org)
    user
  end

  defp user_scope(user), do: Scope.for_user(user)

  # A runtime owned by a fresh member of `org`, carrying `profile`. Returns
  # `{runtime, scope}`; `runtime.agent_id` names a real agent row.
  defp runtime_in!(org, profile \\ @task_profile) do
    owner = member!(org)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "ca-agent-#{System.unique_integer([:positive])}",
        name: "CA Agent",
        status: "active"
      })
      |> Repo.insert()

    runtime = runtime!(owner.id, profile, %{agent_id: agent.id})
    {runtime, Scope.for_runtime(runtime)}
  end

  # The agent behind `runtime` may read canvases in `space`.
  defp agent_reads!(space, runtime) do
    create_participant(space.id, %{participant_type: "agent", participant_id: runtime.agent_id})
  end

  defp denial_rows(task), do: Audit.list(resource_type: "task", resource_id: task.id)

  describe "attach_canvas/4" do
    test "inserts a row and returns {:ok, %CanvasAttachment{}}", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, %CanvasAttachment{} = attachment} =
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
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
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
                 note: "first",
                 attached_by: attached_by(ctx)
               )

      other_participant = create_participant(ctx.space.id, %{display_name: "Bob"})

      assert {:ok, second} =
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
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
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, UUID.generate(),
                 attached_by: attached_by(ctx)
               )

      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "rejects a soft-deleted canvas with :canvas_not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {:ok, _} = Chat.delete_canvas(canvas)

      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "rejects a nonexistent task with :task_not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.attach_canvas(Scope.system(), UUID.generate(), canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "surfaces a missing :attached_by as a changeset error", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id)

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
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
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
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
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
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert :ok = CanvasAttachments.detach_canvas(Scope.system(), ctx.task.id, canvas.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    test "returns {:error, :not_found} when the pair doesn't exist", ctx do
      assert {:error, :not_found} =
               CanvasAttachments.detach_canvas(Scope.system(), ctx.task.id, UUID.generate())
    end

    test "only removes the matching pair, not other attachments on the task", ctx do
      canvas_a = create_canvas(ctx.space, ctx.participant)
      canvas_b = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas_a.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas_b.id,
          attached_by: attached_by(ctx)
        )

      assert :ok = CanvasAttachments.detach_canvas(Scope.system(), ctx.task.id, canvas_a.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 1
    end
  end

  # ── The detach gate (task 019fb581 stage 3; tasks.write since 01a1559a) ──
  #
  # Detach is the second write that mutates the grant graph. It was reachable
  # by any runtime that knew two ids: `execute("task_detach_canvas", …)`
  # ignored its context entirely.
  describe "detach_canvas/3 authorizes the detacher against the task" do
    test "a runtime without tasks.write is denied and the row survives", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {_rt, scope} = runtime_in!(ctx.org, AgentRuntime.default_tool_profile())

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas(scope, ctx.task.id, canvas.id)

      assert Repo.aggregate(CanvasAttachment, :count) == 1
    end

    # The shape the LiveView strip's × button takes: the viewer's own
    # `@access_scope`, a member of the task's org.
    test "a user holding tasks.write in the task's org may detach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      user = member!(ctx.org)

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert :ok = CanvasAttachments.detach_canvas(user_scope(user), ctx.task.id, canvas.id)
      assert Repo.aggregate(CanvasAttachment, :count) == 0
    end

    # Detach has NO canvas conjunct: it revokes a read grant rather than
    # conferring one. A writer that could never read this canvas may still
    # unstaple it.
    test "a canvas the detacher cannot read is still detachable by a task writer", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {_rt, scope} = runtime_in!(ctx.org)

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      # Positive control: this caller genuinely fails the canvas door.
      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas(
                 scope,
                 ctx.task.id,
                 create_canvas(ctx.space, ctx.participant).id,
                 attached_by: attached_by(ctx)
               )

      assert :ok = CanvasAttachments.detach_canvas(scope, ctx.task.id, canvas.id)
    end

    test "a nonexistent task reports :task_not_found, not :not_found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.detach_canvas(Scope.system(), UUID.generate(), canvas.id)
    end

    test "a malformed task id reports :task_not_found rather than raising", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_not_found} =
               CanvasAttachments.detach_canvas(Scope.system(), "higginshigginsxx", canvas.id)
    end

    test "a nil scope is denied, not treated as system", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
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
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas_a.id,
          attached_by: attached_by(ctx)
        )

      # Force ordering — bump inserted_at on the first row backward in time
      # so we can prove the list is ordered by inserted_at, not by id.
      shift_inserted_at(a, -60)

      {:ok, _b} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas_b.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _c} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas_c.id,
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
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas_live.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas_gone.id,
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
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
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
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      {:ok, second} =
        CanvasAttachments.attach_canvas(Scope.system(), other_task.id, canvas.id,
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
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
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
               CanvasAttachments.attach_canvas(Scope.system(), "higginshigginsxx", canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "a malformed canvas id reports :canvas_not_found rather than raising", ctx do
      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, "higginshigginsxx",
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
  # Every caller in this block holds `tasks.write` in the task's org; the
  # task door runs FIRST, so without it each of these would be denied before
  # the canvas is ever loaded and the block would assert nothing about the
  # canvas at all.
  describe "attach_canvas/4 authorizes the attacher against the canvas" do
    test "a user who participates in the canvas's space may attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      user = member!(ctx.org)
      create_participant(ctx.space.id, %{participant_id: user.id})

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas(user_scope(user), ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "an agent that participates in the canvas's space may attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    # A `group` space: inside the user's org fence, but not a channel, so the
    # `:org_reader` path (org members read org channels) cannot grant it.
    test "a user with no grant on the canvas is rejected and no row is written", ctx do
      group = create_space(%{kind: "group"})
      canvas = create_canvas(group, create_participant(group.id))
      user = member!(ctx.org)

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas(user_scope(user), ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert CanvasAttachments.list_task_canvases(ctx.task.id) == []
    end

    test "an agent outside the canvas's space is rejected", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(create_space(), rt)

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "Scope.system/0 is unaffected by the gate", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    # Attribution is caller-supplied metadata; the scope is who is asking.
    # They legitimately differ — `DesignTaskDirection` attaches with
    # `Scope.system/0` while attributing to the responsible designer — so
    # attribution must never be readable as authorization.
    test "attribution is not the authorization subject", ctx do
      group = create_space(%{kind: "group"})
      author = create_participant(group.id)
      canvas = create_canvas(group, author)
      user = member!(ctx.org)

      # Attributing the attach to a genuine participant does NOT let a
      # non-participant through.
      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas(user_scope(user), ctx.task.id, canvas.id,
                 attached_by: %{kind: "user", id: author.id}
               )
    end

    # Ordering: a canvas that does not exist reports absence, so the denial
    # does not become a richer existence oracle than the read door already is.
    test "a nonexistent canvas reports :canvas_not_found ahead of :canvas_forbidden", ctx do
      user = member!(ctx.org)

      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas(
                 user_scope(user),
                 ctx.task.id,
                 UUID.generate(),
                 attached_by: attached_by(ctx)
               )
    end
  end

  # ── The attach gate: tasks.write through task_target (task 01a1559a) ────
  #
  # Task 019fb581 stage 3 put a task gate in front of the attach (before it
  # any canvas reader could staple a canvas onto any task in the system).
  # Task 01a1559a stage 1 made that gate the rule `task_update` is held to:
  # `Platform.Access.task_target(scope, {:task, id}, "tasks.write")`, the
  # org fence plus the role permission. An agent no longer has to be bound
  # to the task (assignee, phase assignee, space participant) to attach.
  describe "attach_canvas/4 authorizes the attacher against the task" do
    setup do
      %{org_b: org!("initech")}
    end

    # The widening this task exists for, measured on a runtime that is on NO
    # binding the old rule accepted.
    test "a same-org runtime holding tasks.write that is not bound to the task may attach",
         ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)

      task = Repo.get!(Platform.Tasks.Task, ctx.task.id)
      refute task.assignee_id == rt.agent_id
      assert task.phase_assignees in [nil, %{}]

      case ExecutionSpace.find_by_task_id(task.id) do
        nil -> :ok
        space -> assert Chat.get_agent_participant(space.id, rt.agent_id) == nil
      end

      assert {:ok, %CanvasAttachment{} = row} =
               CanvasAttachments.attach_canvas(scope, task.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert row.attached_by_kind == "agent"
      assert row.attached_by_id == rt.agent_id
      assert :ok = CanvasAttachments.detach_canvas(scope, task.id, canvas.id)
    end

    test "a user holding tasks.write in the task's org may attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      user = member!(ctx.org)
      create_participant(ctx.space.id, %{participant_id: user.id})

      assert {:ok, %CanvasAttachment{}} =
               CanvasAttachments.attach_canvas(user_scope(user), ctx.task.id, canvas.id,
                 attached_by: %{kind: "user", id: user.id}
               )
    end

    # THE FENCE. The runtime's owner belongs to `initech` only, the task is
    # in `globex`. Same profile as the positive case above, so the only
    # difference is the org.
    test "a cross-org (fenced) runtime is denied and no row is written", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org_b)
      agent_reads!(ctx.space, rt)

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas(scope, ctx.task.id, canvas.id)

      assert CanvasAttachments.list_task_canvases(ctx.task.id) == []

      # Positive control on the same fixture shape: the runtime reaches a
      # task in its own org, with a canvas it reads inside its own fence.
      %{task: own} = task_in!(ctx.org_b)
      own_space = create_space(%{org_id: ctx.org_b.id})
      agent_reads!(own_space, rt)
      own_canvas = create_canvas(own_space, create_participant(own_space.id))

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(scope, own.id, own_canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )
    end

    # Through the federated entry point, the fenced runtime's answer is the
    # random-UUID answer for the id it sent: a foreign task cannot be told
    # from a missing one (the `@task_write_targets` swap).
    test "through ToolArguments.dispatch/3 a cross-org runtime gets the random-UUID envelope",
         ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, _scope} = runtime_in!(ctx.org_b)
      agent_reads!(ctx.space, rt)
      context = %{runtime_id: rt.runtime_id, agent_id: rt.agent_id}

      for tool <- ~w(task_attach_canvas task_detach_canvas) do
        random = UUID.generate()

        refused =
          ToolArguments.dispatch(
            tool,
            %{"task_id" => ctx.task.id, "canvas_id" => canvas.id},
            context
          )

        missing =
          ToolArguments.dispatch(tool, %{"task_id" => random, "canvas_id" => canvas.id}, context)

        assert {:error, %{error: "Task not found: " <> _}} = refused
        assert refused == replace_id(missing, random, ctx.task.id), tool
      end

      assert CanvasAttachments.list_task_canvases(ctx.task.id) == []
    end

    test "a same-org runtime without tasks.write is denied", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org, AgentRuntime.default_tool_profile())
      agent_reads!(ctx.space, rt)

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert CanvasAttachments.list_task_canvases(ctx.task.id) == []
    end

    test "a nil scope is denied at the task door, not treated as system", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(nil, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end

    # ORDERING. The task door runs first, so a caller who may not write the
    # task learns nothing about the canvas — not even whether it exists or
    # whether they could read it.
    test "a task denial precedes the canvas checks", ctx do
      {_rt, scope} = runtime_in!(ctx.org, AgentRuntime.default_tool_profile())
      unreadable = create_canvas(ctx.space, ctx.participant)

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, UUID.generate(),
                 attached_by: attached_by(ctx)
               )

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, unreadable.id,
                 attached_by: attached_by(ctx)
               )
    end

    test "an unreadable canvas is :canvas_forbidden once the task check passes", ctx do
      {_rt, scope} = runtime_in!(ctx.org)
      unreadable = create_canvas(ctx.space, ctx.participant)

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, unreadable.id,
                 attached_by: attached_by(ctx)
               )
    end

    # `TaskTarget.resolve/1` checks existence only, so the live-row load in
    # front of it is what keeps a soft-deleted task a not-found, even for a
    # caller who could write it.
    test "a soft-deleted task reports :task_not_found even for a writer", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)
      %{task: task} = task_in!(ctx.org)

      task
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      for s <- [scope, Scope.system()] do
        assert {:error, :task_not_found} =
                 CanvasAttachments.attach_canvas(s, task.id, canvas.id,
                   attached_by: attached_by(ctx)
                 )
      end

      assert denial_rows(task) == []
    end

    test "task_list_canvases' gate takes tasks.read", ctx do
      user = member!(ctx.org)
      {_rt, writer} = runtime_in!(ctx.org)
      {_rt, fenced} = runtime_in!(ctx.org_b)
      {_rt, bare} = runtime_in!(ctx.org, AgentRuntime.default_tool_profile())

      assert :ok =
               CanvasAttachments.ensure_task_touchable(user_scope(user), ctx.task.id,
                 permission: "tasks.read"
               )

      assert :ok =
               CanvasAttachments.ensure_task_touchable(writer, ctx.task.id,
                 permission: "tasks.read"
               )

      for s <- [fenced, bare, nil] do
        assert {:error, :task_forbidden} =
                 CanvasAttachments.ensure_task_touchable(s, ctx.task.id,
                   permission: "tasks.read",
                   tool: "task_list_canvases"
                 )
      end
    end

    test "a denied attach writes exactly one audit row naming the tool", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org_b)

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(scope, ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert [event] = denial_rows(ctx.task)
      assert event.event_type == "platform.tasks.access_denied"
      assert event.actor_type == "agent"
      assert event.actor_id == rt.agent_id
      assert event.resource_id == ctx.task.id
      assert event.metadata["tool"] == "task_attach_canvas"
    end

    test "a denied detach is attributed to task_detach_canvas, not to attach", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {_rt, scope} = runtime_in!(ctx.org_b)

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas(scope, ctx.task.id, canvas.id)

      assert [event] = denial_rows(ctx.task)
      assert event.metadata["tool"] == "task_detach_canvas"
    end

    test "a granted attach emits no denial", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert denial_rows(ctx.task) == []
    end
  end

  # ── NO TRANSITION (task 01a1559a stage 1) ────────────────────────────────
  #
  # Letting any `tasks.write` holder attach is only safe if attaching is
  # pure organisation: it must not start, reassign or dispatch the task. On a
  # task that is in flight (in_progress, assigned, phase assignees set, NOT in
  # the ADR-0046 design step, so the settle hook is inert), attach and then
  # detach leave every dispatch-relevant field byte-equal and create no
  # execution lease and no runtime event.
  describe "attach and detach do not transition the task" do
    test "status, assignee, phase_assignees and planning_step are untouched; no lease, no event",
         ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)
      assignee = UUID.generate()

      task =
        ctx.task
        |> Ecto.Changeset.change(
          status: "in_progress",
          assignee_type: "agent",
          assignee_id: assignee,
          phase_assignees: %{
            "execution" => %{"assignee_id" => assignee, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => UUID.generate(), "assignee_type" => "agent"}
          }
        )
        |> Repo.update!()

      before = dispatch_fields(task.id)
      refute before.planning_step == "designing"

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(scope, task.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert dispatch_fields(task.id) == before

      assert :ok = CanvasAttachments.detach_canvas(scope, task.id, canvas.id)

      assert dispatch_fields(task.id) == before
      assert before.leases == 0
      assert before.events == 0
    end
  end

  defp dispatch_fields(task_id) do
    task = Repo.get!(Platform.Tasks.Task, task_id)

    %{
      status: task.status,
      assignee_type: task.assignee_type,
      assignee_id: task.assignee_id,
      phase_assignees: task.phase_assignees,
      planning_step: task.planning_step,
      planning_step_outcomes: task.planning_step_outcomes,
      leases:
        Repo.aggregate(
          from(l in Platform.Orchestration.ExecutionLease, where: l.task_id == ^task_id),
          :count
        ),
      events:
        Repo.aggregate(
          from(e in Platform.Orchestration.RuntimeEvent, where: e.task_id == ^task_id),
          :count
        )
    }
  end

  defp replace_id(term, from, to) when is_binary(term), do: String.replace(term, from, to)

  defp replace_id(term, from, to) when is_list(term),
    do: Enum.map(term, &replace_id(&1, from, to))

  defp replace_id(term, from, to) when is_tuple(term),
    do: term |> Tuple.to_list() |> replace_id(from, to) |> List.to_tuple()

  defp replace_id(%_{} = struct, _from, _to), do: struct

  defp replace_id(term, from, to) when is_map(term),
    do: Map.new(term, fn {k, v} -> {replace_id(k, from, to), replace_id(v, from, to)} end)

  defp replace_id(term, _from, _to), do: term

  # ── The design step stays coherent under denial (ADR-0046 member 7) ──────
  #
  # `tap_settle_design_step/1` runs on the `{:ok, %CanvasAttachment{}}` arm
  # only. A denial returns before the insert, so the settler is never
  # reached and the step is left OPEN for its normal deadline to expire it
  # to `failed`. It is not half-settled and not stranded ambiguously.
  describe "a denied attach leaves the pre-plan design step OPEN" do
    test "planning_step is still designing and no design outcome was recorded", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {_rt, scope} = runtime_in!(ctx.org, AgentRuntime.default_tool_profile())

      task =
        ctx.task
        |> Ecto.Changeset.change(planning_step: "designing", planning_step_outcomes: %{})
        |> Repo.update!()

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas(scope, task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      reloaded = Repo.get!(Platform.Tasks.Task, task.id)
      assert reloaded.planning_step == "designing"
      refute Map.has_key?(reloaded.planning_step_outcomes, "design")
    end

    # Positive control for the assertion above: the SAME setup with a granted
    # caller does settle, so "still designing" cannot pass because the settler
    # is inert in this fixture.
    test "the same attach from a granted caller does settle the step", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)

      task =
        ctx.task
        |> Ecto.Changeset.change(planning_step: "designing", planning_step_outcomes: %{})
        |> Repo.update!()

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(Scope.system(), task.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      reloaded = Repo.get!(Platform.Tasks.Task, task.id)
      refute reloaded.planning_step == "designing"
      assert Map.has_key?(reloaded.planning_step_outcomes, "design")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Stack attach and detach (task 01a1559a stage 2)
  # ══════════════════════════════════════════════════════════════════════════

  # A stack in `project` with `count` members, in stack order.
  defp stack_with_members!(project, count) do
    slug = "ca-stack-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Platform.Tasks.Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "CA Stack",
        rollup_branch: "stack/#{slug}"
      })

    members =
      for i <- 1..count//1 do
        {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "CA member #{i}"})
        {:ok, member} = Platform.Tasks.Stacks.add_task(stack, task)
        member
      end

    {stack, members}
  end

  defp rows_for(canvas_id) do
    Repo.all(
      from(a in CanvasAttachment, where: a.canvas_id == ^canvas_id, order_by: [asc: a.task_id])
    )
  end

  describe "attach_canvas_to_stack/4 — idempotent, existing rows untouched" do
    test "6 members, 2 pre-attached: attached 4, skipped 2; the 2 rows are byte-equal; a second call attaches 0",
         ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, members} = stack_with_members!(ctx.project, 6)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)

      [_, pre_a, _, _, pre_b, _] = members
      earlier = UUID.generate()

      pre =
        for {task, note} <- [{pre_a, "kept note A"}, {pre_b, "kept note B"}] do
          {:ok, row} =
            CanvasAttachments.attach_canvas(Scope.system(), task.id, canvas.id,
              note: note,
              attached_by: %{kind: "user", id: earlier}
            )

          row
        end

      pre_snapshot = Enum.map(pre, &Repo.get!(CanvasAttachment, &1.id))

      assert {:ok, result} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                 note: "stack note",
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      member_ids = Enum.map(members, & &1.id)
      skipped = [pre_a.id, pre_b.id]

      assert result.stack_id == stack.id
      assert result.canvas_id == canvas.id
      assert result.member_count == 6
      assert result.attached_count == 4
      assert result.skipped_count == 2
      assert result.attached_task_ids == member_ids -- skipped
      assert result.skipped_task_ids == skipped

      # The two pre-existing rows are byte-equal: note, attribution and both
      # timestamps survive, which an upsert would have rewritten.
      assert Enum.map(pre, &Repo.get!(CanvasAttachment, &1.id)) == pre_snapshot

      new_rows = Enum.reject(rows_for(canvas.id), &(&1.task_id in skipped))
      assert length(new_rows) == 4

      for row <- new_rows do
        assert row.attached_by_kind == "agent"
        assert row.attached_by_id == rt.agent_id
        assert row.note == "stack note"
      end

      assert {:ok, again} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert again.attached_count == 0
      assert again.skipped_count == 6
      assert again.attached_task_ids == []
      assert again.skipped_task_ids == member_ids
      assert length(rows_for(canvas.id)) == 6
      assert Enum.map(pre, &Repo.get!(CanvasAttachment, &1.id)) == pre_snapshot
    end

    test "an empty stack returns zeros and writes nothing", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, []} = stack_with_members!(ctx.project, 0)

      assert {:ok,
              %{
                member_count: 0,
                attached_count: 0,
                skipped_count: 0,
                attached_task_ids: [],
                skipped_task_ids: []
              }} =
               CanvasAttachments.attach_canvas_to_stack(Scope.system(), stack.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      assert rows_for(canvas.id) == []
    end

    test "a missing attached_by is the changeset error and writes nothing", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, _members} = stack_with_members!(ctx.project, 2)

      assert {:error, %Ecto.Changeset{}} =
               CanvasAttachments.attach_canvas_to_stack(Scope.system(), stack.id, canvas.id, [])

      assert rows_for(canvas.id) == []
    end

    test "unknown, malformed and soft-deleted ids are not-found", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, _members} = stack_with_members!(ctx.project, 1)

      for bad <- [UUID.generate(), "not-a-uuid"] do
        assert {:error, :stack_not_found} =
                 CanvasAttachments.attach_canvas_to_stack(Scope.system(), bad, canvas.id,
                   attached_by: attached_by(ctx)
                 )

        assert {:error, :stack_not_found} =
                 CanvasAttachments.detach_canvas_from_stack(Scope.system(), bad, canvas.id)
      end

      for bad <- [UUID.generate(), "not-a-uuid"] do
        assert {:error, :canvas_not_found} =
                 CanvasAttachments.attach_canvas_to_stack(Scope.system(), stack.id, bad,
                   attached_by: attached_by(ctx)
                 )
      end

      {:ok, _} = Chat.delete_canvas(canvas)

      assert {:error, :canvas_not_found} =
               CanvasAttachments.attach_canvas_to_stack(Scope.system(), stack.id, canvas.id,
                 attached_by: attached_by(ctx)
               )
    end
  end

  describe "detach_canvas_from_stack/3 is symmetric" do
    test "detached 6, then a second call detaches 0 and skips 6", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, members} = stack_with_members!(ctx.project, 6)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)
      member_ids = Enum.map(members, & &1.id)

      # A row on a task OUTSIDE the stack, for the same canvas, survives.
      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert {:ok, %{attached_count: 6}} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert {:ok, first} = CanvasAttachments.detach_canvas_from_stack(scope, stack.id, canvas.id)

      assert first.member_count == 6
      assert first.detached_count == 6
      assert first.skipped_count == 0
      assert first.detached_task_ids == member_ids
      assert first.skipped_task_ids == []

      assert {:ok, second} =
               CanvasAttachments.detach_canvas_from_stack(scope, stack.id, canvas.id)

      assert second.detached_count == 0
      assert second.skipped_count == 6
      assert second.skipped_task_ids == member_ids

      assert [%CanvasAttachment{task_id: outside}] = rows_for(canvas.id)
      assert outside == ctx.task.id
    end

    test "a malformed canvas id detaches nothing and skips every member", ctx do
      {stack, _members} = stack_with_members!(ctx.project, 2)

      assert {:ok, %{detached_count: 0, skipped_count: 2}} =
               CanvasAttachments.detach_canvas_from_stack(Scope.system(), stack.id, "nope")
    end
  end

  describe "the stack gate: tasks.write on the stack and on every member" do
    setup do
      %{org_b: org!("initech")}
    end

    test "a same-org runtime bound to no member attaches; rows record the agent", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, members} = stack_with_members!(ctx.project, 3)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)

      for m <- members do
        task = Repo.get!(Platform.Tasks.Task, m.id)
        refute task.assignee_id == rt.agent_id
        assert task.phase_assignees in [nil, %{}]
        assert ExecutionSpace.find_by_task_id(task.id) == nil
      end

      assert {:ok, %{attached_count: 3}} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert Enum.all?(
               rows_for(canvas.id),
               &(&1.attached_by_kind == "agent" and &1.attached_by_id == rt.agent_id)
             )
    end

    # THE FENCE. Same profile as the positive case above; only the org differs.
    test "a cross-org (fenced) runtime is refused and no row is written", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, _members} = stack_with_members!(ctx.project, 3)
      {rt, scope} = runtime_in!(ctx.org_b)
      agent_reads!(ctx.space, rt)

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      {:ok, %{attached_count: 3}} =
        CanvasAttachments.attach_canvas_to_stack(Scope.system(), stack.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas_from_stack(scope, stack.id, canvas.id)

      assert length(rows_for(canvas.id)) == 3

      # Positive control: the same runtime on a stack in its own org, with a
      # canvas it reads inside its fence.
      %{project: own_project} = task_in!(ctx.org_b)
      {own_stack, _} = stack_with_members!(own_project, 2)
      own_space = create_space(%{org_id: ctx.org_b.id})
      agent_reads!(own_space, rt)
      own_canvas = create_canvas(own_space, create_participant(own_space.id))

      assert {:ok, %{attached_count: 2}} =
               CanvasAttachments.attach_canvas_to_stack(scope, own_stack.id, own_canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert {:ok, %{detached_count: 2}} =
               CanvasAttachments.detach_canvas_from_stack(scope, own_stack.id, own_canvas.id)
    end

    # ALL-OR-NOTHING. The stack and two members are in the caller's org; one
    # member was added from another org. The caller may write the stack and
    # two of three members, and still nothing is written.
    test "one refused member refuses the whole call and writes nothing", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, members} = stack_with_members!(ctx.project, 2)
      %{task: foreign} = task_in!(ctx.org_b)
      {:ok, _} = Platform.Tasks.Stacks.add_task(stack, foreign)

      user = member!(ctx.org)
      create_participant(ctx.space.id, %{participant_id: user.id})
      scope = user_scope(user)

      # Positive control: the caller may write each in-org member singly.
      for m <- members do
        assert :ok = CanvasAttachments.ensure_task_touchable(scope, m.id)
      end

      assert {:error, :task_forbidden} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                 attached_by: %{kind: "user", id: user.id}
               )

      assert rows_for(canvas.id) == []

      {:ok, %{attached_count: 3}} =
        CanvasAttachments.attach_canvas_to_stack(Scope.system(), stack.id, canvas.id,
          attached_by: attached_by(ctx)
        )

      assert {:error, :task_forbidden} =
               CanvasAttachments.detach_canvas_from_stack(scope, stack.id, canvas.id)

      assert length(rows_for(canvas.id)) == 3
    end

    test "a runtime without tasks.write and a nil scope are refused", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, _members} = stack_with_members!(ctx.project, 2)
      {rt, scope} = runtime_in!(ctx.org, AgentRuntime.default_tool_profile())
      agent_reads!(ctx.space, rt)

      for s <- [scope, nil] do
        assert {:error, :task_forbidden} =
                 CanvasAttachments.attach_canvas_to_stack(s, stack.id, canvas.id,
                   attached_by: %{kind: "agent", id: rt.agent_id}
                 )

        assert {:error, :task_forbidden} =
                 CanvasAttachments.detach_canvas_from_stack(s, stack.id, canvas.id)
      end

      assert rows_for(canvas.id) == []
    end

    test "the canvas conjunct runs after the gate: an unreadable canvas is canvas_forbidden",
         ctx do
      {stack, _members} = stack_with_members!(ctx.project, 2)
      {rt, scope} = runtime_in!(ctx.org)
      unreadable = create_canvas(ctx.space, ctx.participant)

      assert {:error, :canvas_forbidden} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, unreadable.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert rows_for(unreadable.id) == []
    end

    test "a refused stack call emits one denial event", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, members} = stack_with_members!(ctx.project, 2)
      {rt, scope} = runtime_in!(ctx.org_b)

      ref = make_ref()
      parent = self()
      id = "ca-stack-denial-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:platform, :tasks, :access_denied],
        fn _e, _m, meta, _ -> send(parent, {ref, meta}) end,
        nil
      )

      try do
        assert {:error, :task_forbidden} =
                 CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                   attached_by: %{kind: "agent", id: rt.agent_id}
                 )
      after
        :telemetry.detach(id)
      end

      # The handler is VM-global and this file is async, so only events about
      # THIS stack or its members are counted.
      ours = MapSet.new([stack.id | Enum.map(members, & &1.id)])

      mine =
        Stream.repeatedly(fn ->
          receive do
            {^ref, meta} -> meta
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> Enum.filter(&MapSet.member?(ours, &1.resource_id))

      assert [meta] = mine
      assert meta.resource_type == "stack"
      assert meta.resource_id == stack.id
      assert meta.tool == "stack_attach_canvas"
    end
  end

  # NO-TRANSITION. Members in backlog, planning with the ADR-0046 design step
  # OPEN ('designing'), and in_progress with assignees. The single-task attach
  # would settle the 'designing' member's step; the stack attach must not.
  describe "stack attach and detach do not transition any member" do
    test "status, assignee, phase_assignees and planning_step are byte-equal; no lease, no event",
         ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {stack, [backlog, designing, running]} = stack_with_members!(ctx.project, 3)
      {rt, scope} = runtime_in!(ctx.org)
      agent_reads!(ctx.space, rt)
      assignee = UUID.generate()

      backlog |> Ecto.Changeset.change(status: "backlog") |> Repo.update!()

      designing
      |> Ecto.Changeset.change(
        status: "planning",
        planning_step: "designing",
        planning_step_outcomes: %{},
        assignee_type: "agent",
        assignee_id: assignee,
        phase_assignees: %{
          "planning" => %{"assignee_id" => assignee, "assignee_type" => "agent"}
        }
      )
      |> Repo.update!()

      running
      |> Ecto.Changeset.change(
        status: "in_progress",
        assignee_type: "agent",
        assignee_id: assignee,
        phase_assignees: %{
          "execution" => %{"assignee_id" => assignee, "assignee_type" => "agent"},
          "review" => %{"assignee_id" => UUID.generate(), "assignee_type" => "agent"}
        }
      )
      |> Repo.update!()

      ids = [backlog.id, designing.id, running.id]
      before = Map.new(ids, &{&1, dispatch_fields(&1)})

      assert before[designing.id].planning_step == "designing"
      assert before[backlog.id].status == "backlog"
      assert before[running.id].status == "in_progress"

      assert {:ok, %{attached_count: 3}} =
               CanvasAttachments.attach_canvas_to_stack(scope, stack.id, canvas.id,
                 attached_by: %{kind: "agent", id: rt.agent_id}
               )

      assert Map.new(ids, &{&1, dispatch_fields(&1)}) == before

      assert {:ok, %{detached_count: 3}} =
               CanvasAttachments.detach_canvas_from_stack(scope, stack.id, canvas.id)

      assert Map.new(ids, &{&1, dispatch_fields(&1)}) == before

      for id <- ids do
        assert before[id].leases == 0
        assert before[id].events == 0
      end
    end

    # POSITIVE CONTROL for the 'designing' member: the single-task attach on
    # the same fixture DOES settle the step, so "still designing" above cannot
    # pass because the settler is inert here.
    test "the single-task attach on the same 'designing' member does settle it", ctx do
      canvas = create_canvas(ctx.space, ctx.participant)
      {_stack, [designing]} = stack_with_members!(ctx.project, 1)

      designing
      |> Ecto.Changeset.change(
        status: "planning",
        planning_step: "designing",
        planning_step_outcomes: %{}
      )
      |> Repo.update!()

      assert {:ok, _} =
               CanvasAttachments.attach_canvas(Scope.system(), designing.id, canvas.id,
                 attached_by: attached_by(ctx)
               )

      refute dispatch_fields(designing.id).planning_step == "designing"
    end
  end

  describe "list_stack_canvases/1 and stack_coverage/2" do
    test "one entry per canvas with its attached members in stack order", ctx do
      {stack, [a, b, c]} = stack_with_members!(ctx.project, 3)
      full = create_canvas(ctx.space, ctx.participant)
      partial = create_canvas(ctx.space, ctx.participant)
      gone = create_canvas(ctx.space, ctx.participant)

      {:ok, _} =
        CanvasAttachments.attach_canvas_to_stack(Scope.system(), stack.id, full.id,
          attached_by: attached_by(ctx)
        )

      for t <- [c, a] do
        {:ok, _} =
          CanvasAttachments.attach_canvas(Scope.system(), t.id, partial.id,
            attached_by: attached_by(ctx)
          )
      end

      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), b.id, gone.id,
          attached_by: attached_by(ctx)
        )

      {:ok, _} = Chat.delete_canvas(gone)

      # Not a member: never counted.
      {:ok, _} =
        CanvasAttachments.attach_canvas(Scope.system(), ctx.task.id, partial.id,
          attached_by: attached_by(ctx)
        )

      entries = Map.new(CanvasAttachments.list_stack_canvases(stack.id), &{&1.canvas_id, &1})

      assert map_size(entries) == 3
      assert entries[full.id].attached_task_ids == [a.id, b.id, c.id]
      assert entries[full.id].attached_count == 3
      assert entries[full.id].member_count == 3
      assert entries[full.id].canvas.title == full.title
      assert entries[partial.id].attached_task_ids == [a.id, c.id]
      assert entries[partial.id].attached_count == 2
      assert entries[gone.id].canvas == nil

      assert CanvasAttachments.stack_coverage(stack.id, partial.id) ==
               %{member_count: 3, already_count: 2, to_attach_count: 1}

      assert CanvasAttachments.stack_coverage(stack.id, full.id) ==
               %{member_count: 3, already_count: 3, to_attach_count: 0}

      assert CanvasAttachments.stack_coverage(stack.id, UUID.generate()) ==
               %{member_count: 3, already_count: 0, to_attach_count: 3}

      assert CanvasAttachments.list_stack_canvases("not-a-uuid") == []
      assert CanvasAttachments.list_stack_canvases(UUID.generate()) == []

      assert CanvasAttachments.stack_coverage("not-a-uuid", full.id) ==
               %{member_count: 0, already_count: 0, to_attach_count: 0}
    end
  end
end
