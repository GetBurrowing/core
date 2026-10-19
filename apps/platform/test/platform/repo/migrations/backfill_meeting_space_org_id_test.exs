defmodule Platform.Repo.Migrations.BackfillMeetingSpaceOrgIdTest do
  @moduledoc """
  Task `019fcfdd` stage 3 — behavioural coverage for the data migration
  `20260827133700_backfill_meeting_space_org_id`.

  ## A BACKFILL IS INVISIBLE TO CI, WHICH IS WHY THIS FILE EXISTS

  The suite runs against a freshly created, freshly migrated, EMPTY database.
  A backfill that matches zero rows there does exactly what a correct one
  does: nothing. `mix ecto.migrate` is green either way, and so is every other
  test in the suite. Every green you can get from CI is compatible with this
  migration being `def up, do: :ok`.

  So the only evidence that means anything is a seeded table, the migration
  run, and assertions read back OFF THE COLUMN.

  ## What this file does differently from the exec-backfill test

  `backfill_exec_space_org_id_test.exs` copies the migration's SQL into a
  module attribute and runs the copy. That proves the SQL is correct; it
  cannot prove the SHIPPED migration contains that SQL, so gutting `up/0`
  leaves it green.

  This file calls `Platform.Repo.Migrations.BackfillMeetingSpaceOrgId.up/0`
  itself. That is possible because the migration issues
  `Ecto.Adapters.SQL.query!/3` directly rather than `execute/1`, so it needs
  no migration runner. Emptying `up/0` — or dropping either of its two
  statements — fails the assertions below.

  ## The two halves, and why the second one is the important one

  Half one: rows with a resolvable meeting → project → org chain are stamped
  WITH THE CORRECT ORG. Not merely non-nil: `two orgs` below seeds two
  meetings under two DIFFERENT orgs, because with a single org in the fixture
  a migration that writes one hardcoded constant is indistinguishable from one
  that resolves. (That mutant is not hypothetical — it survived stage 2's
  primary test for exactly this reason, because a default-created project's
  org IS the root org.)

  Half two, the control: rows whose meeting does NOT resolve are STILL NULL
  afterwards, and neither are rows of other kinds. Without this half, a
  migration that stamps every row in the table with one value passes.

  ## What could NOT be seeded, stated rather than quietly dropped

  The stage brief asked for a row "whose project has no org". That row cannot
  be constructed: `projects.org_id` is `NOT NULL` at the database level
  (`20260618181114_adr_0042_org_project_topology.exs`) and
  `Project.changeset/2` carries `validate_required([:name, :org_id])`. Nor can
  a meeting with no project — `meetings.project_id` is `NOT NULL` with a real
  FK (`20260514120000_create_meetings.exs`), and `Meetings.create_meeting/1`
  rejects a nil `project_id` at `require_present/2` before anything else runs.
  Loosening either constraint to manufacture the case would be testing a
  database that does not exist.

  The unresolvable shapes that ARE reachable are seeded instead, and they are
  reachable through one cascade: deleting a project reaps its `meetings` rows
  (`ON DELETE delete_all`) while their `chat_spaces` rows survive, because the
  FK runs the other way. That leaves orphan `meeting` spaces and
  `guest_meeting` spaces whose jsonb `meeting_id` dangles.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.BackfillMeetingSpaceOrgId

  # `priv/repo/migrations/` is not on the compile path. Climb from
  # `test/platform/repo/migrations/<this>.exs` to the `apps/platform/` root.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260827133700_backfill_meeting_space_org_id.exs"
                  ])

  setup_all do
    # `mix ecto.migrate` runs in this same VM and loads PENDING migration
    # files only, so on an already-migrated database the module is absent and
    # on a fresh one it is already there. Requiring it twice would raise.
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp project_in(org_id) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Backfill Meeting Org Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    assert project.org_id == org_id
    project
  end

  # A `kind: "meeting"` space in the PRE-BACKFILL shape.
  #
  # Since stage 2, `create_meeting/1` stamps the org itself, so the row has to
  # be stripped back to reproduce the historical population this migration
  # exists for. Done with a bare changeset rather than by hand-building a
  # space, so the row keeps the real slug, kind, metadata and `meetings` link
  # that `create_meeting/1` produces — the join under test is the FK from
  # `meetings`, and a hand-built space would have no meeting behind it.
  defp historical_meeting_space!(project) do
    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Backfill Meeting #{System.unique_integer([:positive])}"
      })

    space = strip_org!(Chat.get_space(meeting.chat_space_id))

    assert space.kind == "meeting"
    assert String.starts_with?(space.slug, "meeting-")

    {meeting, space}
  end

  defp strip_org!(%Space{} = space) do
    space
    |> Ecto.Changeset.change(%{org_id: nil})
    |> Repo.update!()
  end

  defp guest_space!(metadata) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      Ecto.Changeset.change(%Space{}, %{
        name: "Guest — backfill #{n}",
        slug: "guest-bf#{n}",
        kind: "guest_meeting",
        org_id: nil,
        metadata: metadata
      })
    )
  end

  defp persisted_org_id(space_id) do
    Repo.one!(from(s in Space, where: s.id == ^space_id, select: s.org_id))
  end

  # ── The seeded run ────────────────────────────────────────────────────────

  describe "up/0 against a seeded table" do
    test "populates the resolvable rows with the RIGHT org and leaves the unresolvable ones NULL" do
      org_a = acme_org_id()
      org_b = tenant_org_id("globex")

      # ANTI-VACUITY. With one org in the fixture, "resolved the project's org"
      # and "wrote a hardcoded constant" are the same observation.
      refute org_a == org_b,
             "fixture is vacuous: both orgs are the same row, so this test " <>
               "cannot tell resolution from a hardcoded value"

      project_a = project_in(org_a)
      project_b = project_in(org_b)

      # ── Rows that MUST be populated ──────────────────────────────────────
      {_meeting_a, space_a} = historical_meeting_space!(project_a)
      {meeting_b, space_b} = historical_meeting_space!(project_b)

      # A guest_meeting row linked to meeting_b through jsonb, not an FK.
      guest_ok = guest_space!(%{"meeting_id" => meeting_b.id, "host_user_id" => nil})

      # ── Rows that MUST stay NULL ─────────────────────────────────────────

      # (1) A `meeting` space with no `meetings` row pointing at it. This is
      #     what a deleted project leaves behind: the cascade reaps the
      #     meeting, the space survives.
      {_orphan_meeting, orphan_meeting_space} = historical_meeting_space!(project_a)

      Repo.delete_all(
        from(m in Meetings.Meeting, where: m.chat_space_id == ^orphan_meeting_space.id)
      )

      assert Repo.aggregate(
               from(m in Meetings.Meeting, where: m.chat_space_id == ^orphan_meeting_space.id),
               :count
             ) == 0,
             "the orphan control still has its meeting, so it is not testing the orphan case"

      # (2) A guest space whose `meeting_id` names a meeting that is gone.
      guest_dangling = guest_space!(%{"meeting_id" => Platform.Types.UUIDv7.generate()})

      # (3) A guest space with no `meeting_id` key at all.
      guest_keyless = guest_space!(%{"host_user_id" => nil})

      # (4) A guest space whose `meeting_id` is not UUID-shaped. Without the
      #     regex filter in front of the `::uuid` cast this does not merely
      #     stay NULL — it RAISES and aborts the migration.
      guest_garbage = guest_space!(%{"meeting_id" => "not-a-uuid"})

      # (5) A `dm` space. Cross-org by design, NULL forever. The kind filter
      #     is what keeps the migration off it.
      dm_space =
        Repo.insert!(
          Ecto.Changeset.change(%Space{}, %{
            name: "dm control",
            slug: "dm-bf#{System.unique_integer([:positive])}",
            kind: "dm",
            org_id: nil,
            is_direct: true
          })
        )

      # ── The no-clobber row: already stamped, with the WRONG org ──────────
      # Its meeting resolves to org_b. If the `org_id IS NULL` filter is ever
      # dropped, this flips to org_b and the migration has started rewriting
      # rows it was never allowed to touch.
      {_meeting_c, prestamped} = historical_meeting_space!(project_b)

      prestamped =
        prestamped
        |> Ecto.Changeset.change(%{org_id: org_a})
        |> Repo.update!()

      # ── PRECONDITION: everything that should move is NULL right now ──────
      should_populate = [space_a.id, space_b.id, guest_ok.id]

      should_stay_nil = [
        orphan_meeting_space.id,
        guest_dangling.id,
        guest_keyless.id,
        guest_garbage.id,
        dm_space.id
      ]

      for id <- should_populate ++ should_stay_nil do
        assert is_nil(persisted_org_id(id)),
               "seed is broken: #{id} already carries an org before the migration ran, " <>
                 "so nothing this test observes afterwards is attributable to the migration"
      end

      assert persisted_org_id(prestamped.id) == org_a

      # ── RUN THE SHIPPED MIGRATION ────────────────────────────────────────
      #
      # `up/0` hands back `{meeting_rows, guest_meeting_rows}` straight off
      # the two `Postgrex.Result`s. Both statements have to report work: a
      # zero from either is a statement that matched nothing, which on an
      # empty CI database is exactly what a correct run also looks like.
      #
      # Other rows may be in the table (the seed migrations run before the
      # sandbox opens), so these are lower bounds, not equalities. The
      # per-row assertions below are what pin the values.
      assert {meeting_rows, guest_rows} = @migration_module.up()

      assert meeting_rows >= 2,
             "the kind='meeting' statement updated #{meeting_rows} rows; it was handed " <>
               "two resolvable meeting spaces and must have moved both"

      assert guest_rows >= 1,
             "the kind='guest_meeting' statement updated #{guest_rows} rows; dropping " <>
               "that statement leaves every guest space behind and CI cannot see it"

      # ── Half one: populated, and populated CORRECTLY ─────────────────────
      assert persisted_org_id(space_a.id) == org_a
      assert persisted_org_id(space_b.id) == org_b
      assert persisted_org_id(guest_ok.id) == org_b

      # The pair above is the real assertion: one migration cannot satisfy
      # both with a constant. Spelled out so a future reader cannot delete
      # `space_b` as a duplicate of `space_a`.
      refute persisted_org_id(space_a.id) == persisted_org_id(space_b.id),
             "both meeting spaces resolved to the same org — the join fell back " <>
               "to a constant instead of reading each meeting's own project"

      # ── Half two, the control: still NULL ────────────────────────────────
      for id <- should_stay_nil do
        assert is_nil(persisted_org_id(id)),
               "row #{id} has no resolvable meeting → project → org chain and must " <>
                 "still be NULL; a non-nil value here means the migration stamped a " <>
                 "row by falling back rather than by resolving"
      end

      # ── No-clobber ───────────────────────────────────────────────────────
      assert persisted_org_id(prestamped.id) == org_a,
             "an already-stamped row was rewritten — the `org_id IS NULL` filter is gone"

      # ── The counts, asserted rather than merely printed ──────────────────
      populated = Enum.count(should_populate, &(not is_nil(persisted_org_id(&1))))
      left_nil = Enum.count(should_stay_nil, &is_nil(persisted_org_id(&1)))

      assert populated == 3,
             "a run in which not every resolvable row moved is a broken migration, " <>
               "and a run in which ZERO rows moved is a no-op wearing a green tick"

      assert left_nil == 5,
             "a run in which EVERY row was populated is a failure: it means the join " <>
               "fell back rather than resolved"
    end

    test "is idempotent — the second run matches zero rows" do
      org = tenant_org_id("hooli")
      project = project_in(org)
      {meeting, space} = historical_meeting_space!(project)
      guest = guest_space!(%{"meeting_id" => meeting.id})

      assert {m1, g1} = @migration_module.up()
      assert m1 >= 1
      assert g1 >= 1
      assert persisted_org_id(space.id) == org
      assert persisted_org_id(guest.id) == org

      # `updated_at = NOW()` would be useless as the witness here: NOW() is
      # transaction start time, so a row rewritten inside this same sandbox
      # transaction gets a byte-identical stamp. The row COUNT is the only
      # honest observation.
      assert {0, 0} = @migration_module.up()
      assert persisted_org_id(space.id) == org
      assert persisted_org_id(guest.id) == org
    end

    test "down/0 is a deliberate no-op and does not clear what up/0 wrote" do
      org = tenant_org_id("initech")
      project = project_in(org)
      {_meeting, space} = historical_meeting_space!(project)

      assert {_, _} = @migration_module.up()
      assert persisted_org_id(space.id) == org

      assert :ok = @migration_module.down()
      assert persisted_org_id(space.id) == org
    end
  end

  # ── Kind scope ────────────────────────────────────────────────────────────

  describe "the kind filter is load-bearing on its own" do
    test "a NON-meeting space that a meetings row points at is still not touched" do
      # Found by mutation: deleting `s.kind = 'meeting'` from the meeting
      # statement passed every other test in this file, because the join is
      # `meetings.chat_space_id = s.id` and only `create_meeting/1` ever
      # writes that column — so in practice the join already implies the kind.
      #
      # The schema does NOT imply it. `meetings.chat_space_id` is a plain FK
      # to `chat_spaces` with an ordinary index; nothing forbids a meeting row
      # from naming a space of another kind. This pins the filter directly so
      # the intent survives a future write path that does exactly that.
      #
      # Honest caveat: no current code path produces this row. The meeting is
      # repointed by hand below.
      org = tenant_org_id("vandelay_ind")
      project = project_in(org)
      {meeting, _space} = historical_meeting_space!(project)

      channel =
        Repo.insert!(
          Ecto.Changeset.change(%Space{}, %{
            name: "kind scope control",
            slug: "kind-scope-#{System.unique_integer([:positive])}",
            kind: "channel",
            org_id: nil
          })
        )

      meeting
      |> Ecto.Changeset.change(%{chat_space_id: channel.id})
      |> Repo.update!()

      assert {_, _} = @migration_module.up()

      assert is_nil(persisted_org_id(channel.id)),
             "a kind='channel' row was stamped — the `s.kind = 'meeting'` filter " <>
               "is gone and the migration's scope is now whatever the join happens " <>
               "to reach"
    end
  end

  # ── Collision safety ──────────────────────────────────────────────────────

  describe "chat_spaces_unique_org_slug is not tripped" do
    test "two guest spaces sharing a slug under one org: one is stamped, one stays NULL" do
      # `guest-<8 random chars>` slugs are not unique by construction, and the
      # partial UNIQUE on `(org_id, slug) WHERE org_id IS NOT NULL` would
      # reject the second UPDATE in the same statement. The `DISTINCT ON
      # (target_org_id, slug)` level is what keeps the migration alive here.
      org = acme_org_id()
      project = project_in(org)

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Guest Slug Collision #{System.unique_integer([:positive])}"
        })

      shared_slug = "guest-dup#{System.unique_integer([:positive])}"

      [a, b] =
        for _ <- 1..2 do
          Repo.insert!(
            Ecto.Changeset.change(%Space{}, %{
              name: "Guest — collision",
              slug: shared_slug,
              kind: "guest_meeting",
              org_id: nil,
              metadata: %{"meeting_id" => meeting.id}
            })
          )
        end

      # Must not raise.
      assert {_, guest_rows} = @migration_module.up()
      assert guest_rows >= 1

      reloaded = [Repo.get!(Space, a.id), Repo.get!(Space, b.id)]

      # Which of the two wins is `inserted_at ASC, id ASC` and not part of the
      # contract worth pinning; that exactly one wins is.
      assert Enum.count(reloaded, &(&1.org_id == org)) == 1
      assert Enum.count(reloaded, &is_nil(&1.org_id)) == 1
    end
  end
end
