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
end
