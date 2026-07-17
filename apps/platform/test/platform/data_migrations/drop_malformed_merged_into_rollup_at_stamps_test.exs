defmodule Platform.DataMigrations.DropMalformedMergedIntoRollupAtStampsTest do
  @moduledoc """
  Regression coverage for
  `20260717173915_drop_malformed_merged_into_rollup_at_stamps`
  (task 019f708f stage 3, bug #3).

  Drives the migration's `drop_malformed_stamps/1` helper directly
  against `Platform.Repo` inside the sandbox transaction — the test
  hook the migration module exposes for exactly this purpose.
  Migrations run to `:up` before ExUnit boots so we can't exercise
  `up/0` via `Ecto.Migrator`; this helper is the same SQL wrapped
  for direct invocation without the migration Runner scaffolding.

  The stamp-shape matrix — each row seeds a specific pre-bug-#3
  shape and asserts drop-vs-preserve:

    (a) bare string                                    → DROPPED
    (b) empty map                                      → DROPPED
    (c) map with only :at, no :sha                     → DROPPED
    (d) integer scalar                                 → DROPPED
    (e) map with sha present but null                  → DROPPED
    (f) well-shaped map {sha, at}                      → PRESERVED
    (g) no merged_into_rollup_at key at all            → PRESERVED (unrelated keys survive)
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Repo.Migrations.DropMalformedMergedIntoRollupAtStamps
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord

  # Migration source lives under `priv/repo/migrations/` and is not on
  # the compile path — walk up from `test/platform/data_migrations/<this>.exs`
  # to `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260717173915_drop_malformed_merged_into_rollup_at_stamps.exs"
                  ])

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Malformed stamp #{Ecto.UUID.generate()}"})
    %{project: project}
  end

  # ── helpers ────────────────────────────────────────────────────────

  # Bypass the changeset's new shape validation (bug #3) to seed a
  # legacy row whose metadata could not be written via `changeset/2`
  # anymore. Direct SQL `UPDATE` is the only path — this simulates
  # rows persisted before the validator landed. Format the jsonb
  # literal inline (rather than parameter-binding) because
  # Postgrex's `$1::jsonb` binding for a String encodes the string
  # as a jsonb-string type, not as a parsed jsonb object.
  defp seed_task_with_metadata!(project, metadata) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Seed " <> uniq()})
    json_literal = Jason.encode!(metadata) |> String.replace("'", "''")

    Repo.query!(
      "UPDATE tasks SET metadata = '#{json_literal}'::jsonb WHERE id = $1",
      [Ecto.UUID.dump!(task.id)]
    )

    Repo.get!(TaskRecord, task.id)
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp reload!(%TaskRecord{id: id}), do: Repo.get!(TaskRecord, id)

  # ── the predicate matrix ───────────────────────────────────────────

  describe "drop_malformed_stamps/1" do
    test "drops bare-string stamp", %{project: project} do
      task = seed_task_with_metadata!(project, %{"merged_into_rollup_at" => "bare-string"})
      assert task.metadata == %{"merged_into_rollup_at" => "bare-string"}

      {n, _} = DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)
      assert n >= 1

      refute Map.has_key?(reload!(task).metadata, "merged_into_rollup_at")
    end

    test "drops empty-map stamp", %{project: project} do
      task = seed_task_with_metadata!(project, %{"merged_into_rollup_at" => %{}})
      DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)
      refute Map.has_key?(reload!(task).metadata, "merged_into_rollup_at")
    end

    test "drops map missing :sha (only :at)", %{project: project} do
      task =
        seed_task_with_metadata!(project, %{
          "merged_into_rollup_at" => %{"at" => "2026-07-17T00:00:00Z"}
        })

      DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)
      refute Map.has_key?(reload!(task).metadata, "merged_into_rollup_at")
    end

    test "drops integer-scalar stamp", %{project: project} do
      task = seed_task_with_metadata!(project, %{"merged_into_rollup_at" => 42})
      DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)
      refute Map.has_key?(reload!(task).metadata, "merged_into_rollup_at")
    end

    test "drops map with sha present but null value", %{project: project} do
      task =
        seed_task_with_metadata!(project, %{
          "merged_into_rollup_at" => %{"sha" => nil, "at" => "2026-07-17T00:00:00Z"}
        })

      DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)
      refute Map.has_key?(reload!(task).metadata, "merged_into_rollup_at")
    end

    test "preserves well-shaped stamp", %{project: project} do
      stamp = %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
      task = seed_task_with_metadata!(project, %{"merged_into_rollup_at" => stamp})

      DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)

      assert reload!(task).metadata["merged_into_rollup_at"] == stamp
    end

    test "preserves unrelated metadata keys on rows with malformed stamps", %{project: project} do
      task =
        seed_task_with_metadata!(project, %{
          "merged_into_rollup_at" => "bare-string",
          "phase_assignees" => %{"execution" => "agent-1"},
          "other_flag" => true
        })

      DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)

      meta = reload!(task).metadata
      refute Map.has_key?(meta, "merged_into_rollup_at")
      assert meta["phase_assignees"] == %{"execution" => "agent-1"}
      assert meta["other_flag"] == true
    end

    test "leaves rows without the key untouched", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No stamp"})
      assert task.metadata == %{} or task.metadata == nil

      DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)

      meta = reload!(task).metadata
      refute Map.has_key?(meta || %{}, "merged_into_rollup_at")
    end
  end

  # ── idempotence ────────────────────────────────────────────────────

  describe "idempotence" do
    test "re-invoking on a scrubbed database drops zero rows", %{project: project} do
      _ = seed_task_with_metadata!(project, %{"merged_into_rollup_at" => "bare-string"})
      _ = seed_task_with_metadata!(project, %{"merged_into_rollup_at" => %{}})

      {first_pass, _} = DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)
      assert first_pass >= 2

      {second_pass, _} = DropMalformedMergedIntoRollupAtStamps.drop_malformed_stamps(Repo)
      assert second_pass == 0
    end
  end

  # ── module surface ─────────────────────────────────────────────────

  describe "migration module surface" do
    test "module loads and up/0, down/0, drop_malformed_stamps/1 are defined" do
      assert Code.ensure_loaded?(DropMalformedMergedIntoRollupAtStamps)
      assert function_exported?(DropMalformedMergedIntoRollupAtStamps, :up, 0)
      assert function_exported?(DropMalformedMergedIntoRollupAtStamps, :down, 0)
      assert function_exported?(DropMalformedMergedIntoRollupAtStamps, :drop_malformed_stamps, 1)
    end
  end
end
