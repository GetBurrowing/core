defmodule Platform.Tasks.TaskAccessTest do
  @moduledoc """
  Stage 1 of task 019fb581 — task authorization, the primitive.

  No caller is wired to `Platform.Tasks.TaskAccess` yet, so this file is the
  module's ONLY consumer and has to pin the whole rule on its own. Every grant
  path, every denial and the not-found/forbidden split are asserted
  explicitly rather than inferred from a happy path.

  Covers:

    * all six grants — `:system`, `:assignee`, `:phase_assignee`,
      `:space_member`, `:sponsor`, `:project_member`
    * the agent short-circuit after path 4, with a POSITIVE CONTROL: the same
      id resolves `:project_member` / `:sponsor` as `{:user, id}` and nothing
      as `{:agent, id}`, so the absence assertion cannot pass vacuously
    * `nil` and unrecognised actor shapes — no principal, no grant, and no
      promotion to `:system`
    * malformed ids, including the 16-byte binary a bare `Ecto.UUID.cast/1`
      would wave through
    * soft-deleted tasks — `:not_found` even for a grant holder
    * denial telemetry: emitted once, and REGISTERED, which is what makes the
      audit row exist at all
  """

  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures

  alias Ecto.UUID
  alias Platform.Audit
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Tasks
  alias Platform.Tasks.TaskAccess
  alias Platform.Tenancy

  setup do
    %{org_a: Tenancy.get_org_by_slug!("sxi"), org_b: Tenancy.get_org_by_slug!("soylent")}
  end

  # ── Builders ──────────────────────────────────────────────────────────────

  defp project_in!(org) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "TA Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    project
  end

  defp task_in!(org, attrs \\ %{}) do
    project = project_in!(org)

    {:ok, task} =
      Tasks.create_task(Map.merge(%{project_id: project.id, title: "TA Task"}, attrs))

    %{project: project, task: task}
  end

  defp exec_space!(task) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    space
  end

  defp denial_rows(task) do
    Audit.list(resource_type: "task", resource_id: task.id)
  end

  # ── 1. :system ────────────────────────────────────────────────────────────

  describe "fetch_for_actor/3 — :system" do
    test "the explicit system actor resolves every task", %{org_a: org_a} do
      %{task: task} = task_in!(org_a)

      assert {:ok, resolved, :system} = TaskAccess.fetch_for_actor(task.id, :system)
      assert resolved.id == task.id
    end

    test "a system resolution is not audited", %{org_a: org_a} do
      %{task: task} = task_in!(org_a)

      assert {:ok, _task, :system} = TaskAccess.fetch_for_actor(task.id, :system)
      assert denial_rows(task) == []
    end
  end

  # ── 2. :assignee ──────────────────────────────────────────────────────────

  describe "fetch_for_actor/3 — :assignee" do
    test "the agent named in assignee_id/assignee_type resolves", %{org_a: org_a} do
      agent_id = UUID.generate()

      %{task: task} =
        task_in!(org_a, %{assignee_type: "agent", assignee_id: agent_id})

      assert {:ok, _task, :assignee} = TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})
    end

    test "the user named in assignee_id/assignee_type resolves", %{org_a: org_a} do
      user = create_user!()

      %{task: task} =
        task_in!(org_a, %{assignee_type: "user", assignee_id: user.id})

      assert {:ok, _task, :assignee} = TaskAccess.fetch_for_actor(task.id, {:user, user.id})
    end

    test "the KIND has to match, not just the id", %{org_a: org_a} do
      # An agent id and a user id are drawn from different tables and could
      # collide. Matching on the id alone would hand a user an agent's grant.
      shared_id = UUID.generate()

      %{task: task} =
        task_in!(org_a, %{assignee_type: "agent", assignee_id: shared_id})

      assert {:ok, _task, :assignee} = TaskAccess.fetch_for_actor(task.id, {:agent, shared_id})
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:user, shared_id})
    end

    test "an assignee_id with no assignee_type grants nothing", %{org_a: org_a} do
      # `Tasks.assignee_for_phase/2`'s top-level arm requires both fields, so a
      # half-written row must not resolve as either kind.
      agent_id = UUID.generate()
      %{task: task} = task_in!(org_a, %{assignee_id: agent_id})

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:user, agent_id})
    end
  end

  # ── 3. :phase_assignee ────────────────────────────────────────────────────

  describe "fetch_for_actor/3 — :phase_assignee" do
    test "an agent assigned to a phase other than the current one resolves", %{org_a: org_a} do
      agent_id = UUID.generate()
      %{task: task} = task_in!(org_a)

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "execution" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
        })

      # The task is in `backlog`, whose phase is `planning`, so the top-level
      # assignee was re-derived to nil. Path 2 cannot be what fires here.
      assert is_nil(task.assignee_id)

      assert {:ok, _task, :phase_assignee} =
               TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})
    end

    test "a bare assignee_id with no type is an AGENT, agreeing with Tasks.per_phase_assignee/2",
         %{org_a: org_a} do
      agent_id = UUID.generate()
      %{task: task} = task_in!(org_a)

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{"review" => %{"assignee_id" => agent_id}})

      assert {:ok, _task, :phase_assignee} =
               TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})

      # …and specifically NOT a user, which is the half of the agreement that
      # would silently widen the gate if this module re-derived the map itself.
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:user, agent_id})
    end

    test "a user assigned to a phase resolves", %{org_a: org_a} do
      user = create_user!()
      %{task: task} = task_in!(org_a)

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "review" => %{"assignee_id" => user.id, "assignee_type" => "user"}
        })

      assert {:ok, _task, :phase_assignee} = TaskAccess.fetch_for_actor(task.id, {:user, user.id})
    end

    test "an id in nobody's phase entry resolves nothing", %{org_a: org_a} do
      %{task: task} = task_in!(org_a)

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "execution" => %{"assignee_id" => UUID.generate(), "assignee_type" => "agent"}
        })

      assert {:error, :forbidden} =
               TaskAccess.fetch_for_actor(task.id, {:agent, UUID.generate()})
    end
  end

  # ── 4. :space_member ──────────────────────────────────────────────────────

  describe "fetch_for_actor/3 — :space_member" do
    test "an agent participant of the task's execution space resolves", %{org_a: org_a} do
      agent_id = UUID.generate()
      %{task: task} = task_in!(org_a)
      space = exec_space!(task)
      add_agent!(space.id, agent_id)

      assert {:ok, _task, :space_member} =
               TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})
    end

    test "a user participant of the task's execution space resolves", %{org_a: org_a} do
      user = create_user!()
      %{task: task} = task_in!(org_a)
      space = exec_space!(task)
      add_user!(space.id, user.id)

      assert {:ok, _task, :space_member} = TaskAccess.fetch_for_actor(task.id, {:user, user.id})
    end

    test "a user-type participant row does not confer the grant on an agent of the same id",
         %{org_a: org_a} do
      shared_id = UUID.generate()
      %{task: task} = task_in!(org_a)
      space = exec_space!(task)
      add_user!(space.id, shared_id)

      assert {:ok, _task, :space_member} = TaskAccess.fetch_for_actor(task.id, {:user, shared_id})
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, shared_id})
    end

    test "participating in some OTHER task's execution space grants nothing", %{org_a: org_a} do
      agent_id = UUID.generate()
      %{task: task} = task_in!(org_a)
      %{task: other_task} = task_in!(org_a)
      other_space = exec_space!(other_task)
      add_agent!(other_space.id, agent_id)

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})
    end

    test "a task with no execution space at all denies rather than raising", %{org_a: org_a} do
      %{task: task} = task_in!(org_a)

      assert is_nil(ExecutionSpace.find_by_task_id(task.id))
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, UUID.generate()})
    end
  end

  # ── 5. :sponsor ───────────────────────────────────────────────────────────

  describe "fetch_for_actor/3 — :sponsor" do
    test "the sponsoring user resolves", %{org_a: org_a} do
      sponsor = create_user!()
      %{task: task} = task_in!(org_a, %{sponsor_user_id: sponsor.id})

      assert {:ok, _task, :sponsor} = TaskAccess.fetch_for_actor(task.id, {:user, sponsor.id})
    end

    test "an unrelated user is not the sponsor", %{org_a: org_a} do
      sponsor = create_user!()
      other = create_user!()
      %{task: task} = task_in!(org_a, %{sponsor_user_id: sponsor.id})

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:user, other.id})
    end
  end

  # ── 6. :project_member ────────────────────────────────────────────────────

  describe "fetch_for_actor/3 — :project_member" do
    test "a member of the project's org resolves", %{org_a: org_a} do
      user = create_user!()
      plain_member!(user, org_a)
      %{task: task} = task_in!(org_a)

      assert {:ok, _task, :project_member} =
               TaskAccess.fetch_for_actor(task.id, {:user, user.id})
    end

    test "a member of a DIFFERENT org is denied", %{org_a: org_a, org_b: org_b} do
      user = create_user!()
      plain_member!(user, org_b)
      %{task: task} = task_in!(org_a)

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:user, user.id})
    end

    test "a user with no membership anywhere is denied", %{org_a: org_a} do
      user = create_user!()
      %{task: task} = task_in!(org_a)

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:user, user.id})
    end
  end

  # ── The agent short-circuit after path 4 ──────────────────────────────────

  describe "fetch_for_actor/3 — agent principals stop after :space_member" do
    test "an agent id that IS an org member resolves nothing through :project_member",
         %{org_a: org_a} do
      # POSITIVE CONTROL. The id is a real `users.id` with a real
      # `org_memberships` row, so `Tenancy.member_of?/2` says YES for it. The
      # only difference between the two calls below is the principal SHAPE.
      # Without the control this assertion would pass on a typo in the setup.
      user = create_user!()
      plain_member!(user, org_a)
      %{task: task} = task_in!(org_a)

      assert {:ok, _task, :project_member} =
               TaskAccess.fetch_for_actor(task.id, {:user, user.id})

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, user.id})
    end

    test "an agent id that IS the sponsor resolves nothing through :sponsor", %{org_a: org_a} do
      sponsor = create_user!()
      %{task: task} = task_in!(org_a, %{sponsor_user_id: sponsor.id})

      assert {:ok, _task, :sponsor} = TaskAccess.fetch_for_actor(task.id, {:user, sponsor.id})
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, sponsor.id})
    end

    test "the short-circuit does not cost an agent its first four paths", %{org_a: org_a} do
      # The stop is AFTER path 4, not before it.
      agent_id = UUID.generate()
      %{task: task} = task_in!(org_a, %{assignee_type: "agent", assignee_id: agent_id})

      assert {:ok, _task, :assignee} = TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})
    end
  end

  # ── No principal ──────────────────────────────────────────────────────────

  describe "fetch_for_actor/3 — no principal" do
    test "a nil actor is denied on a task anyone else could read", %{org_a: org_a} do
      user = create_user!()
      plain_member!(user, org_a)
      %{task: task} = task_in!(org_a)

      assert {:ok, _task, :project_member} =
               TaskAccess.fetch_for_actor(task.id, {:user, user.id})

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, nil)
    end

    test "an unrecognised actor shape is denied and is NOT promoted to :system",
         %{org_a: org_a} do
      user = create_user!()
      plain_member!(user, org_a)
      %{task: task} = task_in!(org_a)

      # A bare `%{id: _}` map is deliberately NOT accepted here, unlike
      # `Platform.Chat.CanvasAccess`: this module's actor taxonomy is
      # `Platform.Tasks`'s triple and nothing else. A caller holding a
      # `%User{}` must tag it `{:user, id}`.
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, %{id: user.id})
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, user.id)
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:runtime, user.id})
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, :admin)
    end
  end

  # ── Malformed, absent and soft-deleted ────────────────────────────────────

  describe "fetch_for_actor/3 — :not_found" do
    test "a well-formed id with no row is :not_found, not :forbidden" do
      assert {:error, :not_found} = TaskAccess.fetch_for_actor(UUID.generate(), :system)
    end

    test "a malformed id is :not_found and never reaches Repo" do
      assert {:error, :not_found} = TaskAccess.fetch_for_actor("not-a-uuid", :system)
      assert {:error, :not_found} = TaskAccess.fetch_for_actor("", :system)
      assert {:error, :not_found} = TaskAccess.fetch_for_actor(nil, :system)
      assert {:error, :not_found} = TaskAccess.fetch_for_actor(123, :system)
    end

    test "a 16-character slug does not clear the guard" do
      # The discriminating case. `Ecto.UUID.cast/1` hex-encodes any 16-byte
      # binary and returns `{:ok, _}`, so a bare cast would let this through
      # and `Repo` would raise `Ecto.Query.CastError` against the strict
      # UUIDv7 primary key. `Platform.UUID.valid?/1` adds the length check.
      slug = "higginshigginsxx"
      assert byte_size(slug) == 16
      assert {:ok, _hex} = Ecto.UUID.cast(slug)

      assert {:error, :not_found} = TaskAccess.fetch_for_actor(slug, :system)
    end

    test "a soft-deleted task is :not_found even for its own assignee", %{org_a: org_a} do
      agent_id = UUID.generate()

      %{task: task} =
        task_in!(org_a, %{assignee_type: "agent", assignee_id: agent_id})

      assert {:ok, _task, :assignee} = TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})

      {:ok, _deleted} = Tasks.soft_delete_task(task)

      assert {:error, :not_found} = TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})
      assert {:error, :not_found} = TaskAccess.fetch_for_actor(task.id, :system)
    end

    test "a live task the actor cannot touch is :forbidden, not :not_found", %{
      org_a: org_a,
      org_b: org_b
    } do
      user = create_user!()
      plain_member!(user, org_b)
      %{task: task} = task_in!(org_a)

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:user, user.id})
    end

    test "a soft-deleted task does not emit a denial event", %{org_a: org_a} do
      # Absence outranks denial: there is nothing to deny access TO, and a
      # denial row would make the audit stream an existence oracle.
      %{task: task} = task_in!(org_a)
      {:ok, _deleted} = Tasks.soft_delete_task(task)

      assert {:error, :not_found} = TaskAccess.fetch_for_actor(task.id, {:agent, UUID.generate()})
      assert denial_rows(task) == []
    end
  end

  # ── Denial telemetry ──────────────────────────────────────────────────────

  describe "denial telemetry" do
    test "the event is registered in the audit handler's allowlist" do
      # Without this registration `:telemetry.execute/3` is a silent no-op and
      # every assertion below would be testing an emit nobody listens to.
      assert [:platform, :tasks, :access_denied] in Platform.Audit.TelemetryHandler.events()
    end

    test "a denial writes exactly one audit row naming the actor and the task",
         %{org_a: org_a, org_b: org_b} do
      user = create_user!()
      plain_member!(user, org_b)
      %{task: task} = task_in!(org_a)

      assert {:error, :forbidden} =
               TaskAccess.fetch_for_actor(task.id, {:user, user.id}, tool: "task_attach_canvas")

      assert [event] = denial_rows(task)
      assert event.event_type == "platform.tasks.access_denied"
      assert event.actor_id == user.id
      assert event.actor_type == "user"
      assert event.resource_type == "task"
      assert event.resource_id == task.id
      assert event.metadata["tool"] == "task_attach_canvas"
    end

    test "an agent denial is attributed to the agent, not to a user", %{org_a: org_a} do
      agent_id = UUID.generate()
      %{task: task} = task_in!(org_a)

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, agent_id})

      assert [event] = denial_rows(task)
      assert event.actor_type == "agent"
      assert event.actor_id == agent_id
    end

    test "a no-principal denial is attributed to nobody", %{org_a: org_a} do
      %{task: task} = task_in!(org_a)

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, nil)

      assert [event] = denial_rows(task)
      assert event.actor_type == "anonymous"
      assert is_nil(event.actor_id)
    end

    test "a granted resolution emits nothing", %{org_a: org_a} do
      user = create_user!()
      plain_member!(user, org_a)
      %{task: task} = task_in!(org_a)

      assert {:ok, _task, :project_member} =
               TaskAccess.fetch_for_actor(task.id, {:user, user.id})

      assert denial_rows(task) == []
    end

    test "two denials write two rows", %{org_a: org_a} do
      # The stage-5 regression suite asserts "exactly one event per denial".
      # Pin the per-call cardinality here so that assertion has a floor.
      %{task: task} = task_in!(org_a)

      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, UUID.generate()})
      assert {:error, :forbidden} = TaskAccess.fetch_for_actor(task.id, {:agent, UUID.generate()})

      assert length(denial_rows(task)) == 2
    end
  end
end
