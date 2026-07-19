defmodule Platform.Chat.SpacePurger do
  @moduledoc """
  Permanently deletes channels whose scheduled deletion passed its
  retention window (task 019e95ea stage 3).

  `Platform.Chat.schedule_space_deletion/2` archives a channel and stamps
  `deletion_scheduled_at`. The channel immediately vanishes from every
  listing/search surface but stays recoverable via
  `Platform.Chat.cancel_space_deletion/2` until
  `Platform.Chat.space_retention_days/0` days have elapsed. This GenServer
  ticks daily and hard-deletes any channel past that deadline — the DB
  foreign keys cascade the space's messages, participants, threads, pins,
  canvases, space_agents, attention routing, attachments, and meetings.

  ## Ownership split with `Platform.Tenancy.ContainerPurger`

  This purger owns ONLY directly-scheduled channels — its candidate query
  and per-row re-check both require `archived_cascade_org_id IS NULL`.
  Channels cascade-hidden by a scheduled org carry the marker AND their own
  deletion clock (task 019f760f); `ContainerPurger` purges those under
  container retention. Without this `IS NULL` filter both purgers would key
  off the same own-clock predicate and race to delete one row.

  Safety posture (per security review): the sweep runs in one transaction,
  every delete re-verifies kind + the cascade marker + BOTH lifecycle flags
  in the delete query itself (not just the select), and an impossible row
  count raises so the whole sweep rolls back. Non-channel rows carrying
  deletion flags can only come from corruption or a bug — they are never
  deleted, only warned about.
  """

  use GenServer

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Repo

  import Ecto.Query, only: [from: 2]

  @tick_interval_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one sweep synchronously. Returns `{:ok, purged_count}`."
  @spec sweep() :: {:ok, non_neg_integer()}
  def sweep, do: do_sweep()

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    {:ok, _count} = do_sweep()
    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp do_sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -Chat.space_retention_days(), :day)

    {:ok, purged} =
      Repo.transaction(fn ->
        warn_on_corrupted_flags(cutoff)

        candidates =
          Repo.all(
            from(s in Space,
              where:
                s.kind == "channel" and is_nil(s.archived_cascade_org_id) and
                  not is_nil(s.archived_at) and not is_nil(s.deletion_scheduled_at) and
                  s.deletion_scheduled_at < ^cutoff
            )
          )

        Enum.filter(candidates, &purge_candidate(&1, cutoff))
      end)

    # Telemetry fires only after the transaction commits — a rolled-back
    # sweep must not leave phantom purge entries in the audit log.
    Enum.each(purged, &emit_purged_telemetry/1)
    Logger.info("[space_purger] purged #{length(purged)} channel(s) past retention")
    {:ok, length(purged)}
  end

  # Deletes one candidate, re-verifying kind, the cascade marker, and both
  # lifecycle flags in the delete query itself so a row mutated between select
  # and delete (e.g. a deletion cancelled mid-sweep, or an org cascade
  # claiming the channel) is never purged. Exactly 0 (skip + warn) or 1 row
  # may be affected — anything else raises, rolling back the sweep.
  defp purge_candidate(%Space{} = candidate, cutoff) do
    {deleted, _} =
      Repo.delete_all(
        from(s in Space,
          where:
            s.id == ^candidate.id and s.kind == "channel" and
              is_nil(s.archived_cascade_org_id) and not is_nil(s.archived_at) and
              not is_nil(s.deletion_scheduled_at) and s.deletion_scheduled_at < ^cutoff
        )
      )

    case deleted do
      1 ->
        true

      0 ->
        Logger.warning(
          "[space_purger] candidate #{candidate.id} no longer matched the " <>
            "delete re-check — skipped"
        )

        false

      other ->
        raise "space purge affected #{other} rows for id #{candidate.id} — " <>
                "expected exactly 1, rolling back sweep"
    end
  end

  # `schedule_space_deletion/2` kind-guards, so deletion flags on a dm,
  # group, or execution space mean corruption or a bug. Refuse to purge
  # (execution spaces are task audit logs) and surface loudly instead.
  defp warn_on_corrupted_flags(cutoff) do
    from(s in Space,
      where:
        s.kind != "channel" and not is_nil(s.deletion_scheduled_at) and
          s.deletion_scheduled_at < ^cutoff,
      select: {s.id, s.kind}
    )
    |> Repo.all()
    |> Enum.each(fn {id, kind} ->
      Logger.warning(
        "[space_purger] #{kind} space #{id} has deletion_scheduled_at past " <>
          "retention — refusing to purge non-channel space"
      )
    end)
  end

  # Bridged into the audit log by `Platform.Audit.TelemetryHandler`.
  # `deletion_scheduled_at` is stringified so the bridge's JSON pass
  # doesn't choke on a DateTime struct.
  defp emit_purged_telemetry(%Space{} = space) do
    :telemetry.execute(
      [:platform, :chat, :space_purged],
      %{system_time: System.system_time()},
      %{
        actor_id: nil,
        actor_type: "system",
        resource_type: "chat_space",
        resource_id: space.id,
        action: "space_purged",
        space_kind: space.kind,
        space_name: space.name,
        deletion_scheduled_at: DateTime.to_iso8601(space.deletion_scheduled_at)
      }
    )
  end
end
