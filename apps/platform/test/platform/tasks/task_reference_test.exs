defmodule Platform.Tasks.TaskReferenceTest do
  @moduledoc """
  Covers the stage-1 additions from task 019f3dbb:

    * `tasks.search_vector` — Postgres populates the generated column on
      insert AND on update (the generation expression is `STORED`, so
      editing `title` or `description` refreshes the vector at commit).
    * `tasks.search_vector` is indexed by GIN (`idx_tasks_search`).
    * `task_references` table exists, enforces `(source, target)`
      uniqueness via its composite primary key, and cascades on task
      delete.
    * `task_references.target_task_id` is indexed
      (`idx_task_references_target`) — a stage-3 follow-up-detector
      requirement, checked here at the DB level.
    * `Platform.Tasks.TaskReference.changeset/2` rejects self-references
      and duplicates.

  The scanner + write-path hooks land in stage 2; the search integration
  lands in stage 3. Both are out of scope for these tests.
  """

  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.TaskReference

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "search_vector column" do
    test "populates on insert with tsvector derived from title + description" do
      {:ok, project} = Tasks.create_project(%{name: "Vec Project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "hello",
          description: "world"
        })

      %{rows: [[vec_present]]} =
        Repo.query!(
          "SELECT search_vector @@ websearch_to_tsquery('english', $1) FROM tasks WHERE id = $2",
          ["hello", Ecto.UUID.dump!(task.id)]
        )

      assert vec_present == true

      %{rows: [[world_match]]} =
        Repo.query!(
          "SELECT search_vector @@ websearch_to_tsquery('english', $1) FROM tasks WHERE id = $2",
          ["world", Ecto.UUID.dump!(task.id)]
        )

      assert world_match == true
    end

    test "refreshes when title or description is updated" do
      {:ok, project} = Tasks.create_project(%{name: "Vec Project 2"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "initial title",
          description: "initial description"
        })

      %{rows: [[before_match]]} =
        Repo.query!(
          "SELECT search_vector @@ websearch_to_tsquery('english', $1) FROM tasks WHERE id = $2",
          ["overhauled", Ecto.UUID.dump!(task.id)]
        )

      refute before_match

      {:ok, _updated} =
        Tasks.update_task(task, %{
          title: "overhauled headline",
          description: "overhauled body"
        })

      %{rows: [[after_match]]} =
        Repo.query!(
          "SELECT search_vector @@ websearch_to_tsquery('english', $1) FROM tasks WHERE id = $2",
          ["overhauled", Ecto.UUID.dump!(task.id)]
        )

      assert after_match == true
    end

    test "GIN index idx_tasks_search exists" do
      %{rows: rows} =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'tasks' AND indexname = 'idx_tasks_search'"
        )

      assert rows == [["idx_tasks_search"]]
    end
  end

  describe "task_references table" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Refs Project"})
      {:ok, source} = Tasks.create_task(%{project_id: project.id, title: "source"})
      {:ok, target} = Tasks.create_task(%{project_id: project.id, title: "target"})
      {:ok, project: project, source: source, target: target}
    end

    test "insert with valid changeset succeeds", %{source: source, target: target} do
      assert {:ok, %TaskReference{} = ref} =
               %TaskReference{}
               |> TaskReference.changeset(%{
                 source_task_id: source.id,
                 target_task_id: target.id
               })
               |> Repo.insert()

      assert ref.source_task_id == source.id
      assert ref.target_task_id == target.id

      # `inserted_at` is DB-defaulted via `fragment("now()")` and Ecto does
      # not reload composite-PK rows post-insert. Verify at the DB layer.
      %{rows: [[dt]]} =
        Repo.query!(
          "SELECT inserted_at FROM task_references WHERE source_task_id = $1 AND target_task_id = $2",
          [Ecto.UUID.dump!(source.id), Ecto.UUID.dump!(target.id)]
        )

      refute is_nil(dt)
    end

    test "self-reference rejected at the changeset layer", %{source: source} do
      cs =
        TaskReference.changeset(%TaskReference{}, %{
          source_task_id: source.id,
          target_task_id: source.id
        })

      refute cs.valid?

      assert %{target_task_id: ["cannot equal source_task_id"]} = errors_on(cs)
    end

    test "composite primary key enforces (source, target) uniqueness", %{
      source: source,
      target: target
    } do
      attrs = %{source_task_id: source.id, target_task_id: target.id}

      assert {:ok, _} = %TaskReference{} |> TaskReference.changeset(attrs) |> Repo.insert()

      assert {:error, cs} =
               %TaskReference{} |> TaskReference.changeset(attrs) |> Repo.insert()

      # The changeset's `unique_constraint([:source_task_id, :target_task_id],
      # name: :task_references_pkey)` attaches the "already references this
      # target" error to the first field in the list, which is
      # `source_task_id`.
      assert %{source_task_id: ["already references this target"]} = errors_on(cs)
    end

    test "target index idx_task_references_target exists" do
      %{rows: rows} =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'task_references' AND indexname = 'idx_task_references_target'"
        )

      assert rows == [["idx_task_references_target"]]
    end

    test "cascades on source task delete", %{source: source, target: target} do
      {:ok, _ref} =
        %TaskReference{}
        |> TaskReference.changeset(%{source_task_id: source.id, target_task_id: target.id})
        |> Repo.insert()

      Repo.delete!(source)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM task_references WHERE source_task_id = $1",
                 [Ecto.UUID.dump!(source.id)]
               )
    end

    test "cascades on target task delete", %{source: source, target: target} do
      {:ok, _ref} =
        %TaskReference{}
        |> TaskReference.changeset(%{source_task_id: source.id, target_task_id: target.id})
        |> Repo.insert()

      Repo.delete!(target)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM task_references WHERE target_task_id = $1",
                 [Ecto.UUID.dump!(target.id)]
               )
    end
  end

  describe "backfill query idempotency" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Backfill Project"})
      {:ok, target} = Tasks.create_task(%{project_id: project.id, title: "referenced task"})

      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "referring task",
          description:
            "This description mentions the target directly via its id " <>
              target.id <> " so the scanner picks it up."
        })

      {:ok, project: project, target: target, source: source}
    end

    test "running the migration backfill twice yields exactly one row per (source, target)",
         %{source: source, target: target} do
      backfill_sql = """
      INSERT INTO task_references (source_task_id, target_task_id)
      SELECT DISTINCT
        source.id AS source_task_id,
        target.id AS target_task_id
      FROM tasks AS source
      CROSS JOIN LATERAL regexp_matches(
        coalesce(source.description, ''),
        '([a-f0-9]{8}-[a-f0-9]{4}-7[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12})',
        'gi'
      ) AS m(captures)
      JOIN tasks AS target ON target.id::text = lower(m.captures[1])
      WHERE source.id <> target.id
      ON CONFLICT DO NOTHING
      """

      # First run — the migration's initial backfill has already executed
      # at test-suite-setup time, but running it again here must be a
      # no-op if the row is already there. Two invocations back-to-back
      # therefore prove `ON CONFLICT DO NOTHING` is doing its job.
      Repo.query!(backfill_sql)
      Repo.query!(backfill_sql)

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM task_references WHERE source_task_id = $1 AND target_task_id = $2",
                 [
                   Ecto.UUID.dump!(source.id),
                   Ecto.UUID.dump!(target.id)
                 ]
               )
    end

    test "backfill query skips descriptions containing UUIDs that don't exist as tasks",
         %{source: source} do
      # Overwrite the description with a valid-shaped UUIDv7 that doesn't
      # match any existing task — the JOIN must drop it.
      # Well-formed UUIDv7 (so the regex genuinely matches it) that is not
      # a row in `tasks` — the assertion below must be earned by the JOIN
      # dropping it, not by the pattern failing to match at all.
      ghost_id = "019abcde-1234-7abc-89ab-cdef01234567"

      {:ok, _} =
        Tasks.update_task(source, %{
          description: "This mentions " <> ghost_id <> " which does not exist."
        })

      backfill_sql = """
      INSERT INTO task_references (source_task_id, target_task_id)
      SELECT DISTINCT
        source.id AS source_task_id,
        target.id AS target_task_id
      FROM tasks AS source
      CROSS JOIN LATERAL regexp_matches(
        coalesce(source.description, ''),
        '([a-f0-9]{8}-[a-f0-9]{4}-7[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12})',
        'gi'
      ) AS m(captures)
      JOIN tasks AS target ON target.id::text = lower(m.captures[1])
      WHERE source.id <> target.id
      ON CONFLICT DO NOTHING
      """

      Repo.query!(backfill_sql)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM task_references WHERE source_task_id = $1",
                 [Ecto.UUID.dump!(source.id)]
               )
    end

    test "backfill query excludes self-references", %{source: source} do
      {:ok, _} =
        Tasks.update_task(source, %{
          description: "This description references itself: " <> source.id
        })

      backfill_sql = """
      INSERT INTO task_references (source_task_id, target_task_id)
      SELECT DISTINCT
        source.id AS source_task_id,
        target.id AS target_task_id
      FROM tasks AS source
      CROSS JOIN LATERAL regexp_matches(
        coalesce(source.description, ''),
        '([a-f0-9]{8}-[a-f0-9]{4}-7[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12})',
        'gi'
      ) AS m(captures)
      JOIN tasks AS target ON target.id::text = lower(m.captures[1])
      WHERE source.id <> target.id
      ON CONFLICT DO NOTHING
      """

      Repo.query!(backfill_sql)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM task_references WHERE source_task_id = $1 AND target_task_id = $1",
                 [Ecto.UUID.dump!(source.id)]
               )
    end
  end
end
