defmodule Platform.Federation.OrphanRuntimes do
  @moduledoc """
  One-off sweep for runtimes orphaned before task 01a1b34b stage 1 landed:
  `active` rows whose agent was deleted, leaving `agent_id` NULL and the
  token hash set.

  This is NOT a migration and nothing here runs on deploy. It is called by
  `mix platform.revoke_orphan_runtimes` locally, and from a release (prod has
  no mix) through the running node:

      bin/platform rpc 'Platform.Federation.OrphanRuntimes.print(dry_run: true)'
      bin/platform rpc 'Platform.Federation.OrphanRuntimes.print(dry_run: false)'

  Prefer `rpc` over `eval` in a release. `eval` boots a second VM with no
  `RuntimePresence` process, so it cannot see which runtimes are connected;
  this module refuses to run in that state (`{:error, :presence_unavailable}`)
  rather than treat every runtime as offline.

  ## Orphan criterion

      status = 'active'
      AND agent_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM agents a WHERE a.runtime_id = agent_runtimes.id)
      AND (last_connected_at IS NULL OR last_connected_at < now() - :stale_days days)
      AND NOT RuntimePresence.online?(runtime_id)

  `:runtime_ids` names rows explicitly. A named row must still satisfy every
  condition except staleness: that is how a runtime that connected recently
  (e.g. `agentgateway-locke`) is revoked once a human approves it.

  ## Options

    * `:stale_days` - staleness cutoff in days (default 7)
    * `:runtime_ids` - list of runtime_id strings; drops the staleness clause
      and restricts the sweep to those ids
    * `:dry_run` - `revoke_orphans/1` only; defaults to `true`. Revokes only
      when exactly `false`.
    * `:now` - the reference time (tests)
  """

  import Ecto.Query

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  @default_stale_days 7

  @type row :: %{
          id: Ecto.UUID.t(),
          runtime_id: String.t(),
          owner_user_id: Ecto.UUID.t(),
          display_name: String.t() | nil,
          last_connected_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          role: term()
        }

  @doc "Default staleness cutoff, in days."
  def default_stale_days, do: @default_stale_days

  @doc """
  Rows matching the orphan criterion. Read-only.

  Returns `{:ok, rows}` or `{:error, :presence_unavailable}`.
  """
  @spec list_orphans(keyword()) :: {:ok, [row()]} | {:error, :presence_unavailable}
  def list_orphans(opts \\ []) do
    with :ok <- ensure_presence() do
      rows =
        opts
        |> orphans_query()
        |> order_by([r], asc: r.runtime_id)
        |> Repo.all()
        |> Enum.reject(&online?/1)
        |> Enum.map(&to_row/1)

      {:ok, rows}
    end
  end

  @doc """
  Revoke every orphan. A dry run (the default) only lists them.

  Returns `{:ok, %{dry_run: true, orphans: rows}}`, or with `dry_run: false`
  `{:ok, %{dry_run: false, orphans: rows, revoked: rows}}`. Each orphan is
  re-checked under a row lock before it is revoked, so a row that gained an
  agent or connected since the listing is skipped (and absent from
  `revoked`).

  Each revocation goes through `Federation.revoke_runtime/1`, then the same
  post-revoke steps as agent delete (`Federation.finalize_revoked_runtimes/2`):
  a `"disconnect"` broadcast and abandoning the runtime's live dead letters.
  """
  @spec revoke_orphans(keyword()) :: {:ok, map()} | {:error, :presence_unavailable}
  def revoke_orphans(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true) != false

    with {:ok, orphans} <- list_orphans(opts) do
      if dry_run? do
        {:ok, %{dry_run: true, orphans: orphans}}
      else
        revoked = Enum.flat_map(orphans, &revoke_one(&1, opts))
        {:ok, %{dry_run: false, orphans: orphans, revoked: revoked}}
      end
    end
  end

  @doc """
  `revoke_orphans/1` plus a printed table, for `bin/platform rpc`. Returns
  the same value.
  """
  def print(opts \\ []) do
    result = revoke_orphans(opts)
    result |> format_result() |> Enum.each(&IO.puts/1)
    result
  end

  @doc "Human-readable lines for a `revoke_orphans/1` result."
  @spec format_result({:ok, map()} | {:error, term()}) :: [String.t()]
  def format_result({:error, :presence_unavailable}) do
    [
      "revoke_orphan_runtimes: RuntimePresence is not running in this VM, so online " <>
        "runtimes cannot be told apart. Run it on the live node (bin/platform rpc), not eval."
    ]
  end

  def format_result({:ok, %{dry_run: true, orphans: orphans}}) do
    table(orphans) ++
      ["DRY RUN: #{length(orphans)} orphan runtime(s) would be revoked. Pass --apply to revoke."]
  end

  def format_result({:ok, %{dry_run: false, orphans: orphans, revoked: revoked}}) do
    skipped = length(orphans) - length(revoked)

    table(revoked) ++
      ["APPLIED: revoked #{length(revoked)} orphan runtime(s); #{skipped} skipped on re-check."]
  end

  # ── criterion ──────────────────────────────────────────────────────────

  @doc false
  # The orphan criterion as one query, minus the presence check (in-memory).
  def orphans_query(opts) do
    referenced = from(a in Agent, where: a.runtime_id == parent_as(:runtime).id, select: 1)

    query =
      from(r in AgentRuntime,
        as: :runtime,
        where: r.status == "active",
        where: is_nil(r.agent_id),
        where: not exists(referenced)
      )

    case Keyword.get(opts, :runtime_ids, []) do
      [] ->
        cutoff = cutoff(opts)

        where(
          query,
          [r],
          is_nil(r.last_connected_at) or r.last_connected_at < ^cutoff
        )

      ids when is_list(ids) ->
        where(query, [r], r.runtime_id in ^ids)
    end
  end

  defp cutoff(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    days = Keyword.get(opts, :stale_days, @default_stale_days)
    DateTime.add(now, -days * 86_400, :second)
  end

  defp revoke_one(%{id: id}, opts) do
    Repo.transaction(fn ->
      opts
      |> orphans_query()
      |> where([r], r.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil ->
          Repo.rollback(:no_longer_orphan)

        %AgentRuntime{} = runtime ->
          if online?(runtime), do: Repo.rollback(:online)

          case Federation.revoke_runtime(runtime) do
            {:ok, revoked} -> revoked
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, revoked} ->
        Federation.finalize_revoked_runtimes([revoked], reason: "orphan_runtime_revoked")
        [to_row(revoked)]

      {:error, _reason} ->
        []
    end
  end

  defp ensure_presence do
    if Process.whereis(RuntimePresence), do: :ok, else: {:error, :presence_unavailable}
  end

  defp online?(%AgentRuntime{runtime_id: runtime_id}), do: RuntimePresence.online?(runtime_id)

  defp to_row(%AgentRuntime{} = r) do
    %{
      id: r.id,
      runtime_id: r.runtime_id,
      owner_user_id: r.owner_user_id,
      display_name: r.display_name,
      last_connected_at: r.last_connected_at,
      inserted_at: r.inserted_at,
      role: (r.metadata || %{})["role"]
    }
  end

  defp table([]), do: []

  defp table(rows) do
    header = ~w(id runtime_id owner_user_id display_name last_connected_at inserted_at role)

    lines =
      Enum.map(rows, fn row ->
        [
          row.id,
          row.runtime_id,
          row.owner_user_id,
          row.display_name,
          row.last_connected_at,
          row.inserted_at,
          row.role
        ]
        |> Enum.map(&cell/1)
      end)

    [header | lines]
    |> Enum.map(&Enum.join(&1, "  "))
  end

  defp cell(nil), do: "-"
  defp cell(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp cell(value) when is_binary(value), do: value
  defp cell(value), do: inspect(value)
end
