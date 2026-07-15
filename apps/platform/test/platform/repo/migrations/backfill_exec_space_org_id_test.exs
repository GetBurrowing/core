defmodule Platform.Repo.Migrations.BackfillExecSpaceOrgIdTest do
  @moduledoc """
  Regression coverage for the stage-2 data migration
  `20260715165309_backfill_exec_space_org_id` (task 019f62a1 v4).

  The migration's `up/0` runs raw SQL that walks
  `chat_spaces (kind='execution', org_id IS NULL) → tasks → projects`
  and copies `projects.org_id` onto the chat_spaces row. Under the
  sandbox test env migrations are already at `:up` when ExUnit boots,
  so we can't roll back and re-run. Instead we:

    1. Byte-lock the SQL shape by reading the migration source and
       asserting the load-bearing WHERE clauses are present. This
       catches accidental relaxations of the guard rails (e.g. the
       `org_id IS NULL` filter dropping, which would let the migration
       stomp on already-stamped rows).

    2. Compile-load the module so a syntax error surfaces here rather
       than as a full-suite compile break at deploy time.

    3. Exercise the exact SQL against a live schema — seed a chat_spaces
       row with `org_id = NULL` + a task + project + org, run the same
       UPDATE, and assert the org_id is populated on the target row and
       left alone on rows without a resolvable task chain.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks

  @moduletag :regression

  # Migration files live under `priv/repo/migrations/` and are not on the
  # compile path — walk five `dirname`s to climb from
  # `test/platform/repo/migrations/<this>.exs` up to the
  # `apps/platform/` app root, then descend into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260715165309_backfill_exec_space_org_id.exs"
                  ])

  # Reproduces the migration's UPDATE verbatim. Extracted so the runtime
  # test can prove semantics against a live schema without needing to
  # roll back + re-run the actual migration inside the sandbox.
  @backfill_sql """
  WITH candidates AS (
    SELECT DISTINCT ON (p.org_id, s.slug)
           s.id AS space_id,
           p.org_id AS target_org_id
    FROM   chat_spaces s
    JOIN   tasks t ON (s.metadata->>'task_id')::uuid = t.id
    JOIN   projects p ON p.id = t.project_id
    WHERE  s.kind = 'execution'
      AND  s.org_id IS NULL
      AND  p.org_id IS NOT NULL
      AND  NOT EXISTS (
        SELECT 1
        FROM   chat_spaces s2
        WHERE  s2.org_id = p.org_id
          AND  s2.slug   = s.slug
          AND  s2.id    != s.id
      )
    ORDER BY p.org_id, s.slug, s.inserted_at ASC
  )
  UPDATE chat_spaces s
  SET    org_id     = c.target_org_id,
         updated_at = NOW()
  FROM   candidates c
  WHERE  s.id = c.space_id
  """

  describe "SQL shape guard rails" do
    test "the UPDATE keeps its load-bearing WHERE clauses" do
      source = File.read!(@migration_path)

      # Guard rail 1: only touches exec-space rows.
      assert source =~ "s.kind = 'execution'",
             "backfill must scope to kind = 'execution' — dropping this filter risks stamping the wrong kind of space"

      # Guard rail 2: only touches NULL-org rows (idempotency +
      # no-clobber for post-fix rows).
      assert source =~ "s.org_id IS NULL",
             "backfill must scope to org_id IS NULL rows — dropping this filter would stomp already-stamped rows"

      # Guard rail 3: only backfills when the source org_id is present.
      assert source =~ "p.org_id IS NOT NULL",
             "backfill must skip rows whose project has no org — otherwise the SET clause would write NULL, a no-op that still bumps updated_at unnecessarily"

      # Guard rail 4: joins through the metadata task_id, not a random
      # column. UUID cast prevents accidental text matches.
      assert source =~ "s.metadata->>'task_id')::uuid = t.id",
             "backfill must join chat_spaces → tasks via (metadata->>'task_id')::uuid — dropping the cast lets Postgres compare text to uuid and error"

      # Guard rail 5: joins tasks → projects, since org lives on projects.
      assert source =~ "projects p ON p.id = t.project_id",
             "backfill must join tasks → projects — org_id lives on projects, not tasks"

      # Guard rail 6: NOT EXISTS clause guards against pre-existing
      # `(org_id, slug)` collisions (post-fix rows already stamped
      # elsewhere).
      assert source =~ "NOT EXISTS",
             "backfill must include NOT EXISTS guard against unique-org-slug collisions from pre-existing stamped rows"

      # Guard rail 7: DISTINCT ON per (target_org_id, slug) prevents
      # in-statement pair-collisions when the pre-existing race in
      # `find_or_create/1` left multiple NULL-org rows for the same
      # task with identical slugs. Without DISTINCT ON, the whole
      # migration blows up on `chat_spaces_unique_org_slug` when the
      # UPDATE tries to stamp both siblings in one shot.
      assert source =~ "DISTINCT ON (p.org_id, s.slug)",
             "backfill must select DISTINCT ON (target_org_id, slug) so race-produced duplicate NULL-org rows for the same task don't collide inside the same UPDATE"
    end

    test "the migration module loads and both up/0 and down/0 are defined" do
      Code.require_file(@migration_path)

      assert Code.ensure_loaded?(Platform.Repo.Migrations.BackfillExecSpaceOrgId)

      assert function_exported?(
               Platform.Repo.Migrations.BackfillExecSpaceOrgId,
               :up,
               0
             )

      assert function_exported?(
               Platform.Repo.Migrations.BackfillExecSpaceOrgId,
               :down,
               0
             )
    end
  end

  describe "runtime semantics against live schema" do
    test "populates org_id for exec spaces whose task chain resolves; leaves others alone" do
      fabrikam_id = fabrikam_org_id()

      # Row 1: exec space with org_id=NULL that HAS a resolvable
      # task+project+org chain. Should get stamped.
      {:ok, project} =
        Tasks.create_project(%{name: "Backfill Target Project", org_id: fabrikam_id})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Backfill target"})

      {:ok, target_space} =
        Repo.insert(
          Ecto.Changeset.change(%Space{}, %{
            name: "task-exec-target",
            slug: "task-exec-target-#{System.unique_integer([:positive])}",
            kind: "execution",
            org_id: nil,
            metadata: %{"task_id" => task.id}
          })
        )

      # Row 2: exec space with org_id=NULL but metadata.task_id points at
      # a task that DOES NOT EXIST. No resolvable org — must stay NULL.
      orphan_task_id = Ecto.UUID.generate()

      {:ok, orphan_space} =
        Repo.insert(
          Ecto.Changeset.change(%Space{}, %{
            name: "task-exec-orphan",
            slug: "task-exec-orphan-#{System.unique_integer([:positive])}",
            kind: "execution",
            org_id: nil,
            metadata: %{"task_id" => orphan_task_id}
          })
        )

      # Row 3: exec space that ALREADY carries a (different) org_id. The
      # idempotency guard (`s.org_id IS NULL`) must skip it — the SXI
      # value must survive.
      sxi_id = tenant_org_id("sxi")

      {:ok, project2} =
        Tasks.create_project(%{name: "Already Stamped Project", org_id: fabrikam_id})

      {:ok, task2} =
        Tasks.create_task(%{project_id: project2.id, title: "Already stamped"})

      {:ok, prestamped_space} =
        Repo.insert(
          Ecto.Changeset.change(%Space{}, %{
            name: "task-exec-prestamped",
            slug: "task-exec-prestamped-#{System.unique_integer([:positive])}",
            kind: "execution",
            org_id: sxi_id,
            metadata: %{"task_id" => task2.id}
          })
        )

      # Run the exact SQL the migration ships.
      Ecto.Adapters.SQL.query!(Repo, @backfill_sql, [])

      # Row 1: stamped with the project's org.
      assert %Space{org_id: got} = Repo.get!(Space, target_space.id)
      assert got == fabrikam_id

      # Row 2: still NULL — no resolvable task chain, nothing to stamp.
      assert %Space{org_id: nil} = Repo.get!(Space, orphan_space.id)

      # Row 3: untouched — WHERE clause skipped it. SXI survives.
      assert %Space{org_id: got_prestamped} = Repo.get!(Space, prestamped_space.id)
      assert got_prestamped == sxi_id
    end

    test "is idempotent — re-running against a stamped row is a no-op" do
      fabrikam_id = fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{name: "Idempotent Project", org_id: fabrikam_id})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Idempotent"})

      {:ok, space} =
        Repo.insert(
          Ecto.Changeset.change(%Space{}, %{
            name: "task-exec-idem",
            slug: "task-exec-idem-#{System.unique_integer([:positive])}",
            kind: "execution",
            org_id: nil,
            metadata: %{"task_id" => task.id}
          })
        )

      Ecto.Adapters.SQL.query!(Repo, @backfill_sql, [])
      assert %Space{org_id: got1} = Repo.get!(Space, space.id)
      assert got1 == fabrikam_id

      # Second run — the s.org_id IS NULL filter now excludes the row.
      Ecto.Adapters.SQL.query!(Repo, @backfill_sql, [])
      assert %Space{org_id: got2} = Repo.get!(Space, space.id)
      assert got2 == fabrikam_id
    end

    test "skips race-produced duplicate exec spaces to avoid unique-org-slug collision" do
      # Two exec-space rows for the SAME task with IDENTICAL slugs and
      # org_id=NULL — the exact shape the pre-existing race in
      # `find_or_create/1` can leave behind. Without the NOT EXISTS
      # guard, stamping both with the same org_id would trip
      # `chat_spaces_unique_org_slug` and blow up the migration.
      fabrikam_id = fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{name: "Race Dup Project", org_id: fabrikam_id})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Race dup"})

      shared_slug = "task-exec-racedup-#{System.unique_integer([:positive])}"

      {:ok, space_a} =
        Repo.insert(
          Ecto.Changeset.change(%Space{}, %{
            name: "task-exec-racedup-a",
            slug: shared_slug,
            kind: "execution",
            org_id: nil,
            metadata: %{"task_id" => task.id}
          })
        )

      {:ok, space_b} =
        Repo.insert(
          Ecto.Changeset.change(%Space{}, %{
            name: "task-exec-racedup-b",
            slug: shared_slug,
            kind: "execution",
            org_id: nil,
            metadata: %{"task_id" => task.id}
          })
        )

      # The migration MUST run without raising the unique-constraint
      # error — the NOT EXISTS clause is what makes this safe.
      Ecto.Adapters.SQL.query!(Repo, @backfill_sql, [])

      reloaded_a = Repo.get!(Space, space_a.id)
      reloaded_b = Repo.get!(Space, space_b.id)

      # Exactly ONE of the two got stamped (the first the SET clause
      # touches — after that, NOT EXISTS filters the other out). The
      # OTHER is left with org_id=NULL. Which is which is not
      # deterministic across Postgres versions and is not part of the
      # contract; the contract is (a) migration doesn't fail, and (b)
      # no violation of `chat_spaces_unique_org_slug`.
      stamped_count = Enum.count([reloaded_a, reloaded_b], &(&1.org_id == fabrikam_id))
      null_count = Enum.count([reloaded_a, reloaded_b], &is_nil(&1.org_id))

      assert stamped_count == 1
      assert null_count == 1
    end

    test "does NOT touch non-execution spaces even when org_id is NULL" do
      fabrikam_id = fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{name: "Non-Exec Guard Project", org_id: fabrikam_id})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Non-exec guard"})

      # A meeting-kind space with the same metadata shape must NOT be
      # touched — the kind='execution' filter is load-bearing.
      {:ok, meeting_space} =
        Repo.insert(
          Ecto.Changeset.change(%Space{}, %{
            name: "meeting-not-target",
            slug: "meeting-not-target-#{System.unique_integer([:positive])}",
            kind: "meeting",
            org_id: nil,
            metadata: %{"task_id" => task.id}
          })
        )

      Ecto.Adapters.SQL.query!(Repo, @backfill_sql, [])

      assert %Space{org_id: nil} = Repo.get!(Space, meeting_space.id)
    end
  end
end
