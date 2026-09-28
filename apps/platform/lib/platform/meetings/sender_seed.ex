defmodule Platform.Meetings.SenderSeed do
  @moduledoc """
  Seeds the `agents` row the meetings subsystem sends invites *as*.

  ## Why an agent, and not a "platform" author

  `Platform.Chat.Participant` declares `@participant_types ~w(user agent)`
  — there is no `system` type. `chat_messages.participant_id` points at a
  participant row, so every message is authored by a user or an agent and
  "the platform sends a message" has nothing to send it as. The sender is
  therefore a real `agents` row that gets an agent participant row in
  whatever space it writes to.

  A third participant type was considered and rejected: `Platform.Chat`
  pattern-matches on the literals `"user"` / `"agent"` in a large number of
  read paths, and a new type would silently miss all of them.

  ## Seeded at boot, not in a migration

  Migrations run exactly once per database; environment variables flip.
  If `MEETINGS_ENABLED` goes false-to-true *after* the migration has
  already run, a migration-seeded agent never appears and the whole invite
  path is silently dead in both directions, with no log line.

  This is not hypothetical. Commit `7549dd89` (PR #658) is exactly this
  failure: five responsibility keys were added to
  `Platform.Roles.Seeds.@default_roles`, that list reached the database
  only through a migration, and on every already-migrated database the rows
  never landed — production ran with the Router subscribed and every prompt
  correct while `Platform.Roles.assignee_for/1` returned `nil` for all five.

  So: `ensure!/0` runs on every boot, and is idempotent.

  ## Turning the flag off must never un-seed

  `Platform.Meetings.Config.enabled?/0` gates **sending**. Seeding is
  additive-only and permanent. Messages already sent reference this agent
  as their author through their participant row, so deleting the agent
  orphans that authorship.

  There is deliberately no `down/0`, no purge path, and no cleanup task
  here. Do not add one.

  ## Idempotency: advisory lock, NOT `on_conflict`

  The obvious route —
  `Repo.insert(cs, on_conflict: :nothing, conflict_target: [:workspace_id, :slug])`
  against `unique_index(:agents, [:workspace_id, :slug], name: :agents_unique_slug)`
  — **did not work here** when this module was written, because this row's
  `workspace_id` is `NULL`.

  Measured, not assumed (Postgres 16.12, before migration
  `20260928230000_enforce_agent_slug_uniqueness_across_null_workspace`):

      SELECT ix.indisunique, ix.indnullsnotdistinct
        FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid
       WHERE i.relname = 'agents_unique_slug';
      -- indisunique = true, indnullsnotdistinct = false

  The index was plain `UNIQUE`, not `UNIQUE NULLS NOT DISTINCT`, so two
  rows with a `NULL` `workspace_id` were never "equal" and the index
  constrained nothing between them. Running the `ON CONFLICT ... DO NOTHING`
  insert twice against a live database produced two rows.

  **As of migration
  `20260928230000_enforce_agent_slug_uniqueness_across_null_workspace`
  (task 01a0e77c) the index is `NULLS NOT DISTINCT`** — same name, same
  columns — so two NULL-workspace agents can no longer share a slug and
  `indnullsnotdistinct` is true. The advisory lock below is kept anyway: it
  is cheap, it was correct before the index changed and still is, and it
  turns a racing second booter into a clean read of the winner's row rather
  than a changeset error it would have to handle.

  The route taken is `Repo.transaction/1` wrapping
  `SELECT pg_advisory_xact_lock($1)` on a constant key, then a
  `get_by`/`insert` inside the lock. This is the same idiom as
  `Platform.Tasks.Stacks.allocate_migration_slot/1` and
  `Platform.Tasks.StackDeployer`. A plain read-then-write without the lock
  is a TOCTOU race between two booting nodes and inserts twice; the
  transaction-scoped lock closes it and releases on commit or rollback, so
  there is no leak path. Under the Ecto test sandbox all callers share one
  connection, which makes the lock re-entrant and provides the
  serialization itself — the observable contract is the same either way.

  `Agent.changeset/2` also carries
  `unique_constraint(:slug, name: :agents_unique_slug)`, so now that the
  index is `NULLS NOT DISTINCT` a racer that somehow bypassed the lock gets a
  changeset error rather than a raise.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Repo

  @slug "meetings"
  @name "Meetings"

  # Constant key: there is exactly one row to serialize on, so every caller
  # on every node contends on the same lock. Hashed from a namespaced tuple
  # rather than a bare literal so it cannot collide with the stack locks,
  # which key on `{"migration_slot", stack_id}` and on a stack id.
  @lock_key :erlang.phash2({"meetings_sender_seed", @slug}, 2_147_483_647)

  @doc "The slug of the seeded meetings sender agent."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc """
  Ensures the meetings sender agent exists, returning it.

  Idempotent — safe to call on every boot and from concurrent nodes. See
  the moduledoc for why the idempotency rides on an advisory lock rather
  than on `on_conflict`.
  """
  @spec ensure!() :: {:ok, Agent.t()}
  def ensure! do
    {:ok, agent} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])

        # Read INSIDE the lock: a concurrent booter may have inserted
        # between our transaction starting and the lock being granted.
        # `get/0` and not `Repo.get_by(Agent, slug: @slug, workspace_id: nil)`
        # — Ecto rejects a nil in a keyword filter ("Comparison with nil is
        # forbidden as it is unsafe"), which is the same NULL semantics that
        # defeat `on_conflict` here, surfacing one layer up.
        case get() do
          %Agent{} = existing ->
            existing

          nil ->
            %Agent{}
            |> Agent.changeset(%{
              slug: @slug,
              name: @name,
              status: "active",
              kind: "native",
              runtime_type: "built_in",
              workspace_id: nil
            })
            |> Repo.insert!()
        end
      end)

    {:ok, agent}
  end

  @doc """
  Returns the seeded meetings sender agent, or `nil` if it has not been
  seeded (which is the expected state when `MEETINGS_ENABLED` is unset).
  """
  @spec get() :: Agent.t() | nil
  def get do
    Repo.one(from(a in Agent, where: a.slug == ^@slug and is_nil(a.workspace_id)))
  end
end
