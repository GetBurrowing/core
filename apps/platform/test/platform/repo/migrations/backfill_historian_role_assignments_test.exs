defmodule Platform.Repo.Migrations.BackfillHistorianRoleAssignmentsTest do
  @moduledoc """
  Regression coverage for the stage-1 data migration
  `20260702192606_backfill_historian_role_assignments` — specifically
  the Postgrex parameter-binding fix that prevented the migration
  from ever matching legacy Historian rows in production.

  ## Why this file is so slim

  The stage-1 executor originally shipped a rich test file that drove
  the migration's `up/0` against a live `agents.system_events` column
  and asserted all three semantic branches (no-existing, same-agent,
  different-agent). Stage 5's schema drop retired the column, and
  stage 6 removed the test file because its raw-SQL helper
  `set_system_events!` wrote to a column that no longer exists in
  the test DB (migrations are already at `:up` by the time ExUnit
  boots — there's no schema-window in which the old assertions can
  run).

  The three semantic branches are now covered by the reviewer's
  stage-7 e2e_behavior cases (2 and 3) — they roll back the
  drop-column migration in a dev env, seed the legacy state, and
  assert the migration's post-state against a real schema. That is
  the ONLY environment those assertions are meaningful in.

  What we CAN pin here is the shape of the parameter binding that
  broke the migration in the first place: `[~s(["historian"])]`
  (a text binary) versus `[["historian"]]` (an Elixir list).
  Postgrex encodes the string variant with the text OID; PostgreSQL's
  `@>` jsonb containment operator does not match under that specific
  binding path even with an explicit `::jsonb` cast in the SQL. This
  is the bug the fresh executor was dispatched to fix — losing it
  again would silently break the prod deploy the same way stage 7
  cases 2 and 3 originally observed.

  So: byte-lock the parameter shape by reading the migration source
  and asserting the literal that appears at the binding call-site.
  """
  use Platform.DataCase, async: false

  @moduletag :regression

  # Migration files live under `priv/repo/migrations/` and are not on
  # the compile path — walk five `dirname`s to climb from
  # `test/platform/repo/migrations/<this>.exs` up to the
  # `apps/platform/` app root, then descend into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260702192606_backfill_historian_role_assignments.exs"
                  ])

  describe "Postgrex jsonb parameter binding" do
    test "fetch_legacy_historian_agents/0 binds the containment RHS as an Elixir list, not a text binary" do
      source = File.read!(@migration_path)

      # Positive assertion: the correct binding shape is present.
      assert source =~ "[[\"historian\"]]",
             """
             Expected the backfill migration to bind the jsonb containment
             parameter as an Elixir list `[["historian"]]`. The
             corresponding SQL uses `WHERE system_events @> $1::jsonb`,
             and Postgrex only matches under this binding path when the
             parameter is a nested Elixir term (encoded via the jsonb
             OID), not a pre-serialized text binary.
             """

      # Negative assertion: the broken binding shape is NOT present. This
      # is the byte-level guard against the exact regression stage 7
      # observed — `~s(["historian"])` looks correct at a glance because
      # the string LOOKS like JSON, but Postgrex sends it with the text
      # OID and PostgreSQL's `@>` never matches.
      refute source =~ ~s{[~s(["historian"])]},
             """
             The backfill migration must NOT bind the jsonb containment
             parameter as a text binary via `[~s(["historian"])]`. That
             binding is silently wrong: the migration runs without error
             but the SELECT returns zero rows, so no legacy Historian is
             ever promoted into role_assignments. See stage 7 e2e_behavior
             cases 2 (post-migration survivor) and 3 (disagreement
             scenario) for the observed failure mode.
             """
    end

    test "the migration module loads and both up/0 and down/0 are defined" do
      # Compile-load the module directly so a syntax error introduced
      # while touching the binding surfaces as a test failure rather
      # than a full-suite compile break at deploy time.
      Code.require_file(@migration_path)

      assert Code.ensure_loaded?(Platform.Repo.Migrations.BackfillHistorianRoleAssignments)

      assert function_exported?(
               Platform.Repo.Migrations.BackfillHistorianRoleAssignments,
               :up,
               0
             )

      assert function_exported?(
               Platform.Repo.Migrations.BackfillHistorianRoleAssignments,
               :down,
               0
             )
    end
  end
end
