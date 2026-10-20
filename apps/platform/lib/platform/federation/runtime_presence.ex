defmodule Platform.Federation.RuntimePresence do
  @moduledoc """
  Tracks which external agent runtimes are currently connected via WebSocket.

  Agent-based process holding a map of runtime_id => connection info with timestamps.
  Called from RuntimeChannel join/terminate to maintain online state.

  Each entry is a map with:
    - connected_at: DateTime when the current session started
    - last_seen_at: DateTime of last incoming message (liveness indicator)
    - proven: %{capability_name => DateTime} — the last time core OBSERVED
      an inbound frame that evidences the named capability

  ## Why `proven` is not read off the client's declared feature list

  A runtime declares what it can do in `client_info.features` at join. That
  declaration is a claim made by the very process whose competence is in
  question, and it is measurably unable to discriminate the case this exists
  for. Measured on the `claude-code-suite-channel` repo across the exact
  boundary that motivated this: commit `63229eb` added the
  `meeting_transcript` listener and `b238164e` lacks it, yet both builds
  report package.json `version` `0.3.0` and `CLIENT_FEATURES`
  `["system_event_prompt"]`. `git show 63229eb -- package.json` is empty. The
  two builds send a byte-identical `client_info`; a runtime that cannot hear
  a meeting and one that can are indistinguishable by declaration.

  Process start time fails the same way in the other direction: a runtime
  measured on another host started six hours AFTER `63229eb` merged upstream
  and still could not hear a room, because its local checkout was behind.

  So `proven` records only what core actually SAW arrive. An event core
  observed cannot lie, and a capability with no inbound frame honestly reads
  as never proven rather than as a claim nobody checked.

  ## On a web node (task 01a155a6 stage 4)

  Runtimes connect to the full node, so a web node's own map is empty and
  every runtime would read as offline there. Under the web role with a
  cluster peer, the four reads (`online?/1`, `status/1`, `list_online/0`,
  `list_all/0`) also ask the peer through `Platform.Role.Peer.read/5`
  (`:erpc`, 2s timeout) and combine its answer with the local map, local
  entries winning. An unreachable peer contributes nothing. Writes stay
  local: a runtime that does connect to the web node is tracked there.
  """
  use Agent

  alias Platform.Role.Peer

  # Upper bound on the number of distinct capability keys held per runtime.
  #
  # Today the key set is closed server-side — every `prove/2` call site
  # passes a literal from this repo, so a client cannot introduce a key at
  # all. This is the abuse-surface cap for the day a call site starts
  # deriving the name from a frame, not a limit anyone should hit.
  #
  # At the cap a NEW key is dropped and existing keys still refresh. The
  # other option — evicting the oldest proof — would let a client erase
  # evidence core had already observed by flooding new names, which is the
  # one thing this map exists to prevent.
  @max_proven_capabilities 16

  # The capabilities every runtime surface reports a cell for, whether or not
  # core has ever observed one.
  #
  # A surface that only lists the keys present in a runtime's `proven` map
  # cannot express "never" — the absent cell just vanishes, and a reader sees
  # a short list rather than a gap. The gap IS the finding: this list exists
  # so an unobserved capability occupies a row and reads `never`.
  #
  # `meeting_transcript` is in this list even though NOTHING proves it today
  # (delivery is an outbound broadcast with no inbound ack — see the comment
  # at `Platform.Meetings.deliver_transcript_segment/2`). That is the point,
  # not an omission: the permanently-`never` transcript row is the single row
  # that would have ended this ticket's originating incident in ten seconds.
  # Dropping it because it is always `never` would delete the answer.
  #
  # Not an allowlist. `prove/2` accepts any capability name and readers must
  # report observations outside this list too — this is the floor of what is
  # always shown, never a ceiling on what is recorded.
  @reported_capabilities ["chat_reply", "meeting_transcript", "meeting_voice"]

  @doc """
  The capabilities a runtime surface always reports a cell for, in display
  order, whether or not core has observed one.

  Callers render an entry absent from a runtime's `proven` map as `never`
  (the design canvas is explicit: never a blank, never a dash). Observations
  recorded under names outside this list are still real evidence and must be
  reported alongside it, not filtered out.
  """
  @spec reported_capabilities() :: [String.t()]
  def reported_capabilities, do: @reported_capabilities

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Mark a runtime as online, recording the connection timestamp."
  def track(runtime_id) do
    now = DateTime.utc_now()

    Agent.update(__MODULE__, fn state ->
      # A whole-entry overwrite ON PURPOSE, unlike `touch/1`/`prove/2`: this
      # is a genuinely new session, so `proven` resets to empty. A proof
      # observed from a process that has since died says nothing about the
      # one that just connected — that is exactly the stale-build case here.
      Map.put(state, runtime_id, %{connected_at: now, last_seen_at: now, proven: %{}})
    end)
  end

  @doc "Mark a runtime as offline."
  def untrack(runtime_id) do
    Agent.update(__MODULE__, &Map.delete(&1, runtime_id))
  end

  @doc "Check if a runtime is currently connected."
  def online?(runtime_id) do
    local_online?(runtime_id) or Peer.read(__MODULE__, :local_online?, [runtime_id], false)
  end

  @doc false
  def local_online?(runtime_id), do: Agent.get(__MODULE__, &Map.has_key?(&1, runtime_id))

  @doc """
  Update the last_seen_at timestamp for a runtime (call on any incoming message).

  Self-heals when the entry is missing: any inbound frame from a live channel
  process upserts the presence entry. This recovers the map after this Agent
  process crashes/restarts while the RuntimeChannel Cowboy WS processes stay
  running — otherwise the presence map would be permanently empty even though
  every runtime is still connected, since `track/1` only runs at join time.
  """
  def touch(runtime_id) do
    Agent.update(__MODULE__, fn state ->
      now = DateTime.utc_now()

      case Map.get(state, runtime_id) do
        nil ->
          Map.put(state, runtime_id, %{connected_at: now, last_seen_at: now, proven: %{}})

        entry ->
          # `proven` is left alone: a heartbeat is not a capability.
          Map.put(state, runtime_id, %{entry | last_seen_at: now})
      end
    end)
  end

  @doc """
  Record that core OBSERVED an inbound frame evidencing `capability`.

  Call this only from a handler for a frame the runtime SENT. A frame core
  sent outbound proves nothing about whether the receiver could handle it —
  recording one here would reintroduce the defect this map exists to fix.

  Upserts like `touch/1` and, like `touch/1`, PRESERVES `connected_at` on an
  existing entry. It is not `track/1`: stamping a proof does not start a new
  session, and rewriting `connected_at` here would turn the connection age
  into a rolling clock (the shipped defect fixed in `e752bdce`).
  """
  def prove(runtime_id, capability) when is_binary(capability) do
    Agent.update(__MODULE__, fn state ->
      now = DateTime.utc_now()

      case Map.get(state, runtime_id) do
        nil ->
          Map.put(state, runtime_id, %{
            connected_at: now,
            last_seen_at: now,
            proven: %{capability => now}
          })

        entry ->
          proven =
            entry
            |> Map.get(:proven, %{})
            |> put_bounded_proof(capability, now)

          entry
          |> Map.put(:last_seen_at, now)
          |> Map.put(:proven, proven)
          |> then(&Map.put(state, runtime_id, &1))
      end
    end)
  end

  # Refreshing a key core has already proven is always allowed; only the
  # introduction of a new key is capped. See @max_proven_capabilities.
  defp put_bounded_proof(proven, capability, now) do
    cond do
      Map.has_key?(proven, capability) -> Map.put(proven, capability, now)
      map_size(proven) < @max_proven_capabilities -> Map.put(proven, capability, now)
      true -> proven
    end
  end

  @doc "Get connection info for a specific runtime, or nil if offline."
  def status(runtime_id) do
    local_status(runtime_id) || Peer.read(__MODULE__, :local_status, [runtime_id], nil)
  end

  @doc false
  def local_status(runtime_id), do: Agent.get(__MODULE__, &Map.get(&1, runtime_id))

  @doc "List all currently connected runtime_ids."
  def list_online do
    Map.keys(list_all())
  end

  @doc """
  Return the full presence map:
  `%{runtime_id => %{connected_at: DateTime, last_seen_at: DateTime, proven: map}}`
  """
  def list_all do
    Map.merge(Peer.read(__MODULE__, :local_list_all, [], %{}), local_list_all())
  end

  @doc false
  def local_list_all, do: Agent.get(__MODULE__, & &1)
end
