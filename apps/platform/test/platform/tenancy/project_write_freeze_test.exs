defmodule Platform.Tenancy.ProjectWriteFreezeTest do
  @moduledoc """
  Task 019f4eaa — the project write freeze.

  Hiding an archived project from listings is only half of "archived"; this is
  the half that makes it mean *locked*. Mirrors the proven channel freeze
  (`Platform.Chat.space_writable?/1`).

  The design under test — "freeze the front doors, let the machine drain":

    1. Verbs that INITIATE work are rejected with `{:error, :project_archived}`
       (create/edit/delete a task, create an epic, start a plan, create a
       stack/meeting/file, edit the project itself).
    2. Verbs the SYSTEM drives are deliberately NOT frozen. A task is a state
       machine advanced by TaskRouter, StackDeployer and the PR-merged
       webhook — freezing those would not lock an archived project, it would
       WEDGE it (TaskRouter re-dispatches after a failed transition, so the
       task would retry forever). Work already in flight drains to a terminal
       state; nothing new begins. The `in_flight` describe block below is the
       regression guard for that, and it is the load-bearing test in this file.
    3. Archiving stays reversible — the guard must never lock the lifecycle out
       of its own `archived_at` column.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Files
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stacks
  alias Platform.Tenancy
  alias Platform.Tenancy.Lifecycle
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ────────────────────────────────────────────────────────────

  defp admin_user! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "freeze-#{n}@example.com",
        name: "Freeze #{n}",
        oidc_sub: "oidc-freeze-#{n}"
      })
      |> Repo.insert!()

    # New users get a baseline "member" row on Fabrikam; upgrade rather than insert.
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    case Repo.get_by(OrgMembership, user_id: user.id, org_id: fabrikam.id) do
      nil ->
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: fabrikam.id, role: "admin"})
        |> Repo.insert!()

      existing ->
        existing |> Ecto.Changeset.change(%{role: "admin"}) |> Repo.update!()
    end

    user
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp project!(org) do
    n = System.unique_integer([:positive])
    {:ok, p} = Tasks.create_project(%{name: "Proj #{n}", org_id: org.id})
    p
  end

  defp task!(project, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, t} =
      Tasks.create_task(Map.merge(%{title: "Task #{n}", project_id: project.id}, attrs))

    t
  end

  defp archive!(admin, project) do
    {:ok, archived} = Tasks.archive_project(admin, project)
    archived
  end

  # ── The predicate ──────────────────────────────────────────────────────

  describe "project_writable?/1" do
    test "true for an active project, false once archived" do
      admin = admin_user!()
      project = project!(tenant_org!())

      assert Lifecycle.project_writable?(project.id)

      archive!(admin, project)
      refute Lifecycle.project_writable?(project.id)
    end

    test "false when the project is scheduled for deletion (schedule also stamps archived_at)" do
      admin = admin_user!()
      project = project!(tenant_org!())
      {:ok, _} = Tasks.schedule_project_deletion(admin, project)

      refute Lifecycle.project_writable?(project.id)
    end

    test "false when the project was cascade-hidden by an org archive" do
      admin = admin_user!()
      org = tenant_org!()
      project = project!(org)

      {:ok, _} = Tenancy.archive_org(admin, org)

      # The org cascade stamps archived_at on the child, so the same single
      # column freezes children of an archived org for free.
      refute Lifecycle.project_writable?(project.id)
    end

    test "unknown id is WRITABLE — let the write path surface its own not-found/FK error" do
      assert Lifecycle.project_writable?(Ecto.UUID.generate())
    end

    test "non-binary id falls through to :ok so changeset validation reports the real problem" do
      assert :ok == Lifecycle.ensure_project_writable(nil)
      assert :ok == Lifecycle.ensure_project_writable(%{})
    end

    test "regression: an empty-string id must not raise Ecto.Query.CastError" do
      # An unselected form dropdown submits project_id: "". It IS a binary, so
      # it slipped past the is_binary/1 guard and reached `where: p.id == ^""`,
      # raising CastError against UUIDv7 and taking the LiveView down with it.
      # A malformed id is not a project reference — fall through to :ok and let
      # validate_required report the real problem.
      assert Lifecycle.project_writable?("")
      assert :ok == Lifecycle.ensure_project_writable("")
      assert :ok == Lifecycle.ensure_task_project_writable("")
    end

    test "regression: a non-UUID id must not raise either" do
      assert Lifecycle.project_writable?("not-a-uuid")
      assert :ok == Lifecycle.ensure_project_writable("not-a-uuid")
      assert :ok == Lifecycle.ensure_task_project_writable("nope")
    end

    test "create_epic with a blank project_id reports a changeset error, not a crash" do
      # End-to-end shape of the bug above: the New Epic sheet submitting with
      # no project selected must surface inline validation, not a 500.
      assert {:error, %Ecto.Changeset{}} = Tasks.create_epic(%{name: "x", project_id: ""})
    end
  end

  # ── Front doors: rejected ──────────────────────────────────────────────

  describe "initiating verbs are frozen" do
    setup do
      admin = admin_user!()
      org = tenant_org!()
      project = project!(org)
      # A task that exists BEFORE the archive — the in-flight fixture.
      task = task!(project)
      archive!(admin, project)

      %{admin: admin, org: org, project: project, task: task}
    end

    test "create_task is rejected", %{project: project} do
      assert {:error, :project_archived} =
               Tasks.create_task(%{title: "nope", project_id: project.id})
    end

    test "create_task is rejected for string-keyed attrs too (MCP passes strings)", %{
      project: project
    } do
      assert {:error, :project_archived} =
               Tasks.create_task(%{"title" => "nope", "project_id" => project.id})
    end

    test "create_epic is rejected", %{project: project} do
      assert {:error, :project_archived} =
               Tasks.create_epic(%{name: "nope", project_id: project.id})
    end

    test "soft_delete_task is rejected", %{task: task} do
      assert {:error, :project_archived} = Tasks.soft_delete_task(task)
    end

    test "update_project is rejected", %{project: project} do
      assert {:error, :project_archived} = Tasks.update_project(project, %{name: "renamed"})
    end

    test "create_plan is rejected — the keystone", %{task: task} do
      # The hole a task-only guard would leave: an agent can plan a
      # PRE-EXISTING backlog task without ever calling create_task.
      assert {:error, :project_archived} =
               Tasks.create_plan(%{task_id: task.id, status: "draft"})
    end

    test "create_stack is rejected", %{project: project} do
      assert {:error, :project_archived} =
               Stacks.create_stack(%{
                 name: "nope",
                 slug: "nope-#{System.unique_integer([:positive])}",
                 project_id: project.id,
                 rollup_branch: "stack/nope"
               })
    end

    test "create_file is rejected", %{project: project} do
      assert {:error, :project_archived} =
               Files.create_file(%{
                 project_id: project.id,
                 path: "notes.md",
                 content_hash: "abc123",
                 byte_size: 3
               })
    end
  end

  # ── The drain: NOT frozen (the load-bearing guard) ─────────────────────

  describe "in_flight work still drains after archive" do
    setup do
      admin = admin_user!()
      project = project!(tenant_org!())
      task = task!(project, %{status: "in_progress"})
      archive!(admin, project)

      %{admin: admin, project: project, task: task}
    end

    test "an in-flight task can still reach done — freezing this would WEDGE the router", %{
      task: task
    } do
      # TaskRouter/StackDeployer/the PR-merged webhook drive this transition.
      # If the freeze caught it, TaskRouter would log the failure and
      # re-dispatch anyway — an infinite retry loop on a project nobody is
      # watching. Letting an already-taken decision finish is the design.
      assert {:ok, done} = Tasks.transition_task_status(Repo.reload!(task), "done")
      assert done.status == "done"
    end

    test "update_task still works on a pre-existing task (system-driven writes)", %{task: task} do
      assert {:ok, updated} = Tasks.update_task(Repo.reload!(task), %{title: "renamed by system"})
      assert updated.title == "renamed by system"
    end
  end

  # ── Reversibility ──────────────────────────────────────────────────────

  describe "archiving stays reversible" do
    test "unarchive re-opens the front doors" do
      admin = admin_user!()
      project = project!(tenant_org!())

      archived = archive!(admin, project)

      assert {:error, :project_archived} =
               Tasks.create_task(%{title: "blocked", project_id: project.id})

      # The lifecycle writes archived_at through its OWN private writer, so
      # guarding Tasks.update_project/2 can't lock archiving out of its column.
      assert {:ok, _restored} = Tasks.unarchive_project(admin, archived)
      assert {:ok, task} = Tasks.create_task(%{title: "allowed again", project_id: project.id})
      assert task.title == "allowed again"
    end

    test "restoring the ORG un-freezes its cascade-hidden children" do
      admin = admin_user!()
      org = tenant_org!()
      project = project!(org)

      {:ok, archived_org} = Tenancy.archive_org(admin, org)

      assert {:error, :project_archived} =
               Tasks.create_task(%{title: "blocked", project_id: project.id})

      {:ok, _} = Tenancy.unarchive_org(admin, archived_org)
      assert {:ok, _} = Tasks.create_task(%{title: "allowed", project_id: project.id})
    end
  end

  # ── cascade_preview: what the confirm dialog promises ──────────────────

  describe "cascade_preview/1" do
    # Marlowe kept the bulk cascade (2026-07-16) but asked the dialog to say what
    # it takes rather than "and everything under it". A preview is only worth
    # having if it matches the cascade EXACTLY — a dialog that misstates what
    # it's about to hide is worse than the vague one. Hence it reuses the
    # cascade's own predicate, and these tests pin that equivalence.

    test "lists the org's active children by name" do
      admin = admin_user!()
      org = tenant_org!()
      p = project!(org)
      {:ok, _} = Tasks.update_project(p, %{name: "Zebra Project"})
      _other = project!(org)

      preview = Lifecycle.cascade_preview(org.id)

      assert length(preview.projects) == 2
      assert "Zebra Project" in preview.projects
      # Nothing archived yet, so nothing is skipped.
      assert {:ok, _} = Tasks.archive_project(admin, Repo.reload!(p))
    end

    test "an already-archived child is ABSENT — the cascade skips it, so nothing changes for it" do
      admin = admin_user!()
      org = tenant_org!()

      keeper = project!(org)
      {:ok, _} = Tasks.update_project(keeper, %{name: "Still Active"})

      independent = project!(org)
      {:ok, _} = Tasks.update_project(independent, %{name: "Already Archived"})
      {:ok, _} = Tasks.archive_project(admin, Repo.reload!(independent))

      preview = Lifecycle.cascade_preview(org.id)

      # The list is what CHANGES, not an inventory of the org.
      assert preview.projects == ["Still Active"]
      refute "Already Archived" in preview.projects
    end

    test "matches what the cascade actually hides — the equivalence that makes it honest" do
      admin = admin_user!()
      org = tenant_org!()
      a = project!(org)
      b = project!(org)

      predicted = Lifecycle.cascade_preview(org.id)
      {:ok, _} = Tenancy.archive_org(admin, org)

      actually_hidden =
        [a, b]
        |> Enum.map(&Repo.reload!/1)
        |> Enum.filter(&(&1.archived_cascade_org_id == org.id))
        |> Enum.map(& &1.name)

      assert Enum.sort(predicted.projects) == Enum.sort(actually_hidden)
    end

    test "empty for an org with no active children" do
      org = tenant_org!()
      assert Lifecycle.cascade_preview(org.id) == %{projects: [], channels: []}
    end

    test "regression: a SLUG or malformed id must not raise CastError" do
      # The Tasks sidebar posts org SLUGS off its phx-click (id={org_slug});
      # Chat and Recovery post UUIDs. A slug reaching the query would raise
      # against UUIDv7 — the same trap as the empty-string project_id above.
      # PlatformWeb.LifecycleActions.cascade_preview/2 resolves slug->UUID;
      # this is the belt-and-braces half.
      assert Lifecycle.cascade_preview("paragon") == %{projects: [], channels: []}
      assert Lifecycle.cascade_preview("") == %{projects: [], channels: []}
      assert Lifecycle.cascade_preview(nil) == %{projects: [], channels: []}
      assert Lifecycle.cascade_preview(Ecto.UUID.generate()) == %{projects: [], channels: []}
    end
  end

  # ── Active projects are untouched ──────────────────────────────────────

  describe "an active project is unaffected" do
    test "every guarded verb still works" do
      project = project!(tenant_org!())

      assert {:ok, task} = Tasks.create_task(%{title: "fine", project_id: project.id})
      assert {:ok, _} = Tasks.create_epic(%{name: "fine", project_id: project.id})
      assert {:ok, _} = Tasks.update_project(project, %{name: "renamed fine"})
      assert {:ok, _} = Tasks.soft_delete_task(task)
    end
  end
end
