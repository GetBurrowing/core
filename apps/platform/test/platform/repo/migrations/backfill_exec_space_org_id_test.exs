defmodule Platform.Repo.Migrations.BackfillExecSpaceOrgIdTest do
  @moduledoc """
  Behavioural coverage for the data migration
  `20260715165309_backfill_exec_space_org_id` (task `019f62a1` v4, cast guard
  added under task `01a044c6`).

  ## A BACKFILL IS INVISIBLE TO CI, WHICH IS WHY THIS FILE EXISTS

  The suite runs against a freshly created, freshly migrated, EMPTY database.
  A backfill that matches zero rows there does exactly what a correct one
  does: nothing. `mix ecto.migrate` is green either way, and so is every other
  test in the suite. Every green CI can produce is compatible with this
  migration being `def up, do: :ok`.

  So the only evidence worth anything is a seeded table, the migration run,
  and assertions read back OFF THE COLUMN.

  ## This file runs the SHIPPED `up/0`, not a copy of its SQL

  The previous version of this file pasted the migration's UPDATE into a
  module attribute and ran the copy. That proves the SQL is correct; it cannot
  prove the shipped migration still contains that SQL, so gutting `up/0` left
  it green. Calling `up/0` is possible because the migration issues
  `Ecto.Adapters.SQL.query!/3` directly rather than `execute/1`, so it needs no
  migration runner — the same arrangement
  `backfill_meeting_space_org_id_test.exs` relies on next door.

  ## The malformed-metadata case is the point of the cast guard

  `chat_spaces.metadata` is unstructured `jsonb`. Nothing at the database
  level constrains what sits at `task_id`, so `(metadata->>'task_id')::uuid`
  is a text→uuid cast over a value that can be any string. On a non-UUID
  string Postgres raises `22P02 invalid_text_representation`, which does not
  skip the row — it takes the whole migration down. That is a replay hazard,
  not a live bug: no code path in this repo writes a malformed `task_id`
  today (see `ExecutionSpace.find_or_create/1`), but a restored backup, a
  hand-edited row or a future writer at that key would abort the migration on
  the next database it runs against.

  Seeding malformed rows is therefore the only way this file can observe the
  guard at all — with well-formed data only, the guarded and unguarded
  statements are indistinguishable.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.BackfillExecSpaceOrgId

  # `priv/repo/migrations/` is not on the compile path. Climb from
  # `test/platform/repo/migrations/<this>.exs` to the `apps/platform/` root.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260715165309_backfill_exec_space_org_id.exs"
                  ])

  setup_all do
    # `mix ecto.migrate` runs in this same VM and loads PENDING migration files
    # only, so on an already-migrated database the module is absent and on a
    # fresh one it is already there. Requiring it twice would raise.
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp project_in(org_id) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Backfill Exec Org Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    assert project.org_id == org_id
    project
  end

  defp task_in(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Backfill exec target #{System.unique_integer([:positive])}"
      })

    task
  end

  # An exec space in the PRE-BACKFILL shape: `org_id = NULL`, task recorded in
  # jsonb. Inserted through a bare changeset rather than
  # `ExecutionSpace.find_or_create/1` for two reasons: that helper stamps the
  # org itself since the companion code fix, and it cannot be made to write a
  # malformed `task_id` at all (`resolve_task_org_id/1` casts the value into an
  # Ecto query and raises first) — which is exactly why the malformed row has
  # to be seeded by hand here.
  defp exec_space!(task_id_value, opts \\ []) do
    n = System.unique_integer([:positive])

    metadata =
      case task_id_value do
        :no_key -> %{}
        value -> %{"task_id" => value}
      end

    Repo.insert!(
      Ecto.Changeset.change(%Space{}, %{
        name: "task-exec-bf#{n}",
        slug: Keyword.get(opts, :slug, "task-exec-bf#{n}"),
        kind: Keyword.get(opts, :kind, "execution"),
        org_id: Keyword.get(opts, :org_id),
        metadata: metadata
      })
    )
  end

  defp persisted_org_id(space_id) do
    Repo.one!(from(s in Space, where: s.id == ^space_id, select: s.org_id))
  end

  # ── The seeded run ──────────────────────────────────────────────────────────

  describe "up/0 against a seeded table" do
    test "stamps the resolvable rows with the RIGHT org and leaves the rest NULL" do
      org_a = acme_org_id()
      org_b = tenant_org_id("globex")

      # ANTI-VACUITY. With one org in the fixture, "resolved the task's project
      # org" and "wrote a hardcoded constant" are the same observation.
      refute org_a == org_b,
             "fixture is vacuous: both orgs are the same row, so this test " <>
               "cannot tell resolution from a hardcoded value"

      task_a = task_in(project_in(org_a))
      task_b = task_in(project_in(org_b))

      # ── Rows that MUST be populated ────────────────────────────────────────
      space_a = exec_space!(task_a.id)
      space_b = exec_space!(task_b.id)

      # ── Rows that MUST stay NULL ───────────────────────────────────────────

      # (1) A well-formed uuid naming a task that does not exist. `tasks` has
      #     no FK from jsonb to keep it honest, and deleting a task leaves the
      #     exec space behind.
      orphan = exec_space!(Platform.Types.UUIDv7.generate())

      # (2)–(4) MALFORMED `task_id` values. Without the regex guard in front of
      #     the `::uuid` cast these do not merely stay NULL — the statement
      #     raises `22P02` and the entire migration aborts, taking the two
      #     resolvable rows above down with it.
      garbage = exec_space!("not-a-uuid")
      empty = exec_space!("")
      truncated = exec_space!(String.slice(task_a.id, 0, 8))

      # (5) No `task_id` key at all. `->>` yields NULL, the regex yields NULL,
      #     the row is filtered out — the pre-guard statement also skipped it,
      #     because a NULL cast is a NULL, not an error.
      keyless = exec_space!(:no_key)

      # (6) A NON-execution space carrying a malformed `task_id`. HONEST
      #     CAVEAT: this row on its own did NOT abort the pre-guard statement.
      #     The plan observed here pushes `kind = 'execution'` down into the
      #     scan on `chat_spaces` and evaluates the cast at the join node
      #     above it, so the row never reaches the cast. That is a planner
      #     choice, not a guarantee — the pre-guard cast lived in a JOIN
      #     condition with nothing scoping it. Kept as a control: after the
      #     guard the cast is confined to a CTE that filters on kind AND on
      #     the regex, so the row is out of reach by construction.
      foreign_kind = exec_space!("also-not-a-uuid", kind: "meeting")

      # ── The no-clobber row: already stamped, with the OTHER org ────────────
      # Its task resolves to org_b. If the `org_id IS NULL` filter is ever
      # dropped this flips to org_b, and the migration has begun rewriting rows
      # it was never allowed to touch.
      prestamped = exec_space!(task_in(project_in(org_b)).id, org_id: org_a)

      should_populate = [space_a.id, space_b.id]

      should_stay_nil = [
        orphan.id,
        garbage.id,
        empty.id,
        truncated.id,
        keyless.id,
        foreign_kind.id
      ]

      # ── PRECONDITION: everything that should move is NULL right now ────────
      for id <- should_populate ++ should_stay_nil do
        assert is_nil(persisted_org_id(id)),
               "seed is broken: #{id} already carries an org before the migration " <>
                 "ran, so nothing observed afterwards is attributable to the migration"
      end

      assert persisted_org_id(prestamped.id) == org_a

      # ── RUN THE SHIPPED MIGRATION ──────────────────────────────────────────
      #
      # `up/0` hands back the UPDATE's row count. Other rows may be in the
      # table (seed migrations run before the sandbox opens), so this is a
      # lower bound; the per-row assertions below pin the values.
      assert updated = @migration_module.up()

      assert is_integer(updated),
             "up/0 must return its row count so this test can assert on the " <>
               "shipped function rather than on a re-implementation of its SQL"

      assert updated >= 2,
             "the statement updated #{updated} rows; it was handed two resolvable " <>
               "exec spaces and must have moved both"

      # ── Half one: populated, and populated CORRECTLY ───────────────────────
      assert persisted_org_id(space_a.id) == org_a
      assert persisted_org_id(space_b.id) == org_b

      # The pair above is the real assertion: one migration cannot satisfy both
      # with a constant. Spelled out so a future reader cannot delete `space_b`
      # as a duplicate of `space_a`.
      refute persisted_org_id(space_a.id) == persisted_org_id(space_b.id),
             "both exec spaces resolved to the same org — the join fell back to a " <>
               "constant instead of reading each task's own project"

      # ── Half two, the control: still NULL ──────────────────────────────────
      for id <- should_stay_nil do
        assert is_nil(persisted_org_id(id)),
               "row #{id} has no resolvable task → project → org chain and must " <>
                 "still be NULL; a value here means the migration stamped a row by " <>
                 "falling back rather than by resolving"
      end

      # ── No-clobber ─────────────────────────────────────────────────────────
      assert persisted_org_id(prestamped.id) == org_a,
             "an already-stamped row was rewritten — the `org_id IS NULL` filter is gone"

      populated = Enum.count(should_populate, &(not is_nil(persisted_org_id(&1))))
      left_nil = Enum.count(should_stay_nil, &is_nil(persisted_org_id(&1)))

      assert populated == 2,
             "a run in which not every resolvable row moved is a broken migration, " <>
               "and a run in which ZERO rows moved is a no-op wearing a green tick"

      assert left_nil == 6,
             "a run in which EVERY row was populated is a failure: it means the join " <>
               "fell back rather than resolved"
    end

    test "a malformed task_id alone does not abort the run" do
      # The narrowest statement of the exposure, kept separate from the seeded
      # run above so that deleting one malformed row from that test cannot
      # quietly retire the guard. Remove the regex filter from the migration
      # and this raises `Postgrex.Error ... 22P02 invalid_text_representation:
      # invalid input syntax for type uuid: "definitely-not-a-uuid"` before it
      # can assert anything.
      org = tenant_org_id("hooli")
      task = task_in(project_in(org))

      resolvable = exec_space!(task.id)
      malformed = exec_space!("definitely-not-a-uuid")

      assert updated = @migration_module.up()
      assert updated >= 1

      assert persisted_org_id(resolvable.id) == org,
             "the resolvable row beside a malformed one was not stamped — a bad " <>
               "value must skip its own row, not sink the run"

      assert is_nil(persisted_org_id(malformed.id))
    end

    test "is idempotent — the second run matches zero rows" do
      org = tenant_org_id("initech")
      task = task_in(project_in(org))
      space = exec_space!(task.id)

      assert first = @migration_module.up()
      assert first >= 1
      assert persisted_org_id(space.id) == org

      # `updated_at = NOW()` is useless as the witness here: NOW() is
      # transaction start time, so a row rewritten inside this same sandbox
      # transaction gets a byte-identical stamp. The row COUNT is the only
      # honest observation.
      assert 0 == @migration_module.up()
      assert persisted_org_id(space.id) == org
    end

    test "down/0 is a deliberate no-op and does not clear what up/0 wrote" do
      org = tenant_org_id("vandelay_ind")
      task = task_in(project_in(org))
      space = exec_space!(task.id)

      assert _ = @migration_module.up()
      assert persisted_org_id(space.id) == org

      assert :ok = @migration_module.down()
      assert persisted_org_id(space.id) == org
    end
  end

  # ── The one property no behavioural test can observe ────────────────────────

  describe "the guard CTE stays un-inlinable" do
    test "the linked CTE is MATERIALIZED" do
      # Everything else in this file is asserted by running the migration. This
      # cannot be: `MATERIALIZED` is an optimisation barrier, and dropping it
      # produces a statement that is still correct under every plan the
      # planner happens to pick for a seeded test table. Its job is to stop the
      # planner inlining the CTE and lifting `(metadata->>'task_id')::uuid`
      # back above the regex that filters it — the exact shape that raised
      # `22P02` before this guard existed.
      #
      # Read off `backfill_sql/0`, the value `up/0` actually executes, not off
      # the file on disk.
      sql = Platform.Repo.Migrations.BackfillExecSpaceOrgId.backfill_sql()

      assert sql =~ "WITH linked AS MATERIALIZED",
             "the cast-guarding CTE is no longer MATERIALIZED — the planner may " <>
               "inline it and evaluate the ::uuid cast on rows the regex was " <>
               "meant to exclude"

      assert sql =~ "'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'",
             "the UUID-shape filter in front of the ::uuid cast is gone"
    end
  end

  # ── Kind scope ──────────────────────────────────────────────────────────────

  describe "the kind filter is load-bearing" do
    test "a non-execution space with the same metadata shape is not touched" do
      org = acme_org_id()
      task = task_in(project_in(org))

      meeting_space = exec_space!(task.id, kind: "meeting")

      assert _ = @migration_module.up()

      assert is_nil(persisted_org_id(meeting_space.id)),
             "a kind='meeting' row was stamped — the `s.kind = 'execution'` filter " <>
               "is gone and the migration's scope is now whatever the join reaches"
    end
  end

  # ── Collision safety ────────────────────────────────────────────────────────

  describe "chat_spaces_unique_org_slug is not tripped" do
    test "race-produced duplicate exec spaces: one is stamped, one stays NULL" do
      # Two exec-space rows for the SAME task with IDENTICAL slugs and
      # `org_id = NULL` — the shape the pre-existing race in
      # `ExecutionSpace.find_or_create/1` can leave behind. Stamping both in one
      # statement would trip `chat_spaces_unique_org_slug`, the partial UNIQUE
      # on `(org_id, slug) WHERE org_id IS NOT NULL`. `DISTINCT ON` is what
      # keeps the migration alive here; the `NOT EXISTS` guard evaluates against
      # the pre-UPDATE snapshot and cannot see a collision this same statement
      # is about to create.
      org = acme_org_id()
      task = task_in(project_in(org))
      shared_slug = "task-exec-racedup-#{System.unique_integer([:positive])}"

      [a, b] = for _ <- 1..2, do: exec_space!(task.id, slug: shared_slug)

      # Must not raise.
      assert updated = @migration_module.up()
      assert updated >= 1

      reloaded = [Repo.get!(Space, a.id), Repo.get!(Space, b.id)]

      # Which of the two wins is `inserted_at ASC` and is not part of the
      # contract worth pinning; that exactly one wins is.
      assert Enum.count(reloaded, &(&1.org_id == org)) == 1
      assert Enum.count(reloaded, &is_nil(&1.org_id)) == 1
    end

    test "an exec space whose (org, slug) pair is already held is skipped" do
      # The `NOT EXISTS` guard's own case: a different row already owns the
      # target pair, so stamping this one would collide.
      org = acme_org_id()
      task = task_in(project_in(org))
      shared_slug = "task-exec-taken-#{System.unique_integer([:positive])}"

      _incumbent = exec_space!(:no_key, slug: shared_slug, org_id: org, kind: "channel")
      contender = exec_space!(task.id, slug: shared_slug)

      assert _ = @migration_module.up()

      assert is_nil(persisted_org_id(contender.id)),
             "the NOT EXISTS guard is gone — stamping this row collides with the " <>
               "incumbent on chat_spaces_unique_org_slug and aborts the migration"
    end
  end
end
