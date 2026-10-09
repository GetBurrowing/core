defmodule Platform.Tenancy.ContainerPurgerTest do
  @moduledoc """
  Task 019f4eaa stage 4: retention purge of container children.
  Task 019f760f stage 2: purgers key off each item's OWN deletion clock.

  Invariants under test (mirrors `Platform.Chat.SpaceDeletionTest`):

    1. A directly-scheduled project past the retention window is
       hard-deleted; one flagged only 1 day ago is NOT.
    2. A cascade child (project / chat_space) whose OWN clock is past the
       window is hard-deleted — while the ORG row survives (never deleted).
    3. A schedule cancelled mid-window (own clock cleared) is NOT purged.
    4. A cascade child whose own clock is cleared is spared even while its
       org stays scheduled and past window — the "spare one" invariant.
    5. A cascade channel is purged by exactly ONE purger: ContainerPurger
       owns cascade children, SpacePurger skips them (no double-purge).
    6. The delete re-checks the full predicate IN the query (not just the
       select), so a cancellation landing after selection is respected.
    7. Each purge emits a system-actor audit event; the sweep is idempotent.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Chat.SpacePurger
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.ContainerPurger
  alias Platform.Tenancy.Lifecycle
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "purger-#{n}@example.com",
          name: "Purger #{n}",
          oidc_sub: "oidc-purger-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp membership!(user, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: role
    })
    |> Repo.insert!()
  end

  defp admin_user! do
    user = create_user!()
    membership!(user, "admin")
    user
  end

  # A fresh tenant org parented to Acme — isolated from seeded tenants.
  defp tenant_org!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    default = %{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
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

  defp past_window_days, do: Lifecycle.retention_days() + 1

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -Lifecycle.retention_days(), :day)

  # Backdates a scheduled row's OWN clock via Repo — the window tests need
  # history the public API refuses to fabricate. As of task 019f760f stage 1
  # every deletion-flagged row (directly-scheduled OR cascade child) carries
  # its own `deletion_scheduled_at`, so this backdates whichever row is passed.
  defp backdate_scheduled!(struct, days_ago) do
    past = DateTime.add(DateTime.utc_now(), -days_ago, :day)
    struct |> Ecto.Changeset.change(deletion_scheduled_at: past) |> Repo.update!()
  end

  # Clears a row's own deletion clock directly (no public API cancels a single
  # cascade child while its org stays scheduled — that is the "spare one" case).
  defp clear_scheduled!(struct) do
    struct |> Ecto.Changeset.change(deletion_scheduled_at: nil) |> Repo.update!()
  end

  # ── Directly-scheduled projects ────────────────────────────────────────

  describe "sweep/0 — directly-scheduled projects" do
    test "purges a project flagged past the retention window" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, scheduled} = Tasks.schedule_project_deletion(admin, proj)
      backdate_scheduled!(scheduled, past_window_days())

      assert {:ok, 1} = ContainerPurger.sweep()
      assert Repo.get(Project, proj.id) == nil
    end

    test "does NOT purge a project flagged only 1 day ago" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, scheduled} = Tasks.schedule_project_deletion(admin, proj)
      backdate_scheduled!(scheduled, 1)

      assert {:ok, 0} = ContainerPurger.sweep()
      assert %Project{} = Repo.get(Project, proj.id)
    end

    test "is idempotent — a second sweep purges nothing" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, scheduled} = Tasks.schedule_project_deletion(admin, proj)
      backdate_scheduled!(scheduled, past_window_days())

      assert {:ok, 1} = ContainerPurger.sweep()
      assert {:ok, 0} = ContainerPurger.sweep()
    end

    test "a project whose deletion was cancelled mid-window is NOT purged" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, scheduled} = Tasks.schedule_project_deletion(admin, proj)
      backdate_scheduled!(scheduled, past_window_days())

      # Cancellation clears the flag before the sweep runs.
      {:ok, cancelled} = Tasks.cancel_project_deletion(admin, Repo.reload!(scheduled))
      assert is_nil(cancelled.deletion_scheduled_at)

      assert {:ok, 0} = ContainerPurger.sweep()
      assert %Project{} = Repo.get(Project, proj.id)
    end
  end

  # ── Cascade-hidden children of a scheduled org ─────────────────────────

  describe "sweep/0 — cascade-hidden children of a scheduled org" do
    test "purges the child project AND chat_space while the org row survives" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)

      {:ok, scheduled_org} = Tenancy.schedule_org_deletion(admin, org)

      # Each cascade child carries the org's provenance marker AND (as of task
      # 019f760f stage 1) its OWN deletion clock — the per-child countdown the
      # purger now keys off. It starts equal to the org's clock.
      assert Repo.reload!(proj).archived_cascade_org_id == org.id
      assert Repo.reload!(proj).deletion_scheduled_at == scheduled_org.deletion_scheduled_at
      assert Repo.reload!(chan).archived_cascade_org_id == org.id
      assert Repo.reload!(chan).deletion_scheduled_at == scheduled_org.deletion_scheduled_at

      # The clock lives on each CHILD now — backdate the children, not the org.
      backdate_scheduled!(Repo.reload!(proj), past_window_days())
      backdate_scheduled!(Repo.reload!(chan), past_window_days())

      assert {:ok, 2} = ContainerPurger.sweep()

      # Children are gone.
      assert Repo.get(Project, proj.id) == nil
      assert Repo.get(Space, chan.id) == nil

      # THE KEY ASSERTION: the emptied org row survives, still soft-hidden.
      surviving_org = Repo.get(Org, org.id)
      assert %Org{} = surviving_org
      assert %DateTime{} = surviving_org.deletion_scheduled_at
    end

    test "does NOT purge cascade children whose own clock is only 1 day old" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      backdate_scheduled!(Repo.reload!(proj), 1)
      backdate_scheduled!(Repo.reload!(chan), 1)

      assert {:ok, 0} = ContainerPurger.sweep()
      assert %Project{} = Repo.get(Project, proj.id)
      assert %Space{} = Repo.get(Space, chan.id)
    end

    test "an org whose deletion was cancelled mid-window leaves its children intact" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      chan = channel!(org)
      {:ok, scheduled_org} = Tenancy.schedule_org_deletion(admin, org)

      # The child clock is what the purger keys off — backdate the children.
      backdate_scheduled!(Repo.reload!(proj), past_window_days())
      backdate_scheduled!(Repo.reload!(chan), past_window_days())

      # cancel_org_deletion clears the org flag AND, for every cascade child,
      # its own clock + provenance marker in one transaction.
      {:ok, cancelled_org} = Tenancy.cancel_org_deletion(admin, Repo.reload!(scheduled_org))
      assert is_nil(cancelled_org.deletion_scheduled_at)
      assert is_nil(Repo.reload!(proj).archived_cascade_org_id)
      assert is_nil(Repo.reload!(proj).deletion_scheduled_at)

      assert {:ok, 0} = ContainerPurger.sweep()
      assert %Project{} = Repo.get(Project, proj.id)
      assert %Space{} = Repo.get(Space, chan.id)
      assert %Org{} = Repo.get(Org, org.id)
    end

    test "a cascade child whose own clock was cleared is spared even while its org is scheduled" do
      admin = admin_user!()
      org = tenant_org!()
      kept = project!(org)
      purged = project!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)

      # Backdate the org AND both children past the window. Under the old
      # org-join logic every marked child would be purged; the own-clock logic
      # spares any child whose own clock was cleared.
      backdate_scheduled!(Repo.reload!(org), past_window_days())
      backdate_scheduled!(Repo.reload!(kept), past_window_days())
      backdate_scheduled!(Repo.reload!(purged), past_window_days())

      # Clear ONE child's own clock — its marker and the org stay untouched
      # (org still scheduled and past window).
      clear_scheduled!(Repo.reload!(kept))

      assert {:ok, 1} = ContainerPurger.sweep()
      assert %Project{} = Repo.get(Project, kept.id)
      assert Repo.get(Project, purged.id) == nil

      # The org survives, still soft-hidden — proving the spare keyed off the
      # child's OWN cleared clock, not the org's.
      assert %DateTime{} = Repo.reload!(org).deletion_scheduled_at
    end
  end

  # ── Race guard: predicate re-checked IN the delete query ───────────────

  describe "race guard — the delete re-verifies the predicate in the query" do
    test "a stale candidate whose DB flag was cleared after selection is not deleted" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, scheduled} = Tasks.schedule_project_deletion(admin, proj)
      stale = backdate_scheduled!(scheduled, past_window_days())

      # Simulate a cancellation landing AFTER this candidate was selected:
      # the DB row's flag is cleared, but `stale` still says "scheduled".
      {:ok, _} = Tasks.cancel_project_deletion(admin, Repo.reload!(stale))

      # Driving the per-candidate delete with the stale struct must re-read
      # the DB predicate (now NULL) and delete nothing.
      refute ContainerPurger.purge_directly_scheduled_project(stale, cutoff())
      assert %Project{} = Repo.get(Project, proj.id)
    end

    test "the re-check also protects a stale cascade child after its org is restored" do
      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      backdate_scheduled!(Repo.reload!(proj), past_window_days())

      stale_child = Repo.reload!(proj)
      assert stale_child.archived_cascade_org_id == org.id
      assert %DateTime{} = stale_child.deletion_scheduled_at

      # Restore the org — clears the org flag and each child's own clock +
      # provenance marker in one transaction.
      {:ok, _} = Tenancy.cancel_org_deletion(admin, Repo.reload!(org))

      # A cascade child is purged off its own clock, so the same seam applies:
      # the stale struct still says "scheduled" but the DB clock is now NULL.
      refute ContainerPurger.purge_directly_scheduled_project(stale_child, cutoff())
      assert %Project{} = Repo.get(Project, proj.id)
    end
  end

  # ── Ownership partition with SpacePurger (no double-purge) ─────────────

  describe "ownership partition — cascade channels vs SpacePurger" do
    test "a cascade channel is skipped by SpacePurger and purged only by ContainerPurger" do
      admin = admin_user!()
      org = tenant_org!()
      chan = channel!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      backdate_scheduled!(Repo.reload!(chan), past_window_days())

      # SpacePurger runs FIRST and must SKIP the cascade channel (marker set)
      # even though it is past window — SpacePurger owns only directly-
      # scheduled channels. Without the marker filter both purgers would key
      # off the same own-clock predicate and race to delete this one row.
      assert {:ok, 0} = SpacePurger.sweep()
      assert %Space{} = Repo.get(Space, chan.id)

      # ContainerPurger then purges it. Net across both sweeps: deleted once.
      assert {:ok, 1} = ContainerPurger.sweep()
      assert Repo.get(Space, chan.id) == nil
    end

    test "a directly-scheduled channel is still purged by SpacePurger" do
      admin = admin_user!()
      org = tenant_org!()
      chan = channel!(org)
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, chan)
      backdate_scheduled!(scheduled, past_window_days())

      # No cascade marker → SpacePurger owns it; ContainerPurger ignores it.
      assert is_nil(Repo.reload!(chan).archived_cascade_org_id)

      assert {:ok, 0} = ContainerPurger.sweep()
      assert %Space{} = Repo.get(Space, chan.id)

      assert {:ok, 1} = SpacePurger.sweep()
      assert Repo.get(Space, chan.id) == nil
    end
  end

  # ── Telemetry / audit bridge ───────────────────────────────────────────

  describe "telemetry" do
    test "a purged project emits :project_purged with actor_type system" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :tasks, :project_purged]])

      admin = admin_user!()
      org = tenant_org!()
      proj = project!(org)
      {:ok, scheduled} = Tasks.schedule_project_deletion(admin, proj)
      backdate_scheduled!(scheduled, past_window_days())

      assert {:ok, 1} = ContainerPurger.sweep()

      assert_receive {[:platform, :tasks, :project_purged], ^ref, _m, meta}
      assert meta.actor_id == nil
      assert meta.actor_type == "system"
      assert meta.resource_type == "project"
      assert meta.resource_id == proj.id
    end

    test "a cascade-purged chat_space reuses :space_purged with actor_type system" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :chat, :space_purged]])

      admin = admin_user!()
      org = tenant_org!()
      chan = channel!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)
      backdate_scheduled!(Repo.reload!(chan), past_window_days())

      assert {:ok, 1} = ContainerPurger.sweep()

      assert_receive {[:platform, :chat, :space_purged], ^ref, _m, meta}
      assert meta.actor_type == "system"
      assert meta.resource_id == chan.id
      assert meta.space_kind == "channel"
      assert meta.archived_cascade_org_id == org.id
    end

    test "the project_purged event is registered with the audit bridge" do
      events = Platform.Audit.TelemetryHandler.events()

      assert [:platform, :tasks, :project_purged] in events
      assert [:platform, :chat, :space_purged] in events
    end
  end
end
