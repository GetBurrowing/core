defmodule Platform.ExternalAgents.EphemeralCredentials do
  @moduledoc """
  GenServer-owned ETS store for ephemeral external-agent credentials.

  External agents (kind == "external") may carry a short-lived secret —
  e.g. a delegated OAuth bearer or a session-scoped API key — that we do
  *not* want to persist to the database. Decision 6 in the External
  Agents design (M3) says these secrets are:

    * single-BEAM-node-local
    * lost on application restart (no orphans)
    * never written to disk

  This module provides the in-memory storage path that satisfies all
  three. The DB-backed `Platform.Vault` (Cloak-encrypted) is the other
  half of the credential dispatch and lands in stage 3.

  ## Lifecycle

  A single GenServer process exists solely to *own* the named ETS table.
  The table is created in `init/1` and dies with the owning process — so
  on supervisor restart, all rows vanish (decision 6: no orphaned
  secrets). The pattern mirrors `Platform.Chat.ActiveAgentStore`.

  ## Read / write paths

    * `get/1` bypasses the GenServer and reads `:ets.lookup` directly
      for minimal latency on the hot path.
    * `put/2` and `delete/1` write the `:public` table directly as well;
      no serialisation through the GenServer is needed because there is
      no per-key state (timers, etc.) to coordinate.

  The dispatcher (`resolve_credential/1`) that consults this store
  before falling back to the Vault lands in M3 stage 3.
  """

  use GenServer

  @table :external_agents_ephemeral_credentials

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Start the store as a named GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Insert (or overwrite) the ephemeral `secret` for `agent_id`.

  Writes directly to the `:public` ETS table; no GenServer round-trip.
  """
  @spec put(binary(), binary()) :: :ok
  def put(agent_id, secret) when is_binary(agent_id) and is_binary(secret) do
    :ets.insert(@table, {agent_id, secret})
    :ok
  end

  @doc """
  Look up the ephemeral secret for `agent_id`.

  Reads directly from ETS (no GenServer call) for hot-path latency.
  Returns `{:error, :not_found}` if the table has no row for the key.
  """
  @spec get(binary()) :: {:ok, binary()} | {:error, :not_found}
  def get(agent_id) when is_binary(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, secret}] -> {:ok, secret}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Remove the ephemeral secret for `agent_id`. Idempotent.

  Writes directly to the `:public` ETS table.
  """
  @spec delete(binary()) :: :ok
  def delete(agent_id) when is_binary(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
