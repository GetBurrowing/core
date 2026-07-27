defmodule Platform.Tenancy.LifecycleTest do
  @moduledoc """
  Task 019f4eaa stage 3 — org/project archive · schedule-deletion · restore
  with a provenance-aware cascade.

  Invariants under test:

    1. Every lifecycle function requires a Fabrikam admin actor (no creator
       carve-out, no system path). Root org is never deletable.
    2. Archiving/scheduling an org cascade-hides its child projects and
       chat_spaces IN ONE transaction, but only children that are not
       already archived — an independently-archived child keeps a NULL
       `archived_cascade_org_id`.
    3. Restore un-hides ONLY the children this org drove; an
       independently-archived child is left hidden (the provenance skip).
    4. `create_project`/`create_space` refuse an archived-or-scheduled org.
    5. Each action records a bridged audit event.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Lifecycle
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "lifecycle-#{n}@example.com",
          name: "Lifecycle #{n}",
          oidc_sub: "oidc-lifecycle-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp membership!(user, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: role
    })
    |> Repo.insert!()
  end

  defp admin_user! do
    user = create_user!()
    membership!(user, "admin")
    user
  end

  defp member_user! do
    user = create_user!()
    membership!(user, "member")
    user
  end

  # A fresh tenant org parented to Fabrikam — isolated from the seeded tenants
  # so archiving it can't perturb anything else.
  defp tenant_org!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    default = %{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    }

    %Org{} |> Org.changeset(Map.merge(default, attrs)) |> Repo.insert!()
  end

  defp project!(org, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(Map.merge(%{name: "Proj #{n}", org_id: org.id}, attrs))
    project
  end

  defp channel!(org, attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "Chan #{n}", slug: "chan-#{n}", kind: "channel", org_id: org.id}, attrs)
      )

    space
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── Org archive / unarchive round-trip + cascade ───────────────────────

  describe "archive_org/2 + unarchive_org/2" do
    test "hides the org and cascade-hides active children; unarchive restores all" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)

      assert {:ok, archived_org} = Tenancy.archive_org(admin, org)
      assert %DateTime{} = archived_org.archived_at

      proj = Repo.reload!(proj)
      chan = Repo.reload!(chan)
      assert %DateTime{} = proj.archived_at
      assert proj.archived_cascade_org_id == org.id
      assert %DateTime{} = chan.archived_at
      assert chan.archived_cascade_org_id == org.id

      assert {:ok, restored_org} = Tenancy.unarchive_org(admin, archived_org)
      assert is_nil(restored_org.archived_at)

      proj = Repo.reload!(proj)
      chan = Repo.reload!(chan)
      assert is_nil(proj.archived_at)
      assert is_nil(proj.archived_cascade_org_id)
      assert is_nil(chan.archived_at)
      assert is_nil(chan.archived_cascade_org_id)
    end
  end

  # ── Org schedule / cancel ──────────────────────────────────────────────

  describe "schedule_org_deletion/2 + cancel_org_deletion/2" do
    test "schedule sets both flags and cascades; cancel restores" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)

      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)
      assert %DateTime{} = scheduled.archived_at
      assert %DateTime{} = scheduled.deletion_scheduled_at

      proj = Repo.reload!(proj)
      assert %DateTime{} = proj.archived_at
      assert proj.archived_cascade_org_id == org.id

      assert {:ok, cancelled} = Tenancy.cancel_org_deletion(admin, scheduled)
      assert is_nil(cancelled.archived_at)
      assert is_nil(cancelled.deletion_scheduled_at)

      proj = Repo.reload!(proj)
      assert is_nil(proj.archived_at)
      assert is_nil(proj.archived_cascade_org_id)
    end

    test "cancel returns :not_scheduled when nothing is pending" do
      admin = admin_user!()
      org = tenant_org!()
      assert {:error, :not_scheduled} = Tenancy.cancel_org_deletion(admin, org)
    end
  end

  # ── The provenance skip (the critical case) ────────────────────────────

  describe "provenance-aware cascade" do
    test "cascade stamps only non-already-archived children, and restore does NOT un-hide an independently-archived child" do
      admin = admin_user!()
      org = tenant_org!()

      # Children that are active at org-archive time → cascade-hidden.
      cascaded_proj = project!(org)
      cascaded_chan = channel!(org)

      # Children archived independently BEFORE the org archive → must be
      # SKIPPED by the cascade (no provenance stamp) and left hidden by the
      # later restore.
      independent_proj = project!(org)
      independent_chan = channel!(org)
      {:ok, independent_proj} = Tasks.archive_project(admin, independent_proj)
      {:ok, independent_chan} = Chat.archive_space(admin, independent_chan)

      assert %DateTime{} = independent_proj.archived_at
      assert is_nil(independent_proj.archived_cascade_org_id)
      assert %DateTime{} = independent_chan.archived_at
      assert is_nil(independent_chan.archived_cascade_org_id)

      # Archive the org.
      assert {:ok, _} = Tenancy.archive_org(admin, org)

      cascaded_proj = Repo.reload!(cascaded_proj)
      cascaded_chan = Repo.reload!(cascaded_chan)
      independent_proj = Repo.reload!(independent_proj)
      independent_chan = Repo.reload!(independent_chan)

      # Active children were stamped with this org's provenance.
      assert cascaded_proj.archived_cascade_org_id == org.id
      assert cascaded_chan.archived_cascade_org_id == org.id

      # Already-archived children were skipped — provenance stays NULL.
      assert is_nil(independent_proj.archived_cascade_org_id)
      assert is_nil(independent_chan.archived_cascade_org_id)

      independent_proj_at = independent_proj.archived_at
      independent_chan_at = independent_chan.archived_at

      # Restore the org.
      assert {:ok, _} = Tenancy.unarchive_org(admin, org)

      cascaded_proj = Repo.reload!(cascaded_proj)
      cascaded_chan = Repo.reload!(cascaded_chan)
      independent_proj = Repo.reload!(independent_proj)
      independent_chan = Repo.reload!(independent_chan)

      # Cascade children are back to active.
      assert is_nil(cascaded_proj.archived_at)
      assert is_nil(cascaded_proj.archived_cascade_org_id)
      assert is_nil(cascaded_chan.archived_at)
      assert is_nil(cascaded_chan.archived_cascade_org_id)

      # THE KEY ASSERTION: independently-archived children are NOT
      # over-restored — their archived_at is untouched.
      assert independent_proj.archived_at == independent_proj_at
      assert is_nil(independent_proj.archived_cascade_org_id)
      assert independent_chan.archived_at == independent_chan_at
      assert is_nil(independent_chan.archived_cascade_org_id)
    end
  end

  # ── Per-child deletion clock (task 019f760f stage 1) ───────────────────

  describe "per-child deletion clock on cascade" do
    test "schedule_org_deletion stamps each cascade child's own deletion clock with the org's" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)

      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)
      assert %DateTime{} = scheduled.deletion_scheduled_at

      proj = Repo.reload!(proj)
      chan = Repo.reload!(chan)

      # Each cascade child inherits the org's OWN deletion timestamp — not nil.
      assert proj.deletion_scheduled_at == scheduled.deletion_scheduled_at
      assert %DateTime{} = proj.archived_at
      assert proj.archived_cascade_org_id == org.id

      assert chan.deletion_scheduled_at == scheduled.deletion_scheduled_at
      assert %DateTime{} = chan.archived_at
      assert chan.archived_cascade_org_id == org.id
    end

    test "archive_org hides children but leaves their deletion clock nil (no countdown on plain archive)" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)

      assert {:ok, _} = Tenancy.archive_org(admin, org)

      proj = Repo.reload!(proj)
      chan = Repo.reload!(chan)

      # Archive hides + stamps provenance …
      assert %DateTime{} = proj.archived_at
      assert proj.archived_cascade_org_id == org.id
      assert %DateTime{} = chan.archived_at
      assert chan.archived_cascade_org_id == org.id

      # … but must NOT start a deletion countdown on the children.
      assert is_nil(proj.deletion_scheduled_at)
      assert is_nil(chan.deletion_scheduled_at)
    end

    test "cancel_org_deletion clears each cascade child's deletion clock and provenance marker" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)

      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)

      # Sanity: children are counting down before the cancel.
      assert Repo.reload!(proj).deletion_scheduled_at == scheduled.deletion_scheduled_at
      assert Repo.reload!(chan).deletion_scheduled_at == scheduled.deletion_scheduled_at

      assert {:ok, cancelled} = Tenancy.cancel_org_deletion(admin, scheduled)
      assert is_nil(cancelled.deletion_scheduled_at)

      proj = Repo.reload!(proj)
      chan = Repo.reload!(chan)

      # Cancelling the org's deletion must stop the children's clocks too —
      # otherwise a reprieved org's children keep counting down.
      assert is_nil(proj.deletion_scheduled_at)
      assert is_nil(proj.archived_cascade_org_id)
      assert is_nil(proj.archived_at)
      assert is_nil(chan.deletion_scheduled_at)
      assert is_nil(chan.archived_cascade_org_id)
      assert is_nil(chan.archived_at)
    end

    test "unarchive_org also clears a cascade child's deletion clock" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)

      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)
      assert Repo.reload!(proj).deletion_scheduled_at == scheduled.deletion_scheduled_at

      assert {:ok, restored} = Tenancy.unarchive_org(admin, scheduled)
      assert is_nil(restored.deletion_scheduled_at)

      proj = Repo.reload!(proj)
      assert is_nil(proj.deletion_scheduled_at)
      assert is_nil(proj.archived_cascade_org_id)
      assert is_nil(proj.archived_at)
    end
  end

  # ── Authorization + root guard ─────────────────────────────────────────

  describe "authorization" do
    test "non-admin actor is rejected and nothing is written" do
      member = member_user!()
      org = tenant_org!()

      assert {:error, :unauthorized} = Tenancy.archive_org(member, org)
      assert {:error, :unauthorized} = Tenancy.schedule_org_deletion(member, org)
      assert is_nil(Repo.reload!(org).archived_at)
    end

    test "nil actor is rejected" do
      org = tenant_org!()
      assert {:error, :unauthorized} = Tenancy.archive_org(nil, org)
    end

    test "root org (Fabrikam) is never deletable, for any org function" do
      admin = admin_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      assert {:error, :not_deletable} = Tenancy.archive_org(admin, fabrikam)
      assert {:error, :not_deletable} = Tenancy.schedule_org_deletion(admin, fabrikam)
      assert {:error, :not_deletable} = Tenancy.unarchive_org(admin, fabrikam)
      assert {:error, :not_deletable} = Tenancy.cancel_org_deletion(admin, fabrikam)
      assert is_nil(Repo.reload!(fabrikam).archived_at)
    end
  end

  # ── Create-time guard ──────────────────────────────────────────────────

  describe "create-time guard" do
    test "create_project rejects an archived target org" do
      admin = admin_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.archive_org(admin, org)

      assert {:error, changeset} = Tasks.create_project(%{name: "New", org_id: org.id})
      assert %{org_id: [_ | _]} = errors_on(changeset)
    end

    test "create_project rejects a deletion-scheduled target org" do
      admin = admin_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)

      assert {:error, changeset} = Tasks.create_project(%{name: "New", org_id: org.id})
      assert %{org_id: [_ | _]} = errors_on(changeset)
    end

    test "create_space rejects an archived target org" do
      admin = admin_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.archive_org(admin, org)
      n = System.unique_integer([:positive, :monotonic])

      assert {:error, changeset} =
               Chat.create_space(%{name: "X", slug: "x-#{n}", kind: "channel", org_id: org.id})

      assert %{org_id: [_ | _]} = errors_on(changeset)
    end

    test "create_project still succeeds for an active org" do
      org = tenant_org!()
      assert {:ok, _} = Tasks.create_project(%{name: "OK", org_id: org.id})
    end

    test "create_space with no org_id is unaffected by the guard" do
      n = System.unique_integer([:positive, :monotonic])
      assert {:ok, _} = Chat.create_space(%{name: "NoOrg", slug: "noorg-#{n}", kind: "channel"})
    end
  end

  # ── Project lifecycle (single-row) ─────────────────────────────────────

  describe "project lifecycle" do
    test "archive → unarchive round-trip; never stamps provenance" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)

      assert {:ok, archived} = Tasks.archive_project(admin, proj)
      assert %DateTime{} = archived.archived_at
      # single-row archive is not a cascade — no provenance marker
      assert is_nil(archived.archived_cascade_org_id)

      assert {:ok, restored} = Tasks.unarchive_project(admin, archived)
      assert is_nil(restored.archived_at)
      assert is_nil(restored.deletion_scheduled_at)
    end

    test "schedule → cancel round-trip; :not_scheduled when idle" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)

      assert {:error, :not_scheduled} = Tasks.cancel_project_deletion(admin, proj)

      assert {:ok, scheduled} = Tasks.schedule_project_deletion(admin, proj)
      assert %DateTime{} = scheduled.archived_at
      assert %DateTime{} = scheduled.deletion_scheduled_at

      assert {:ok, cancelled} = Tasks.cancel_project_deletion(admin, scheduled)
      assert is_nil(cancelled.archived_at)
      assert is_nil(cancelled.deletion_scheduled_at)
    end

    test "unarchive_project clears a cascade child's provenance marker + clock" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)

      # Hide the project as a cascade child of the org: schedule stamps the
      # provenance marker AND its own deletion clock on every child.
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      hidden = Repo.reload!(proj)
      assert hidden.archived_cascade_org_id == org.id
      assert %DateTime{} = hidden.deletion_scheduled_at

      # Restoring the single child directly (the future Recovery-hub path)
      # must clear the stale marker — otherwise a later org restore would
      # wrongly re-match this live project via cascade_children_query.
      assert {:ok, restored} = Tasks.unarchive_project(admin, hidden)
      assert is_nil(restored.archived_at)
      assert is_nil(restored.deletion_scheduled_at)
      assert is_nil(restored.archived_cascade_org_id)
    end

    test "cancel_project_deletion clears a cascade child's provenance marker" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)

      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      hidden = Repo.reload!(proj)
      assert hidden.archived_cascade_org_id == org.id
      assert %DateTime{} = hidden.deletion_scheduled_at

      assert {:ok, cancelled} = Tasks.cancel_project_deletion(admin, hidden)
      assert is_nil(cancelled.archived_at)
      assert is_nil(cancelled.deletion_scheduled_at)
      assert is_nil(cancelled.archived_cascade_org_id)
    end

    test "rejects a non-admin actor" do
      member = member_user!()
      org = tenant_org!()
      proj = project!(org)
      assert {:error, :unauthorized} = Tasks.archive_project(member, proj)
    end
  end

  # ── Audit trail ────────────────────────────────────────────────────────

  describe "audit" do
    setup do
      # Guarantee the telemetry→audit bridge is attached so the new
      # `[:platform, :tenancy | :tasks, …]` events actually persist. If any
      # is missing from TelemetryHandler @events the row silently won't
      # exist — which these tests would then catch.
      Platform.Audit.TelemetryHandler.detach()
      Platform.Audit.TelemetryHandler.attach()

      on_exit(fn ->
        Platform.Audit.TelemetryHandler.detach()
        Platform.Audit.TelemetryHandler.attach()
      end)

      :ok
    end

    test "archive_org emits telemetry AND persists a bridged audit row" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :tenancy, :org_archived]])

      admin = admin_user!()
      org = tenant_org!()
      assert {:ok, _} = Tenancy.archive_org(admin, org)

      assert_receive {[:platform, :tenancy, :org_archived], ^ref, _m, meta}
      assert meta.actor_id == admin.id
      assert meta.actor_type == "user"
      assert meta.resource_type == "org"
      assert meta.resource_id == org.id

      assert [event] = Audit.list(event_type: "platform.tenancy.org_archived")
      assert event.actor_id == admin.id
      assert event.actor_type == "user"
      assert event.resource_type == "org"
      assert event.resource_id == org.id
      assert event.action == "org_archived"
    end

    test "schedule_org_deletion audit row carries the retention deadline" do
      admin = admin_user!()
      org = tenant_org!()
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)

      assert [event] = Audit.list(event_type: "platform.tenancy.org_deletion_scheduled")
      assert is_binary(event.metadata["retention_deadline"])
    end

    test "unarchive_org and cancel_org_deletion persist their own events" do
      admin = admin_user!()

      org1 = tenant_org!()
      {:ok, org1} = Tenancy.archive_org(admin, org1)
      {:ok, _} = Tenancy.unarchive_org(admin, org1)
      assert [_] = Audit.list(event_type: "platform.tenancy.org_unarchived")

      org2 = tenant_org!()
      {:ok, org2} = Tenancy.schedule_org_deletion(admin, org2)
      {:ok, _} = Tenancy.cancel_org_deletion(admin, org2)
      assert [_] = Audit.list(event_type: "platform.tenancy.org_deletion_cancelled")
    end

    test "archive_project persists a bridged audit row" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      assert {:ok, _} = Tasks.archive_project(admin, proj)

      assert [event] = Audit.list(event_type: "platform.tasks.project_archived")
      assert event.resource_type == "project"
      assert event.resource_id == proj.id
      assert event.action == "project_archived"
    end
  end

  # ── Unified recoverable read (Recovery hub, task 019f7600 stage 2) ──────

  describe "list_recoverable/0" do
    defp recoverable_row(rows, type, id) do
      Enum.find(rows, &(&1.type == type and &1.id == id))
    end

    test "surfaces archived orgs, projects, and channels — independent, cascade-hidden, and scheduled" do
      admin = admin_user!()

      # Independently-archived project + channel (own state, no cascade parent).
      indep_org = tenant_org!()
      indep_proj = project!(indep_org)
      indep_chan = channel!(indep_org)
      {:ok, _} = Tasks.archive_project(admin, indep_proj)
      {:ok, _} = Chat.archive_space(admin, indep_chan)

      # A deletion-scheduled org that cascade-hides its active project + channel.
      sched_org = tenant_org!()
      cascaded_proj = project!(sched_org)
      cascaded_chan = channel!(sched_org)
      {:ok, sched_org} = Tenancy.schedule_org_deletion(admin, sched_org)

      rows = Lifecycle.list_recoverable()

      # Org row: scheduled, no cascade parent, `org` field points at itself.
      org_row = recoverable_row(rows, :org, sched_org.id)
      assert org_row.status == :scheduled
      assert is_nil(org_row.cascade_org_id)
      assert org_row.org.id == sched_org.id
      assert org_row.name == sched_org.name

      # Independently-archived project + channel: archived, no cascade parent.
      ip = recoverable_row(rows, :project, indep_proj.id)
      assert ip.status == :archived
      assert is_nil(ip.cascade_org_id)
      assert ip.org.id == indep_org.id

      # Channels now surface at all (the recovery load ignored them before).
      ic = recoverable_row(rows, :channel, indep_chan.id)
      assert ic.status == :archived
      assert is_nil(ic.cascade_org_id)

      # Cascade children: tagged with cascade_org_id and :scheduled. Post-019f760f
      # (now merged) a scheduled org stamps each cascade child's OWN deletion
      # clock with the org's, so their deletion_scheduled_at mirrors the org's
      # rather than staying NULL.
      cp = recoverable_row(rows, :project, cascaded_proj.id)
      assert cp.cascade_org_id == sched_org.id
      assert cp.status == :scheduled
      assert cp.deletion_scheduled_at == sched_org.deletion_scheduled_at

      cc = recoverable_row(rows, :channel, cascaded_chan.id)
      assert cc.cascade_org_id == sched_org.id
      assert cc.status == :scheduled
      assert cc.deletion_scheduled_at == sched_org.deletion_scheduled_at
    end

    test "two-state status: own-clock scheduled vs plain archived, per entity type" do
      admin = admin_user!()
      org = tenant_org!()

      # Plain-archived org → :archived.
      {:ok, _} = Tenancy.archive_org(admin, org)
      assert recoverable_row(Lifecycle.list_recoverable(), :org, org.id).status == :archived

      # Project scheduled on its OWN clock → :scheduled (not a cascade child).
      proj_org = tenant_org!()
      scheduled_proj = project!(proj_org)
      {:ok, _} = Tasks.schedule_project_deletion(admin, scheduled_proj)
      proj_row = recoverable_row(Lifecycle.list_recoverable(), :project, scheduled_proj.id)
      assert proj_row.status == :scheduled
      assert is_nil(proj_row.cascade_org_id)
      assert %DateTime{} = proj_row.deletion_scheduled_at

      # Channel scheduled on its OWN clock → :scheduled (independent, not cascade).
      chan_org = tenant_org!()
      scheduled_chan = channel!(chan_org)
      {:ok, _} = Chat.schedule_space_deletion(admin, scheduled_chan)
      chan_row = recoverable_row(Lifecycle.list_recoverable(), :channel, scheduled_chan.id)
      assert chan_row.status == :scheduled
      assert is_nil(chan_row.cascade_org_id)
      assert %DateTime{} = chan_row.deletion_scheduled_at
    end

    test "the Fabrikam root org never appears, even alongside archived tenants" do
      admin = admin_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.archive_org(admin, org)

      rows = Lifecycle.list_recoverable()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      refute Enum.any?(rows, &(&1.type == :org and &1.id == fabrikam.id))
      # …while the archived tenant is present.
      assert recoverable_row(rows, :org, org.id)
    end

    test "active (non-archived) orgs, projects, and channels are excluded" do
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)

      rows = Lifecycle.list_recoverable()

      refute recoverable_row(rows, :org, org.id)
      refute recoverable_row(rows, :project, proj.id)
      refute recoverable_row(rows, :channel, chan.id)
    end
  end

  # ── Selective restore (Recovery hub, task 019f7600 stage 3) ────────────

  describe "restore_project_with_ancestors/2" do
    test "brings back ONE cascade child + reactivates its org, leaving siblings archived" do
      admin = admin_user!()
      org = tenant_org!()
      target = project!(org)
      sibling = project!(org)

      # Schedule the org for deletion: both children are cascade-hidden and
      # inherit the org's OWN deletion clock (task 019f760f).
      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)

      target = Repo.reload!(target)
      sibling = Repo.reload!(sibling)
      assert target.archived_cascade_org_id == org.id
      assert target.deletion_scheduled_at == scheduled.deletion_scheduled_at
      assert sibling.archived_cascade_org_id == org.id
      assert sibling.deletion_scheduled_at == scheduled.deletion_scheduled_at

      assert {:ok, restored} = Lifecycle.restore_project_with_ancestors(admin, target)

      # The target is fully live: own flags + provenance marker cleared.
      assert is_nil(restored.archived_at)
      assert is_nil(restored.deletion_scheduled_at)
      assert is_nil(restored.archived_cascade_org_id)

      # The org is reactivated so the restored project has a live parent.
      org = Repo.reload!(org)
      assert is_nil(org.archived_at)
      assert is_nil(org.deletion_scheduled_at)

      # THE KEY ASSERTION: the sibling is untouched — still archived, own clock
      # and provenance marker intact ("restore everything except this one").
      sibling_after = Repo.reload!(sibling)
      assert sibling_after.archived_at == sibling.archived_at
      assert sibling_after.deletion_scheduled_at == sibling.deletion_scheduled_at
      assert sibling_after.archived_cascade_org_id == org.id
    end

    test "returns :not_found when the project was hard-deleted before the click" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      proj = Repo.reload!(proj)

      # Simulate the purger hard-deleting between hub render and Restore click.
      Repo.delete!(proj)

      assert {:error, :not_found} = Lifecycle.restore_project_with_ancestors(admin, proj)
      # The verify failure rolls back the whole transaction — org stays hidden.
      assert %DateTime{} = Repo.reload!(org).archived_at
    end

    test "rejects a non-admin actor and writes nothing" do
      admin = admin_user!()
      member = member_user!()
      org = tenant_org!()
      proj = project!(org)
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      proj = Repo.reload!(proj)

      assert {:error, :unauthorized} = Lifecycle.restore_project_with_ancestors(member, proj)
      assert {:error, :unauthorized} = Lifecycle.restore_project_with_ancestors(nil, proj)

      assert %DateTime{} = Repo.reload!(proj).archived_at
      assert %DateTime{} = Repo.reload!(org).archived_at
    end
  end

  describe "restore_space_with_ancestors/2" do
    test "brings back ONE channel + reactivates its org, broadcasts sidebar, leaves siblings archived" do
      admin = admin_user!()
      org = tenant_org!()
      target = channel!(org)
      sibling = channel!(org)

      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)

      target = Repo.reload!(target)
      sibling = Repo.reload!(sibling)
      assert target.archived_cascade_org_id == org.id
      assert target.deletion_scheduled_at == scheduled.deletion_scheduled_at

      # A restored channel must re-read the acting admin's sidebar.
      Chat.PubSub.subscribe_sidebar(admin.id)

      assert {:ok, restored} = Lifecycle.restore_space_with_ancestors(admin, target)

      assert is_nil(restored.archived_at)
      assert is_nil(restored.deletion_scheduled_at)
      assert is_nil(restored.archived_cascade_org_id)

      assert_receive :sidebar_changed

      org = Repo.reload!(org)
      assert is_nil(org.archived_at)
      assert is_nil(org.deletion_scheduled_at)

      sibling_after = Repo.reload!(sibling)
      assert sibling_after.archived_at == sibling.archived_at
      assert sibling_after.deletion_scheduled_at == sibling.deletion_scheduled_at
      assert sibling_after.archived_cascade_org_id == org.id
    end

    test "returns :not_found when the channel was hard-deleted before the click" do
      admin = admin_user!()
      org = tenant_org!()
      chan = channel!(org)
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      chan = Repo.reload!(chan)

      Repo.delete!(chan)

      assert {:error, :not_found} = Lifecycle.restore_space_with_ancestors(admin, chan)
      assert %DateTime{} = Repo.reload!(org).archived_at
    end

    test "rejects a non-admin actor — even the space creator (stricter than Chat.unarchive_space/2)" do
      admin = admin_user!()
      member = member_user!()
      org = tenant_org!()
      # The member is the channel's CREATOR: Chat.unarchive_space/2 would admit
      # them, but selective restore reactivates the whole org, so it must not.
      chan = channel!(org, %{created_by: member.id})
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      chan = Repo.reload!(chan)

      assert {:error, :unauthorized} = Lifecycle.restore_space_with_ancestors(member, chan)
      assert {:error, :unauthorized} = Lifecycle.restore_space_with_ancestors(nil, chan)

      assert %DateTime{} = Repo.reload!(chan).archived_at
      assert %DateTime{} = Repo.reload!(org).archived_at
    end
  end

  describe "selective restore — audit" do
    setup do
      Platform.Audit.TelemetryHandler.detach()
      Platform.Audit.TelemetryHandler.attach()

      on_exit(fn ->
        Platform.Audit.TelemetryHandler.detach()
        Platform.Audit.TelemetryHandler.attach()
      end)

      :ok
    end

    test "project restore persists BOTH the project and org unarchive events" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      proj = Repo.reload!(proj)

      assert {:ok, _} = Lifecycle.restore_project_with_ancestors(admin, proj)

      assert [pe] = Audit.list(event_type: "platform.tasks.project_unarchived")
      assert pe.resource_id == proj.id
      assert pe.actor_id == admin.id

      assert [oe] = Audit.list(event_type: "platform.tenancy.org_unarchived")
      assert oe.resource_id == org.id
    end

    test "channel restore persists BOTH the space and org unarchive events" do
      admin = admin_user!()
      org = tenant_org!()
      chan = channel!(org)
      assert {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      chan = Repo.reload!(chan)

      assert {:ok, _} = Lifecycle.restore_space_with_ancestors(admin, chan)

      assert [se] = Audit.list(event_type: "platform.chat.space_unarchived")
      assert se.resource_id == chan.id
      assert se.resource_type == "chat_space"

      assert [_] = Audit.list(event_type: "platform.tenancy.org_unarchived")
    end

    test "restoring an INDEPENDENTLY-archived project emits NO org event (org was never hidden)" do
      admin = admin_user!()
      # Org stays active the whole time; only the project is archived on its own.
      org = tenant_org!()
      proj = project!(org)
      assert {:ok, _} = Tasks.archive_project(admin, proj)
      proj = Repo.reload!(proj)

      assert {:ok, restored} = Lifecycle.restore_project_with_ancestors(admin, proj)
      assert is_nil(restored.archived_at)

      # The project unarchive IS recorded …
      assert [_] = Audit.list(event_type: "platform.tasks.project_unarchived")
      # … but no phantom org_unarchived row for an org that was never hidden.
      assert [] = Audit.list(event_type: "platform.tenancy.org_unarchived")
    end
  end

  # ── Delete "surface & choose" (Recovery hub, task 019f7600 stage 5) ─────

  describe "purge_preview/1" do
    test "enumerates EVERY child — active, cascade-hidden, and hand-archived — with its status" do
      admin = admin_user!()
      org = tenant_org!()

      active_proj = project!(org)
      active_chan = channel!(org)

      # Hand-archived before any org action: the children `cascade_preview/1`
      # SILENTLY drops (its `unhidden_children_query` skips already-archived).
      hand_proj = project!(org)
      hand_chan = channel!(org)
      {:ok, _} = Tasks.archive_project(admin, hand_proj)
      {:ok, _} = Chat.archive_space(admin, hand_chan)

      items = Lifecycle.purge_preview(org.id)
      by_id = Map.new(items, &{&1.id, &1})

      assert length(items) == 4

      assert by_id[active_proj.id].status == :active
      assert by_id[active_proj.id].type == :project
      assert by_id[active_chan.id].status == :active
      assert by_id[active_chan.id].type == :channel

      # The hand-archived ones ARE surfaced here — the core delete-flow fix.
      assert by_id[hand_proj.id].status == :archived
      assert by_id[hand_chan.id].status == :archived
    end

    test "a child on its own deletion clock reads :scheduled" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, _} = Tasks.schedule_project_deletion(admin, proj)

      item = Enum.find(Lifecycle.purge_preview(org.id), &(&1.id == proj.id))
      assert item.status == :scheduled
    end

    test "empty for a non-UUID and for an org with no children" do
      assert Lifecycle.purge_preview("not-a-uuid") == []
      assert Lifecycle.purge_preview(tenant_org!().id) == []
    end
  end

  describe "schedule_org_deletion/3 (surface & choose)" do
    test "keeping an item spares it; the rest inherit the org's clock and are swept" do
      admin = admin_user!()
      org = tenant_org!()
      swept = project!(org)
      kept = project!(org)

      assert {:ok, scheduled} = Lifecycle.schedule_org_deletion(admin, org, [kept.id])

      swept = Repo.reload!(swept)
      kept = Repo.reload!(kept)

      # Swept child: org's clock + provenance → purged inside the org's window.
      assert swept.deletion_scheduled_at == scheduled.deletion_scheduled_at
      assert swept.archived_cascade_org_id == org.id
      assert %DateTime{} = swept.archived_at

      # Kept child: archived but NO clock and NO provenance → survives the org
      # deletion as an independently-recoverable row.
      assert %DateTime{} = kept.archived_at
      assert is_nil(kept.deletion_scheduled_at)
      assert is_nil(kept.archived_cascade_org_id)
    end

    test "an already-archived child is swept when included but untouched when kept" do
      admin = admin_user!()
      org = tenant_org!()
      included = project!(org)
      kept = project!(org)
      {:ok, _} = Tasks.archive_project(admin, included)
      {:ok, _} = Tasks.archive_project(admin, kept)
      kept_archived_at = Repo.reload!(kept).archived_at

      assert {:ok, scheduled} = Lifecycle.schedule_org_deletion(admin, org, [kept.id])

      included = Repo.reload!(included)
      kept = Repo.reload!(kept)

      # Included hand-archived child now carries the org's clock → will be purged.
      assert included.deletion_scheduled_at == scheduled.deletion_scheduled_at
      assert included.archived_cascade_org_id == org.id

      # Kept hand-archived child is left exactly as it was (archive time intact).
      assert is_nil(kept.deletion_scheduled_at)
      assert is_nil(kept.archived_cascade_org_id)
      assert kept.archived_at == kept_archived_at
    end

    test "channels honor keep too" do
      admin = admin_user!()
      org = tenant_org!()
      swept = channel!(org)
      kept = channel!(org)

      assert {:ok, _} = Lifecycle.schedule_org_deletion(admin, org, [kept.id])

      assert %DateTime{} = Repo.reload!(swept).deletion_scheduled_at
      assert is_nil(Repo.reload!(kept).deletion_scheduled_at)
    end

    test "the purger sweeps the included child and SPARES the kept one" do
      admin = admin_user!()
      org = tenant_org!()
      swept = project!(org)
      kept = project!(org)

      assert {:ok, _} = Lifecycle.schedule_org_deletion(admin, org, [kept.id])

      # Backdate the swept child's clock past the retention window.
      past = DateTime.add(DateTime.utc_now(), -(Lifecycle.retention_days() + 1), :day)

      swept
      |> Repo.reload!()
      |> Ecto.Changeset.change(deletion_scheduled_at: past)
      |> Repo.update!()

      assert {:ok, purged} = Platform.Tenancy.ContainerPurger.sweep()
      assert purged >= 1

      # Swept child is gone; kept child (no clock) was never a candidate.
      assert is_nil(Repo.get(Platform.Tasks.Project, swept.id))
      assert Repo.get(Platform.Tasks.Project, kept.id)
    end

    test "root guard + admin gate still apply" do
      admin = admin_user!()
      member = member_user!()
      org = tenant_org!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      assert {:error, :not_deletable} = Lifecycle.schedule_org_deletion(admin, fabrikam, [])
      assert {:error, :unauthorized} = Lifecycle.schedule_org_deletion(member, org, [])
      assert is_nil(Repo.reload!(org).deletion_scheduled_at)
    end
  end

  describe "restore_org_selective/3 (keep-scheduled restore)" do
    test "default (keep nothing) cancels every child's countdown — full subtree revival" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)

      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)
      assert Repo.reload!(proj).deletion_scheduled_at == scheduled.deletion_scheduled_at
      assert Repo.reload!(chan).deletion_scheduled_at == scheduled.deletion_scheduled_at

      assert {:ok, restored} = Lifecycle.restore_org_selective(admin, scheduled, [])
      assert is_nil(restored.archived_at)
      assert is_nil(restored.deletion_scheduled_at)

      proj = Repo.reload!(proj)
      chan = Repo.reload!(chan)
      assert is_nil(proj.archived_at)
      assert is_nil(proj.deletion_scheduled_at)
      assert is_nil(proj.archived_cascade_org_id)
      assert is_nil(chan.archived_at)
      assert is_nil(chan.deletion_scheduled_at)
    end

    test "keeping a child leaves its ORIGINAL countdown running while the org + rest revive" do
      admin = admin_user!()
      org = tenant_org!()
      kept = project!(org)
      revived = project!(org)

      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)
      kept_clock = Repo.reload!(kept).deletion_scheduled_at
      assert %DateTime{} = kept_clock

      assert {:ok, org_after} = Lifecycle.restore_org_selective(admin, scheduled, [kept.id])
      assert is_nil(org_after.archived_at)
      assert is_nil(org_after.deletion_scheduled_at)

      # Kept child keeps its ORIGINAL clock (not a fresh window) and detaches from
      # the cascade so it reads as an independently-scheduled row.
      kept = Repo.reload!(kept)
      assert kept.deletion_scheduled_at == kept_clock
      assert %DateTime{} = kept.archived_at
      assert is_nil(kept.archived_cascade_org_id)

      # The other child fully revives.
      revived = Repo.reload!(revived)
      assert is_nil(revived.archived_at)
      assert is_nil(revived.deletion_scheduled_at)
    end

    test "returns :not_found when the org was hard-deleted before the confirm" do
      admin = admin_user!()
      org = tenant_org!()
      assert {:ok, scheduled} = Tenancy.schedule_org_deletion(admin, org)

      Repo.delete!(Repo.reload!(org))

      assert {:error, :not_found} = Lifecycle.restore_org_selective(admin, scheduled, [])
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: preview/writability helpers take LiveView + MCP ids" do
    # RAISE-exposed, not fabricated-value: each of these guards discards its
    # cast output and pins the ORIGINAL value downstream
    # (`where: p.id == ^org_id`), so the strict length check is what actually
    # stops the raise. A bare cast let any 16-character id through to Repo.
    @slug_16 "higginshigginsxx"

    test "cascade_preview/1 and cascade_hidden/1 return the empty preview" do
      empty = %{projects: [], channels: []}
      assert Lifecycle.cascade_preview(@slug_16) == empty
      assert Lifecycle.cascade_hidden(@slug_16) == empty
      assert Lifecycle.cascade_preview("higgins") == empty
    end

    test "purge_preview/1 returns []" do
      assert Lifecycle.purge_preview(@slug_16) == []
    end

    test "project_writable?/1 and ensure_task_project_writable/1 stay permissive" do
      # A malformed id is a validation error for the caller to report, not a
      # reference to freeze — and definitely not a 500.
      assert Lifecycle.project_writable?(@slug_16)
      assert Lifecycle.ensure_task_project_writable(@slug_16) == :ok
    end
  end
end
