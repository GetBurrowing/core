defmodule Platform.Roles.CoverageTest do
  @moduledoc """
  Stage-5 deep behavioural coverage for the M4 roles system (task
  `019ef65b-a361-7873-871b-3375bf60ead7`).

  Stages 1-4 wired tests alongside the incremental schema, context, and
  seed work. This file bridges the gaps the planner's stage 5 spec
  called out that the earlier files don't (or only thinly) cover:

    * **Category 1 — seed shape.** Pin that `bundle_for("designer")`
      returns the v2-canvas `design.*` keys verbatim (not just
      "round-trips through seed data"), and that every seeded role
      bundle is non-empty when viewed through the resolver.
    * **Category 2 — cardinality.** Re-pin Decision 1 at the raw SQL
      layer (constraint violation surfaces from Postgres directly), not
      just via the changeset wrapping. Re-pin `roles_for/1` ordering
      against an insertion order that defeats accidental "natural order
      = insertion order" coincidence.
    * **Category 3 — override semantics.** Pin that setting an override
      does NOT mutate the role assignment row, and that clearing the
      override restores resolver fallback to the role-assigned agent.
      Pin `responsibilities_for/2 exclude_overridden:` for 0, 1, and
      all-overridden bundles.
    * **Category 4 — unfilled fallthrough.** Pin standalone overrides
      (override set, no role holder) routing through the resolver.
    * **Defensive — multi-bundle drift.** Pin that the warn-and-return
      branch in `assignee_for/1` actually fires when raw inserts create
      two role bundles for the same responsibility key.

  All responsibility keys here are v2-canvas-aligned (`design.critique`,
  `meetings.summarize`, …) — same convention as stage 4's seeds — NOT
  the planner's earlier pseudocode like `brand_review` /
  `meetings.transcribe`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.ResponsibilityOverride
  alias Platform.Roles.RoleAssignment
  alias Platform.Roles.RoleResponsibility
  alias Platform.Roles.Seeds

  # ── Helpers ──────────────────────────────────────────────────────────

  defp insert_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "coverage-#{suffix}",
        name: "Coverage Agent #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  # The Postgres-level test sandbox + the stage-4 seed migration (plus
  # task 019f2451 stage 2's re-seed for `meeting_producer`) mean every
  # test in this module starts with the canonical 5-role roster already
  # in place. That's intentional — these tests assert against the real
  # seeded shape, not a scrubbed fixture.

  # ── Category 1: seed shape (canvas-aligned keys) ─────────────────────

  describe "stage-4 seeds — canonical bundle shape" do
    test "Platform.Roles.list_roles/0 returns exactly the 5 canonical rows" do
      keys = Roles.list_roles() |> Enum.map(& &1.key)

      assert keys == [
               "designer",
               "historian",
               "meeting_producer",
               "meeting_scribe",
               "triage_officer"
             ]
    end

    test "bundle_for(\"designer\") returns the v2-canvas design.* keys" do
      bundle = Roles.bundle_for("designer")

      # Canvas 019e0fb8-d87d-72b2-aab4-205b84fe23aa rev 3.
      assert bundle == [
               "design.brand_check",
               "design.critique",
               "design.spec_writer"
             ]

      # Sanity: every key in the bundle is namespaced under `design.`.
      assert Enum.all?(bundle, &String.starts_with?(&1, "design."))
    end

    test "every seeded role has a non-empty bundle" do
      for role <- Roles.list_roles() do
        bundle = Roles.bundle_for(role.key)

        assert bundle != [],
               "role #{role.key} has an empty bundle — seed migration drifted from canvas"
      end
    end

    test "stage-4 seed roster matches Seeds.default_roles/0 verbatim" do
      seeded_keys =
        Seeds.default_roles()
        |> Enum.map(& &1.key)
        |> Enum.sort()

      live_keys = Roles.list_roles() |> Enum.map(& &1.key) |> Enum.sort()

      assert live_keys == seeded_keys
    end
  end

  # ── Category 2: cardinality (Decision 1, at the SQL layer) ───────────

  describe "cardinality — Decision 1 enforced at the SQL layer" do
    test "raw second insert for the same role_key raises a unique-constraint Postgrex error" do
      agent_a = insert_agent!()
      agent_b = insert_agent!()

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {1, _} =
        Repo.insert_all(RoleAssignment, [
          %{
            id: Ecto.UUID.generate(),
            role_key: "designer",
            agent_id: agent_a.id,
            inserted_at: now,
            updated_at: now
          }
        ])

      # Bypass the changeset entirely — we want to prove the unique
      # index on role_assignments.role_key is doing the work, not just
      # the changeset's unique_constraint/3 helper.
      assert_raise Postgrex.Error, ~r/unique constraint/i, fn ->
        Repo.insert_all(RoleAssignment, [
          %{
            id: Ecto.UUID.generate(),
            role_key: "designer",
            agent_id: agent_b.id,
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "roles_for/1 returns roles in stable :key ascending order regardless of insertion order" do
      agent = insert_agent!()

      # Insert the *later* alphabetical role first to defeat any
      # accidental "natural order = insertion order" coincidence in
      # the order_by/2 clause.
      {:ok, _} = Roles.assign_role("triage_officer", agent.id)
      {:ok, _} = Roles.assign_role("designer", agent.id)
      {:ok, _} = Roles.assign_role("historian", agent.id)

      assert Roles.roles_for(agent.id) |> Enum.map(& &1.key) ==
               ["designer", "historian", "triage_officer"]
    end
  end

  # ── Category 3: override semantics ───────────────────────────────────

  describe "override semantics — Decision 3" do
    test "set_override does NOT touch the role_assignment row" do
      role_agent = insert_agent!()
      override_agent = insert_agent!()

      {:ok, assignment} = Roles.assign_role("designer", role_agent.id)
      {:ok, _} = Roles.set_override("design.brand_check", override_agent.id)

      reloaded = Repo.get!(RoleAssignment, assignment.id)
      assert reloaded.agent_id == role_agent.id
      assert reloaded.role_key == "designer"

      # The other designer responsibilities still resolve to the role
      # holder — only the overridden key swings.
      assert %Agent{id: id} = Roles.assignee_for("design.critique")
      assert id == role_agent.id
    end

    test "clear_override restores resolver fallback to the role-assigned agent" do
      role_agent = insert_agent!()
      override_agent = insert_agent!()

      {:ok, _} = Roles.assign_role("designer", role_agent.id)

      # Pre-override: routes to the role holder.
      assert %Agent{id: id} = Roles.assignee_for("design.brand_check")
      assert id == role_agent.id

      # Override flips it.
      {:ok, _} = Roles.set_override("design.brand_check", override_agent.id)
      assert %Agent{id: id} = Roles.assignee_for("design.brand_check")
      assert id == override_agent.id

      # Clear flips it back.
      :ok = Roles.clear_override("design.brand_check")
      assert %Agent{id: id} = Roles.assignee_for("design.brand_check")
      assert id == role_agent.id

      # And the role assignment row still exists, untouched.
      assert Repo.exists?(
               from(ra in RoleAssignment,
                 where: ra.role_key == "designer" and ra.agent_id == ^role_agent.id
               )
             )
    end

    test "responsibilities_for/2 exclude_overridden: handles 0, 1, and all overridden" do
      role_agent = insert_agent!()
      override_agent = insert_agent!()

      {:ok, _} = Roles.assign_role("designer", role_agent.id)

      # 0 overrides → full bundle.
      assert Roles.responsibilities_for("designer", exclude_overridden: true) ==
               Roles.bundle_for("designer")

      # 1 override → subtracted.
      {:ok, _} = Roles.set_override("design.brand_check", override_agent.id)

      assert Roles.responsibilities_for("designer", exclude_overridden: true) ==
               ["design.critique", "design.spec_writer"]

      # All overridden → empty.
      {:ok, _} = Roles.set_override("design.critique", override_agent.id)
      {:ok, _} = Roles.set_override("design.spec_writer", override_agent.id)

      assert Roles.responsibilities_for("designer", exclude_overridden: true) == []

      # exclude_overridden: false (default) is unaffected throughout.
      assert Roles.responsibilities_for("designer", exclude_overridden: false) ==
               Roles.bundle_for("designer")
    end

    test "set_override upserts in place — explicit before/after row count" do
      agent_a = insert_agent!()
      agent_b = insert_agent!()

      {:ok, _} = Roles.set_override("design.brand_check", agent_a.id)

      assert Repo.aggregate(
               from(o in ResponsibilityOverride,
                 where: o.responsibility_key == "design.brand_check"
               ),
               :count
             ) == 1

      {:ok, _} = Roles.set_override("design.brand_check", agent_b.id)

      assert Repo.aggregate(
               from(o in ResponsibilityOverride,
                 where: o.responsibility_key == "design.brand_check"
               ),
               :count
             ) == 1

      [row] =
        Repo.all(
          from(o in ResponsibilityOverride,
            where: o.responsibility_key == "design.brand_check"
          )
        )

      assert row.agent_id == agent_b.id
    end
  end

  # ── Category 4: unfilled fallthrough (Decision 2) ────────────────────

  describe "unfilled fallthrough" do
    test "no assignment + no override → assignee_for/1 returns nil" do
      # The bundle row exists (seeded), but nobody holds the role and
      # there's no override.
      assert Roles.assignee_for("design.brand_check") == nil
    end

    test "override set with no role assignment → returns the override agent (standalone)" do
      standalone = insert_agent!()

      # No assign_role/2 call — the override stands on its own.
      {:ok, _} = Roles.set_override("design.brand_check", standalone.id)

      assert %Agent{id: id} = Roles.assignee_for("design.brand_check")
      assert id == standalone.id
    end

    test "unknown responsibility key + override on it still resolves to the override agent" do
      standalone = insert_agent!()

      # Stage 2's responsibility_overrides intentionally has NO FK
      # against responsibilities(key) — so a leaf-level override on a
      # key that isn't bundled into any role is still valid + routable.
      {:ok, _} = Roles.set_override("never.seeded.anywhere", standalone.id)

      assert %Agent{id: id} = Roles.assignee_for("never.seeded.anywhere")
      assert id == standalone.id
    end
  end

  # ── Defensive: multi-bundle drift warning path ───────────────────────

  describe "resolver defensive branch — multiple role bundles match" do
    test "logs a warning and returns the first match by role_key when drift is forced" do
      # Force the impossible state: two role bundles claiming the same
      # responsibility key. The schema's enum + the changeset prevent
      # this through normal call sites; we punch through with raw
      # insert_all to prove the defensive branch actually logs.
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{num_rows: 1} =
        SQL.query!(
          Repo,
          """
          INSERT INTO role_responsibilities
            (role_key, responsibility_key, inserted_at, updated_at)
          VALUES
            ('historian', 'design.critique', $1, $1)
          """,
          [now]
        )

      designer_agent = insert_agent!()
      historian_agent = insert_agent!()

      {:ok, _} = Roles.assign_role("designer", designer_agent.id)
      {:ok, _} = Roles.assign_role("historian", historian_agent.id)

      {result, log} =
        with_log(fn ->
          Roles.assignee_for("design.critique")
        end)

      # Order is :key ascending → "designer" before "historian", so
      # designer_agent wins the tie.
      assert %Agent{id: id} = result
      assert id == designer_agent.id
      assert log =~ "multiple role bundles match responsibility_key=\"design.critique\""

      # Sanity that the drift fixture really inserted both bundle rows.
      _ = historian_agent

      assert Repo.aggregate(
               from(rr in RoleResponsibility,
                 where: rr.responsibility_key == "design.critique"
               ),
               :count
             ) == 2
    end
  end
end
