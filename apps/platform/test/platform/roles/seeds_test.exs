defmodule Platform.Roles.SeedsTest do
  @moduledoc """
  Tests for `Platform.Roles.Seeds` (M4 stage 4 of task
  `019ef65b-a361-7873-871b-3375bf60ead7`; `meeting_producer` added in
  task `019f2451-6728` stage 2).

  Confirms:

    * `seed_defaults/0` inserts the five canonical roles and their
      bundled responsibility keys on a fresh DB.
    * Re-running `seed_defaults/0` is idempotent — the second call
      neither errors nor duplicates rows.
    * Each role's bundle round-trips through
      `Platform.Roles.bundle_for/1`.
    * The seeded list matches `Platform.Roles.Role.valid_keys/0` so
      the closed-roster invariant (Decision 2) holds.

  Deep behavioural coverage (resolver semantics, override-wins
  cascades) lives in `Platform.RolesTest`; this file is the seed-shape
  contract.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Roles.Seeds

  describe "default_roles/0" do
    test "seeded role keys equal the closed roster from Role.valid_keys/0" do
      seeded_keys =
        Seeds.default_roles()
        |> Enum.map(& &1.key)
        |> Enum.sort()

      valid_keys = Enum.sort(Role.valid_keys())

      # Task 019f2451 stage 2 restored strict equality after stage 1
      # temporarily relaxed this invariant to `subset?` while the seed
      # row for `meeting_producer` was pending. The closed roster
      # (Decision 2 from the M4 stack) MUST match the schema enum
      # exactly — drift here means a stage invented a key the schema
      # doesn't allow, or vice versa.
      assert seeded_keys == valid_keys,
             """
             Seeded role keys must equal the closed roster from
             `Platform.Roles.Role.valid_keys/0` (Decision 2 from the M4
             stack).
             Seeded: #{inspect(seeded_keys)}
             Valid:  #{inspect(valid_keys)}
             """
    end

    test "meeting_producer is present with the expected bundle, icon, and description" do
      # Pin the exact seed shape for the role added in task
      # 019f2451-6728 stage 2. The bundle key `meetings.intent_classify`
      # gets its cost_profile ("high_freq_capable") attached at the
      # responsibility layer, not the role — see
      # `Platform.Responsibilities.Handlers.IntentClassify.register/0`
      # (lands in stage 3).
      producer = Enum.find(Seeds.default_roles(), &(&1.key == "meeting_producer"))

      assert producer,
             "meeting_producer must be present in the canonical seed roster"

      assert producer.name == "Meeting Producer"
      assert producer.icon == "hero-signal"

      assert producer.description ==
               "Watches meeting transcript in real time; classifies intent and delegates to specialist agents"

      assert producer.bundle == ["meetings.intent_classify"]
    end

    test "each role has 1+ bundled responsibility keys" do
      for role <- Seeds.default_roles() do
        assert length(role.bundle) >= 1,
               "role #{role.key} must bundle at least one responsibility"
      end
    end
  end

  describe "security_guard entry" do
    # Task `019f3e8e-4406` stage 1 — see ADR-0043. Pin the exact seed
    # shape for the row that carries the four Security Guard bundle
    # keys. Each of the four keys registers with a `cost_profile` +
    # `metadata.cadence` at the responsibility layer, not the role —
    # see `Platform.Responsibilities.Handlers.SecurityCveScan` etc.
    test "security_guard is present with the expected bundle, icon, and description" do
      guard = Enum.find(Seeds.default_roles(), &(&1.key == "security_guard"))

      assert guard,
             "security_guard must be present in the canonical seed roster"

      assert guard.name == "Security Guard"
      assert guard.icon == "hero-shield-check"

      assert guard.description ==
               "Periodic scans for CVEs, code patterns, deploy config, and leaked secrets"

      assert guard.bundle == [
               "security.cve_scan",
               "security.code_audit",
               "security.deploy_audit",
               "security.secret_leak"
             ]
    end
  end

  describe "seed_defaults/0" do
    test "inserts eight roles and twenty-seven bundle rows on a fresh DB" do
      assert :ok = Seeds.seed_defaults()

      # 8 roles: designer, historian, meeting_producer, meeting_scribe,
      # triage_officer, security_guard, architect (ADR-0044 stage 1),
      # agents_leader (task 01a0b491 stage 1).
      assert Repo.aggregate(Role, :count, :key) == 8

      # 26 bundle rows = 6 (designer) + 4 (historian) + 1 (meeting_producer)
      #                + 4 (meeting_scribe) + 4 (triage_officer)
      #                + 4 (security_guard) + 3 (architect)
      #                + 1 (agents_leader).
      #
      # Designer went 3 → 4 in ADR-0046 stack member 7 (task
      # 019f9b29-5ecd stage 3), which added `design.task_direction`.
      #
      # 21 → 26 on 2026-07-31: the five mid-meeting intent keys
      # (`meetings.visual_adjust` + `meetings.interaction_design` →
      # designer, `meetings.brief_worthy` → meeting_scribe,
      # `meetings.decision_recorded` → historian,
      # `meetings.open_question` → triage_officer). Note the roster
      # stayed at 7 — the new keys landed in EXISTING bundles rather
      # than inventing a role, which is the fact this pair of counts
      # keeps honest: a new key that quietly arrived with a new role
      # would move both numbers and has to be argued for.
      #
      # 26 -> 27 in task 01a0b491 stage 1: `agents_leader` moved BOTH
      # numbers, which is the argued-for case this comment describes —
      # `agents.goal_heartbeat` needs an accountable role, and pinning it
      # onto an existing bundle would have made the heartbeat somebody
      # else's job.
      assert Repo.aggregate(RoleResponsibility, :count, :id) == 27
    end

    test "is idempotent — calling twice does not duplicate rows" do
      assert :ok = Seeds.seed_defaults()
      assert :ok = Seeds.seed_defaults()

      assert Repo.aggregate(Role, :count, :key) == 8

      # Same 27 as the fresh-DB case above — the point of this test is
      # that the SECOND `seed_defaults/0` adds nothing, so the number
      # must be read off the same breakdown rather than drifting into
      # an independent literal.
      assert Repo.aggregate(RoleResponsibility, :count, :id) == 27
    end

    test "each role's bundle round-trips via Platform.Roles.bundle_for/1" do
      :ok = Seeds.seed_defaults()

      for role_attrs <- Seeds.default_roles() do
        expected = Enum.sort(role_attrs.bundle)
        actual = Roles.bundle_for(role_attrs.key)

        assert actual == expected,
               """
               bundle_for/1 mismatch for role #{role_attrs.key}.
               Expected (sorted): #{inspect(expected)}
               Actual:            #{inspect(actual)}
               """
      end
    end

    test "each role row carries the canonical name / description / icon from the seed list" do
      :ok = Seeds.seed_defaults()

      for role_attrs <- Seeds.default_roles() do
        role = Roles.get_role!(role_attrs.key)

        assert role.name == role_attrs.name
        assert role.description == role_attrs.description
        assert role.icon == role_attrs.icon
      end
    end
  end
end
