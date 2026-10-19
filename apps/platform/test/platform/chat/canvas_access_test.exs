defmodule Platform.Chat.CanvasAccessTest do
  @moduledoc """
  Canvas read authorization — task 019e2c4b stage 1, extended by task 019fb01b
  stage 2 (`:task_agent`).

  This module decides who may read a canvas through the standalone
  `/canvases/:id` page and the MCP canvas surface, so every grant path and
  every denial is asserted explicitly rather than inferred from a happy path.

  Covers:

    * `:member` — space participation, including in an execution space
    * `:task_agent` — an AGENT named in an attached live task's
      `phase_assignees`, including a non-current phase slot and survival across
      a phase rotation, plus the denials that keep the grant narrow
      (attribution-only, `"user"`-typed slot, untyped slot, foreign task,
      soft-deleted task, detached canvas)
    * `:task_reader` — attachment to a live task in an org the viewer belongs
      to, including the incident shape (canvas in an EXECUTION space)
    * `:org_reader` — accessible non-archived CHANNEL with a non-nil org, for
      an org member or an Acme admin
    * external users are capped at `:member`
    * a null `org_id` DENIES (DMs and groups)
    * execution and archived spaces are excluded from `:org_reader`
    * `:not_found` and `:forbidden` are distinct return values
    * soft-deleted canvases: `:not_found` without a grant, `{:ok, …}` with one
    * audit rows for `:task_agent` / `:task_reader` / `:org_reader`, none for
      `:member`
    * no read grant confers write
  """

  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Ecto.UUID
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasAccess
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    %{org_a: Tenancy.get_org_by_slug!("globex"), org_b: Tenancy.get_org_by_slug!("initech")}
  end

  # ── Builders ──────────────────────────────────────────────────────────────

  defp space!(attrs) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "CA Space #{n}", slug: "ca-space-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # `chat_canvases.created_by` is FK-constrained to a participant row, so every
  # canvas needs an author IN its space. The author is deliberately a throwaway
  # user distinct from any viewer under test — an author who happened to be the
  # viewer would hand every case a free `:member` grant.
  defp canvas!(space, overrides \\ %{}) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(
        Map.merge(
          %{
            "space_id" => space.id,
            "created_by" => author.id,
            "title" => "Canvas #{System.unique_integer([:positive])}"
          },
          overrides
        )
      )

    canvas
  end

  defp acme_admin! do
    user = create_user!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "admin"})
    |> Repo.insert!()

    user
  end

  defp task_in!(org) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "CA Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "CA Task"})
    %{project: project, task: task}
  end

  defp attach!(task, canvas) do
    {:ok, attachment} =
      CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "user", id: UUID.generate()}
      )

    attachment
  end

  # Attribution, not authorization. Used only to prove that the agent named on
  # the attachment row gets nothing from having put the row there.
  defp attach_as_agent!(task, canvas, agent_id) do
    {:ok, attachment} =
      CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "agent", id: agent_id}
      )

    attachment
  end

  # Bind an agent to one phase slot through the canonical writer
  # (`Tasks.set_phase_assignees/2`, ADR-0044) rather than a raw changeset, so
  # the fixture cannot drift from the shape the column actually holds.
  defp bind_agent!(task, phase, agent_id) do
    {:ok, updated} =
      Tasks.set_phase_assignees(task, %{
        phase => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
      })

    updated
  end

  # Write one phase slot verbatim, bypassing the canonical writer, so the
  # malformed-slot denials can construct shapes `set_phase_assignees/2` would
  # never emit.
  defp put_phase_slot!(task, phase, slot) do
    task
    |> Ecto.Changeset.change(%{
      phase_assignees: Map.put(task.phase_assignees || %{}, phase, slot)
    })
    |> Repo.update!()
  end

  defp soft_delete_canvas!(canvas) do
    canvas
    |> Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp canvas_audit_rows(canvas) do
    Audit.list(resource_type: "canvas", resource_id: canvas.id)
  end

  # ── 1. :member ────────────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :member" do
    test "a space participant reads their own space's canvas", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, %Canvas{id: id}, :member} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert id == canvas.id
    end

    test "membership still works inside an EXECUTION space" do
      # Execution spaces are closed to org REACH, not to their own participants.
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "an EXTERNAL user who participates still gets :member", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      ext = external_user!(org_a)
      add_user!(space.id, ext.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, ext)
    end

    test "a :member read is NOT audited", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert canvas_audit_rows(canvas) == []
    end

    test "an agent-type participant row does not confer :member on a user of the same id",
         %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_agent!(space.id, user.id)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end
  end

  # ── 2. :task_reader ───────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :task_reader" do
    test "a non-member in the attached task's project org reads the canvas", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "reaches a canvas in an EXECUTION space — the reported incident shape", %{
      org_a: org_a
    } do
      # Execution spaces are excluded by `space_accessible?/1`, so :org_reader
      # cannot help here. Without :task_reader the reviewer stays locked out.
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a viewer in a DIFFERENT org than the task's project is denied", %{
      org_a: org_a,
      org_b: org_b
    } do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_b)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a soft-deleted task no longer confers the grant", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)
      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)

      {:ok, _deleted} = Tasks.soft_delete_task(task)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    # There is deliberately NO org-less-project case here: `projects.org_id` is
    # NOT NULL in the schema, so the state cannot exist. That asymmetry with
    # `chat_spaces` — where null org is the DM/group norm and is denied
    # explicitly below — is why the two arms are written differently.

    test "the resolution is audited", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)

      assert [event] = canvas_audit_rows(canvas)
      assert event.event_type == "platform.chat.canvas_read"
      assert event.actor_id == user.id
      assert event.actor_type == "user"
      assert event.action == "read"
      assert event.resource_id == canvas.id
      assert event.metadata["grant"] == "task_reader"
      assert event.metadata["space_id"] == space.id
    end
  end

  # ── 2b. :task_agent ───────────────────────────────────────────────────────
  #
  # Task 019fb01b stage 2. The agent analogue of `:task_reader`: an agent bound
  # to a task by `phase_assignees` may read the canvases attached to that task.

  describe "fetch_for_viewer/3 — :task_agent" do
    test "an agent bound to a phase of an attached task reads the canvas", %{org_a: org_a} do
      # The designer's own space, which the bound agent does not participate in
      # — the ADR-0046 native path that `:member` cannot reach.
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      bind_agent!(task, "execution", agent_id)

      assert {:ok, %Canvas{id: id}, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})

      assert id == canvas.id
    end

    test "reaches a canvas in an EXECUTION space the agent is not rostered in", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      bind_agent!(task, "planning", agent_id)

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "a NON-current phase slot is enough — every slot is read", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      # A freshly created task is `backlog`, whose phase is "planning". Binding
      # "review" leaves the flat current-phase pointer untouched, so this agent
      # is reachable ONLY through the map.
      updated = bind_agent!(task, "review", agent_id)
      assert updated.assignee_id == nil
      assert updated.assignee_type == nil

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "the grant survives a phase rotation", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      planner = UUID.generate()
      executor = UUID.generate()
      task = bind_agent!(task, "planning", planner)
      task = bind_agent!(task, "execution", executor)
      assert task.assignee_id == planner

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, planner})

      # backlog → in_progress moves the current phase to "execution", and the
      # flat pointer is re-derived off the execution slot. This is the exact
      # rotation that would have revoked a grant keyed on `assignee_id`.
      {:ok, rotated} = Tasks.transition_task_status(task, "in_progress")
      assert Tasks.current_phase(rotated) == "execution"
      assert rotated.assignee_id == executor

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, planner})
    end

    test "both agents on a two-phase task resolve", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      planner = UUID.generate()
      executor = UUID.generate()
      task = bind_agent!(task, "planning", planner)
      bind_agent!(task, "execution", executor)

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, planner})

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, executor})
    end

    test ":member outranks :task_agent when the agent is also in the space", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)
      bind_agent!(task, "execution", agent_id)

      assert {:ok, _canvas, :member} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "the resolution is audited as an AGENT read", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      bind_agent!(task, "execution", agent_id)

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})

      assert [event] = canvas_audit_rows(canvas)
      assert event.event_type == "platform.chat.canvas_read"
      assert event.actor_id == agent_id
      assert event.actor_type == "agent"
      assert event.action == "read"
      assert event.resource_id == canvas.id
      assert event.metadata["grant"] == "task_agent"
      assert event.metadata["space_id"] == space.id
    end

    test "a soft-deleted canvas still resolves for a bound agent", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      bind_agent!(task, "execution", agent_id)
      soft_delete_canvas!(canvas)

      assert {:ok, %Canvas{deleted_at: %DateTime{}}, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end
  end

  describe "fetch_for_viewer/3 — :task_agent denials" do
    test "attaching the canvas grants the ATTACHER nothing", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)

      designer_id = UUID.generate()
      attach_as_agent!(task, canvas, designer_id)

      # `attached_by_id` is attribution. The designer appears in no phase slot.
      assert {:error, :forbidden} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, designer_id})
    end

    test "a phase slot typed \"user\" denies an agent of the same id", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      id = UUID.generate()
      put_phase_slot!(task, "execution", %{"assignee_id" => id, "assignee_type" => "user"})

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, id})
    end

    test "a phase slot with no assignee_type denies — the type must be stated", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      id = UUID.generate()
      put_phase_slot!(task, "execution", %{"assignee_id" => id})

      # `Tasks.per_phase_assignee/2` defaults a type-less slot to "agent". This
      # grant deliberately does not: an untyped id could be a user id, and
      # handing an agent a grant off an ambiguous row is the wrong direction to
      # fail in.
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, id})
    end

    test "a flat-pair-only assignment does NOT confer the grant", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{project: project} = task_in!(org_a)

      agent_id = UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Flat pair only",
          assignee_type: "agent",
          assignee_id: agent_id
        })

      attach!(task, canvas)
      assert task.phase_assignees == %{}

      # ADR-0044 routes flat writes into the current-phase slot at the MCP and
      # LiveView boundaries, which is what keeps `phase_assignees` a superset in
      # practice. A raw `create_task/1` skips that routing, and `task_start` is
      # named in ADR-0044's Deferred section as still writing flat directly. The
      # grant reads the map only, so those bindings deny. Fail-closed and
      # deliberate; widening it means fixing the writers, not the reader.
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "a bound agent is denied a canvas attached to a DIFFERENT task", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: attached_task} = task_in!(org_a)
      attach!(attached_task, canvas)

      %{task: other_task} = task_in!(org_a)
      agent_id = UUID.generate()
      bind_agent!(other_task, "execution", agent_id)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "a soft-deleted task no longer confers the grant", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      task = bind_agent!(task, "execution", agent_id)

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})

      {:ok, _deleted} = Tasks.soft_delete_task(task)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "detaching the canvas revokes the grant", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      bind_agent!(task, "execution", agent_id)

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})

      # `:system` because the subject here is CanvasAccess.fetch_for_viewer/3,
      # not the detach gate. Task 019fb581 gave detach_canvas an actor as its
      # FIRST argument; driving that gate is the job of
      # task_canvas_attachment_authorization_test.exs, so this setup step opts
      # out of it rather than restating it.
      :ok = CanvasAttachments.detach_canvas(:system, task.id, canvas.id)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "a USER viewer gets nothing from an agent phase slot carrying their id", %{
      org_a: org_a,
      org_b: org_b
    } do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      # Org B membership so `:task_reader` (org A's project) cannot answer for
      # them, and `:org_reader` cannot either.
      user = create_user!()
      plain_member!(user, org_b)
      bind_agent!(task, "execution", user.id)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:user, user.id})
    end

    test "a soft-deleted canvas is :not_found for an UNBOUND agent", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)
      soft_delete_canvas!(canvas)

      assert {:error, :not_found} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, UUID.generate()})
    end
  end

  describe "fetch_for_writer/2 — :task_agent does not confer write" do
    test "a bound agent that reads the canvas may not write it", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      agent_id = UUID.generate()
      bind_agent!(task, "execution", agent_id)

      assert {:ok, _canvas, :task_agent} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})

      assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, {:agent, agent_id})
    end
  end

  # ── 3. :org_reader ────────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :org_reader" do
    test "an org member reads a canvas in a channel owned by that org", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "an Acme admin reads a channel canvas in any org", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, acme_admin!())
    end

    test "a member of a DIFFERENT org is denied", %{org_a: org_a, org_b: org_b} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_b)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a NULL org_id denies — a channel with no org is not org-readable", %{org_a: org_a} do
      space = space!(%{org_id: nil})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a NULL org_id denies an Acme admin too" do
      # DMs and group conversations never set org_id. If null were a wildcard,
      # every private conversation in the product would be org-readable.
      space = space!(%{org_id: nil})
      canvas = canvas!(space)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, acme_admin!())
    end

    test "a GROUP space with an org_id is still denied — channels only", %{org_a: org_a} do
      space = space!(%{kind: "group", org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "a DM space with an org_id is still denied", %{org_a: org_a} do
      space = space!(%{kind: "dm", org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "an EXECUTION space is excluded even with a matching org_id", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "an ARCHIVED channel is excluded", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      {:ok, _archived} = Chat.archive_space(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "the resolution is audited", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)

      assert [event] = canvas_audit_rows(canvas)
      assert event.event_type == "platform.chat.canvas_read"
      assert event.metadata["grant"] == "org_reader"
      assert event.actor_id == user.id
    end
  end

  # ── External users are capped at :member ──────────────────────────────────

  describe "fetch_for_viewer/3 — external users" do
    test "an external org member gets NO :org_reader on a channel in their own org", %{
      org_a: org_a
    } do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      ext = external_user!(org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, ext)
    end

    test "an external org member gets NO :task_reader", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      ext = external_user!(org_a)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, ext)
    end
  end

  # ── :not_found vs :forbidden ──────────────────────────────────────────────

  describe "fetch_for_viewer/3 — :not_found is distinct from :forbidden" do
    test "an unknown canvas id is :not_found, not :forbidden" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(UUID.generate(), create_user!())
    end

    test "a malformed id is :not_found rather than a raise" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer("not-a-uuid", create_user!())
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(<<1::128>>, create_user!())
      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(nil, create_user!())
    end

    test "an existing canvas the viewer cannot reach is :forbidden, not :not_found", %{
      org_a: org_a
    } do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)

      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, create_user!())
    end

    test "a nil viewer is :forbidden on a live canvas", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, nil)
    end
  end

  # ── Soft-deleted canvases ─────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — soft-deleted canvases" do
    test "resolve to :not_found for a viewer with NO grant", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(canvas.id, create_user!())
    end

    test "resolve to :not_found for a nil viewer", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      assert {:error, :not_found} = CanvasAccess.fetch_for_viewer(canvas.id, nil)
    end

    test "still resolve for a grant holder so the renderer can say 'removed'", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)
      soft_delete_canvas!(canvas)

      assert {:ok, %Canvas{deleted_at: %DateTime{}}, :member} =
               CanvasAccess.fetch_for_viewer(canvas.id, user)
    end

    test "still resolve for an :org_reader grant holder", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, %Canvas{deleted_at: %DateTime{}}, :org_reader} =
               CanvasAccess.fetch_for_viewer(canvas.id, user)
    end
  end

  # ── Audit opt-out ─────────────────────────────────────────────────────────

  describe "fetch_for_viewer/3 — audit: false" do
    test "suppresses the audit row for a LiveView remount", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} =
               CanvasAccess.fetch_for_viewer(canvas.id, user, audit: false)

      assert canvas_audit_rows(canvas) == []
    end
  end

  # ══ STAGE 2 ═══════════════════════════════════════════════════════════════
  #
  # Actor shapes and the write door. Everything above resolves READ for a
  # `%User{}`; everything below covers the `t:actor/0` triple and
  # `fetch_for_writer/2`.

  # ── Actor shapes on the read door ─────────────────────────────────────────

  describe "fetch_for_viewer/3 — actor shapes" do
    test "{:user, id} resolves identically to a %User{}", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas, :member} = CanvasAccess.fetch_for_viewer(canvas.id, {:user, user.id})
    end

    test "an agent participant of the space gets :member", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      assert {:ok, _canvas, :member} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, agent_id})
    end

    test "an agent that does not participate is forbidden", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:error, :forbidden} =
               CanvasAccess.fetch_for_viewer(canvas.id, {:agent, UUID.generate()})
    end

    # The org-reach paths query `org_memberships.user_id`. Sharing an id with a
    # user who WOULD qualify must not smuggle an agent through them.
    test "an agent never reaches :org_reader, even sharing an id with an org member",
         %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, user.id})
    end

    test "an agent never reaches :task_reader, even sharing an id with an org member",
         %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, {:agent, user.id})
    end

    test "an unrecognised actor shape is denied, never promoted to :system", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      for bogus <- [nil, :agent, {:user, nil}, {:agent, 42}, "a-string", %{}] do
        assert {:error, :forbidden} = CanvasAccess.fetch_for_viewer(canvas.id, bogus)
      end
    end
  end

  # ── fetch_for_writer/2 ────────────────────────────────────────────────────

  describe "fetch_for_writer/2 — grants" do
    test "a space participant may write", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, %Canvas{id: id}} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
      assert id == canvas.id
    end

    test "an agent participant may write", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      add_agent!(space.id, agent_id)

      assert {:ok, _canvas} = CanvasAccess.fetch_for_writer(canvas.id, {:agent, agent_id})
    end

    test "the :system actor may write", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      assert {:ok, _canvas} = CanvasAccess.fetch_for_writer(canvas.id, :system)
    end
  end

  describe "fetch_for_writer/2 — read levels do not confer write" do
    test "an :org_reader is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      user = create_user!()
      plain_member!(user, org_a)

      # Reads fine …
      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      # … and must not write.
      assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
    end

    test "a :task_reader is rejected", %{org_a: org_a} do
      space = space!(%{kind: "execution", org_id: nil})
      canvas = canvas!(space)
      %{task: task} = task_in!(org_a)
      attach!(task, canvas)

      user = create_user!()
      plain_member!(user, org_a)

      assert {:ok, _canvas, :task_reader} = CanvasAccess.fetch_for_viewer(canvas.id, user)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
    end

    test "an Acme admin with no participation is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      admin = acme_admin!()

      assert {:ok, _canvas, :org_reader} = CanvasAccess.fetch_for_viewer(canvas.id, admin)
      assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, {:user, admin.id})
    end

    test "an unidentified actor is rejected", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))

      for bogus <- [nil, :agent, {:user, nil}, "a-string"] do
        assert {:error, :forbidden} = CanvasAccess.fetch_for_writer(canvas.id, bogus)
      end
    end
  end

  describe "fetch_for_writer/2 — missing and deleted canvases" do
    test "a non-existent id is :not_found" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_writer(UUID.generate(), :system)
    end

    test "a malformed id is :not_found" do
      assert {:error, :not_found} = CanvasAccess.fetch_for_writer("not-a-uuid", :system)
    end

    # The read door deliberately hands a soft-deleted canvas back to a
    # grant-holder so the renderer can say "removed". The write door must not
    # inherit that: every pre-existing write path went through
    # `Chat.get_canvas/2`, which filters `deleted_at`.
    test "a soft-deleted canvas is :not_found for a member, though it READS", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)
      soft_delete_canvas!(canvas)

      assert {:ok, %Canvas{deleted_at: %DateTime{}}, :member} =
               CanvasAccess.fetch_for_viewer(canvas.id, user)

      assert {:error, :not_found} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
    end

    test "a soft-deleted canvas is :not_found even for :system", %{org_a: org_a} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      soft_delete_canvas!(canvas)

      assert {:error, :not_found} = CanvasAccess.fetch_for_writer(canvas.id, :system)
    end
  end

  describe "fetch_for_writer/2 — no audit" do
    test "resolving write intent does not mint a canvas_read row", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      user = create_user!()
      add_user!(space.id, user.id)

      assert {:ok, _canvas} = CanvasAccess.fetch_for_writer(canvas.id, {:user, user.id})
      assert canvas_audit_rows(canvas) == []
    end
  end
end
