defmodule Platform.Repo.Migrations.RevokeOrphanAgentRuntimes do
  @moduledoc """
  Revoke the `agent_runtimes` rows left `active` with no agent by agent
  deletes made before task 01a1b34b (core PR #107), so their `runtime_id`s
  are free for reuse without an admin visiting Control Center's Unattached
  runtimes list (task 01a1b84c stage 3).

  Why a migration: the release runs migrations on every boot
  (`Platform.Release.migrate()` in the image CMD) and a version runs exactly
  once per install. This is plain SQL and calls no application module: the
  dry-run sweep `Platform.Federation.OrphanRuntimes` and
  `mix platform.revoke_orphan_runtimes` stay as they are and are not used
  here (that module needs `RuntimePresence`, which is not started under
  `eval`).

  The criterion: `status = 'active' AND agent_id IS NULL AND NOT EXISTS
  (SELECT 1 FROM agents a WHERE a.runtime_id = agent_runtimes.id)`.

  What it excludes, and why:

    * Every row with `agent_id` set: brain rows, voice rows
      (`Federation.register_voice_runtime/3` sets `agent_id`, task 01a06686)
      and the Play host seed (`Platform.GameStream.Seed`). These are attached.
    * Rows with `agent_id` NULL that an agent still points at through
      `agents.runtime_id`. They are attached through the pointer
      (`Platform.Access.Agents.manage?/2` reads it) and reachable from that
      agent's runtime panel.
    * `pending` and `suspended` rows. `pending` is the register-time state:
      `reuse_revoked_runtime` leaves a reused row pending with `agent_id`
      NULL until `link_agent` binds it, and `mix platform.terminal_fixture`
      registers then links. `suspended` is a deliberate human hold. Both show
      in the Unattached runtimes list for a human to decide on.
    * No age cutoff, no staleness clause, no presence check. Since 01a1b34b
      `Federation.get_runtime_by_token/1` refuses `agent_id` NULL, so these
      rows cannot authenticate and their `last_connected_at` is frozen. No
      code path commits an active row with `agent_id` NULL (provisioning is
      one transaction). A cutoff on the 01a1b34b merge time could only
      compare `inserted_at`, which records when the runtime was created, not
      when its agent was deleted (the FK nilify does not touch `updated_at`),
      so it would neither identify pre-fix orphans nor protect anything.
      `RuntimePresence` is not running when migrations run under `eval`.
    * Dead letters are not touched: `DeadLetters.mark/3` keeps cumulative
      counters balanced and raw SQL would desync them. A reused runtime_id
      abandons the old row's live dead letters on reuse.

  `down/0` is a no-op: a cleared token hash cannot be restored.
  """
  # old-code-compatible: data-only revoke of rows old code already refuses to authenticate; nothing structural changes

  use Ecto.Migration

  require Logger

  @doc false
  def up_sql do
    """
    UPDATE agent_runtimes
    SET status = 'revoked',
        auth_token_hash = NULL,
        updated_at = now(),
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
          'revoked_reason', 'orphan_runtime_revoked',
          'revoked_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        )
    WHERE status = 'active'
      AND agent_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM agents a WHERE a.runtime_id = agent_runtimes.id)
    """
  end

  def up do
    execute(fn ->
      %{num_rows: revoked} = repo().query!(up_sql(), [], log: :info)
      Logger.info("revoke_orphan_agent_runtimes: revoked #{revoked} orphan runtime(s)")
    end)
  end

  def down do
    # Irreversible by construction: the cleared auth_token_hash is gone, and a
    # revoked runtime_id may already have been reused.
    :ok
  end
end
