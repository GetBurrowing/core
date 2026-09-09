defmodule Platform.DataMigrations.AgentRuntimeMeetingsBundleTest do
  @moduledoc """
  Coverage for `20260908150000_agent_runtime_meetings_bundle`
  (task 01a066af stage 4).

  `agent_runtimes.allowed_bundles` defaults from the Ecto SCHEMA, not from a
  database column default, so widening `default_allowed_bundles/0` reaches only
  rows inserted afterwards. Every already-registered runtime keeps the array it
  was written with — and a runtime that had been hand-granted `task` to reach
  `meeting_create` would silently LOSE that reach when the tool moved into the
  new `meetings` bundle. This migration is what stops that.

  Migrations run to `:up` before ExUnit boots, so `up/0` cannot be driven
  through `Ecto.Migrator` inside the sandbox transaction. The migration exposes
  `grant_meetings_bundle/1` — the identical SQL without the Runner scaffolding
  — and that is what these tests drive.

  Rows are seeded with a direct INSERT rather than through
  `Federation.register_runtime/2` because the point is a row written by the OLD
  code: `register_runtime/2` now stamps the widened defaults, which would make
  the migration a no-op and the test vacuous.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Repo.Migrations.AgentRuntimeMeetingsBundle

  # Migration source lives under `priv/repo/migrations/` and is not on the
  # compile path — walk up from `test/platform/data_migrations/<this>.exs` to
  # `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260908150000_agent_runtime_meetings_bundle.exs"
                  ])

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  test "a row lacking \"meetings\" has it after the migration runs" do
    # The exact pre-change default set, plus the hand-grant of `task` that was
    # the only way to reach `meeting_create` before the move.
    legacy = ~w(federation space context_read messaging attachment skill task)
    id = seed_runtime!(legacy)

    AgentRuntimeMeetingsBundle.grant_meetings_bundle(Repo)

    bundles = bundles_of(id)
    assert "meetings" in bundles
    # The grant APPENDS. Nothing the row already held may be dropped, or the
    # migration would trade one lost capability for another.
    assert Enum.all?(legacy, &(&1 in bundles))
    assert length(bundles) == length(legacy) + 1
  end

  test "a row already holding \"meetings\" is not duplicated, and a re-run is a no-op" do
    already = ~w(federation space meetings)
    id = seed_runtime!(already)

    AgentRuntimeMeetingsBundle.grant_meetings_bundle(Repo)
    assert bundles_of(id) == already

    # Idempotence: running the same UPDATE again changes nothing.
    AgentRuntimeMeetingsBundle.grant_meetings_bundle(Repo)
    bundles = bundles_of(id)
    assert bundles == already
    assert Enum.count(bundles, &(&1 == "meetings")) == 1
  end

  test "a narrow row that never held task still gains meetings" do
    id = seed_runtime!(~w(federation))

    AgentRuntimeMeetingsBundle.grant_meetings_bundle(Repo)

    assert bundles_of(id) == ~w(federation meetings)
  end

  # ── helpers ────────────────────────────────────────────────────────

  defp seed_runtime!(bundles) do
    user =
      Repo.insert!(%User{
        email: "meetings_bundle_#{System.unique_integer([:positive])}@example.com",
        name: "Meetings Bundle Migration User",
        oidc_sub: "oidc-meetings-bundle-#{System.unique_integer([:positive])}"
      })

    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO agent_runtimes
        (id, runtime_id, owner_user_id, transport, status, trust_level,
         allowed_bundles, metadata, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'websocket', 'active', 'participant', $4, '{}'::jsonb, $5, $5)
      """,
      [
        Ecto.UUID.dump!(id),
        "rt-meetings-migration-#{System.unique_integer([:positive])}",
        Ecto.UUID.dump!(user.id),
        bundles,
        now
      ]
    )

    id
  end

  defp bundles_of(id) do
    %{rows: [[bundles]]} =
      Repo.query!("SELECT allowed_bundles FROM agent_runtimes WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    bundles
  end
end
