defmodule Platform.DataMigrations.BackfillCascadeChildDeletionClocksTest do
  @moduledoc """
  Regression coverage for
  `20260719000001_backfill_cascade_child_deletion_clocks`
  (task 019f760f stage 4).

  Drives the migration's `backfill/1` helper directly against
  `Platform.Repo` inside the sandbox transaction — the test hook the
  migration module exposes for exactly this purpose. Migrations run to
  `:up` before ExUnit boots so we can't exercise `up/0` via
  `Ecto.Migrator`; this helper is the same SQL wrapped for direct
  invocation without the migration Runner scaffolding.

  Scenario: a still-scheduled org has two cascade children (a project and
  a chat_space) seeded in the PRE-stage-1 shape — provenance marker set,
  own `deletion_scheduled_at` NULL. The backfill must stamp each child's
  own clock from the org's, and be a strict no-op on the second pass and
  on rows that don't match the predicate.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Repo.Migrations.BackfillCascadeChildDeletionClocks
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  # Migration source lives under `priv/repo/migrations/` and is not on the
  # compile path — walk up from `test/platform/data_migrations/<this>.exs`
  # to `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260719000001_backfill_cascade_child_deletion_clocks.exs"
                  ])

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  # ── seeding helpers ────────────────────────────────────────────────────

  # A live tenant org parented to Fabrikam. Children must be created while the
  # org is still live — `Tasks.create_project/1` (and space creation) reject
  # an `org_id` that already belongs to a deletion-scheduled org — so we
  # stamp the org's clock LAST, via `stamp_org_clock!/1`.
  defp live_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Cascade org #{n}",
      slug: "cascade_org_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  # Stamp the org's OWN deletion clock directly rather than via
  # `Tenancy.schedule_org_deletion/2`, because the public API also runs the
  # stage-1 cascade (stamping each child's own clock) — the whole point of
  # this fixture is to reproduce the PRE-stage-1 shape where cascade children
  # were left with a NULL clock. Returns the updated org.
  defp stamp_org_clock!(org) do
    org
    |> Ecto.Changeset.change(deletion_scheduled_at: now())
    |> Repo.update!()
  end

  # A cascade child project in the pre-stage-1 shape: archived + marker set,
  # own deletion clock NULL. `overrides` lets a test stamp a non-NULL clock.
  defp cascade_child_project!(org, overrides \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Cascade proj #{n}", org_id: org.id})

    project
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          archived_at: now(),
          archived_cascade_org_id: org.id,
          deletion_scheduled_at: nil
        },
        overrides
      )
    )
    |> Repo.update!()
  end

  defp cascade_child_channel!(org, overrides \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "Cascade chan #{n}",
        slug: "cascade-chan-#{n}",
        kind: "channel",
        org_id: org.id
      })

    space
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          archived_at: now(),
          archived_cascade_org_id: org.id,
          deletion_scheduled_at: nil
        },
        overrides
      )
    )
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp reload_project!(%Project{id: id}), do: Repo.get!(Project, id)
  defp reload_space!(%Space{id: id}), do: Repo.get!(Space, id)
  defp reload_org!(%Org{id: id}), do: Repo.get!(Org, id)

  # ── the backfill ───────────────────────────────────────────────────────

  describe "backfill/1" do
    test "stamps each cascade child's own clock from its still-scheduled org" do
      org = live_org!()
      project = cascade_child_project!(org)
      channel = cascade_child_channel!(org)
      org = stamp_org_clock!(org)

      # Pre-condition: children carry the marker but NO own clock yet.
      assert reload_project!(project).deletion_scheduled_at == nil
      assert reload_space!(channel).deletion_scheduled_at == nil

      assert {1, 1} = BackfillCascadeChildDeletionClocks.backfill(Repo)

      org_clock = reload_org!(org).deletion_scheduled_at
      assert %DateTime{} = org_clock
      assert reload_project!(project).deletion_scheduled_at == org_clock
      assert reload_space!(channel).deletion_scheduled_at == org_clock
    end

    test "does not touch a cascade child whose org is not scheduled" do
      org = live_org!()
      project = cascade_child_project!(org)
      channel = cascade_child_channel!(org)

      # Org clock deliberately left NULL — the org-side of the predicate
      # never matches, so nothing is backfilled.
      assert {0, 0} = BackfillCascadeChildDeletionClocks.backfill(Repo)

      assert reload_project!(project).deletion_scheduled_at == nil
      assert reload_space!(channel).deletion_scheduled_at == nil
    end

    test "does not overwrite a child that already carries its own clock" do
      org = live_org!()
      existing = DateTime.add(now(), -3, :day)
      project = cascade_child_project!(org, %{deletion_scheduled_at: existing})
      channel = cascade_child_channel!(org, %{deletion_scheduled_at: existing})
      org = stamp_org_clock!(org)

      assert {0, 0} = BackfillCascadeChildDeletionClocks.backfill(Repo)

      # Own clocks are preserved, NOT reset to the org's clock.
      org_clock = reload_org!(org).deletion_scheduled_at
      assert reload_project!(project).deletion_scheduled_at == existing
      assert reload_space!(channel).deletion_scheduled_at == existing
      refute reload_project!(project).deletion_scheduled_at == org_clock
    end
  end

  # ── idempotence ────────────────────────────────────────────────────────

  describe "idempotence" do
    test "a second pass over a stamped database updates zero rows" do
      org = live_org!()
      project = cascade_child_project!(org)
      channel = cascade_child_channel!(org)
      _org = stamp_org_clock!(org)

      assert {1, 1} = BackfillCascadeChildDeletionClocks.backfill(Repo)

      first_project_clock = reload_project!(project).deletion_scheduled_at
      first_channel_clock = reload_space!(channel).deletion_scheduled_at

      assert {0, 0} = BackfillCascadeChildDeletionClocks.backfill(Repo)

      # Unchanged after the no-op second pass.
      assert reload_project!(project).deletion_scheduled_at == first_project_clock
      assert reload_space!(channel).deletion_scheduled_at == first_channel_clock
    end
  end

  # ── module surface ─────────────────────────────────────────────────────

  describe "migration module surface" do
    test "module loads and up/0, down/0, backfill/1 are defined" do
      assert Code.ensure_loaded?(BackfillCascadeChildDeletionClocks)
      assert function_exported?(BackfillCascadeChildDeletionClocks, :up, 0)
      assert function_exported?(BackfillCascadeChildDeletionClocks, :down, 0)
      assert function_exported?(BackfillCascadeChildDeletionClocks, :backfill, 1)
    end
  end
end
