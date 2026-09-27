defmodule Platform.Meetings.AskFloor do
  @moduledoc """
  Per-agent floor ownership for push-to-talk (task 01a0cf5c stage 1).

  ## The gap this closes

  `Platform.Meetings.PressWindow` keys on the PRESSER's identity, not on
  the agent being addressed — by design, because its whole job is
  matching an ARRIVING TRANSCRIPT SEGMENT back to whoever was holding the
  key when it was said, and a segment has exactly one speaker. Nothing in
  that module (or anywhere else) stops two different people from holding
  the SAME agent's button at once: both open their own per-identity
  window, both get a card, and the agent hears two people at once with no
  signal to either that the other got there first.

  The design-direction canvas (Saru, 01a0cf5e-9cb0, "Design direction:
  hold to ask") calls this out as a binding requirement the mock cannot
  express on its own: a visible owner when the floor is taken, and the
  second presser's button has to say so BEFORE they start talking, not
  after. This module is the thing that makes "before" possible — it
  answers, atomically, "is this agent's floor free" at the moment a press
  lands, before any card opens and before any words are said.

  ## Same lifecycle shape as `PressWindow`, different key

  ETS, one row per `{meeting_id, agent_id}`, owned by this GenServer
  purely for the table's lifecycle: reads and the write in `claim/5` run
  directly in the caller's process (never serialised through the
  server), and the table dies with the owner — a floor claim has no
  meaning across a restart, and resurrecting one would lock an agent for
  a meeting nobody is contesting any more.

  ## The claim is atomic, not read-then-write

  `claim/5` calls `:ets.insert_new/2` on the fresh entry. Either the
  table had no row for `{meeting_id, agent_id}` and the insert wins — the
  press we just handled is the one that gets the floor — or the table
  already had one and the insert is rejected outright, atomically, with
  no window in which two concurrent presses could both read "free" and
  both write "mine". A read-then-write (`lookup` then `insert`) has
  exactly that window under concurrent callers; `insert_new` does not,
  because it is one BIF call that both checks and writes.

  A repeat claim by the SAME identity (the browser firing `pointerdown`
  and `keydown` for one physical press, matching the idempotence
  `PressWindow.press/3` and `PressCard.open/3` already rely on) is
  answered `{:ok, existing}` without disturbing the original
  `pressed_at` or restarting the stuck-claim timer — same reasoning as
  `PressWindow`'s repeat-press handling.

  ## Stuck claims (mirrors `PressWindow.max_hold_ms/0`)

  A closed tab, a dropped socket, or a `push_to_talk_release` that never
  arrives must not lock an agent's button for the rest of the meeting.
  `claim/5` arms `Process.send_after/3` for
  `Platform.Meetings.PressWindow.max_hold_ms/0` — the SAME bound a stuck
  `PressWindow` press stops matching after, reused rather than
  reinvented so the two numbers cannot drift apart. When the timer
  fires, this server checks the claim is still THE SAME claim (same
  `pressed_at` — a released-and-reclaimed or renewed floor carries a
  different one) before evicting it and, when a room id was supplied at
  claim time, broadcasting `{:ask_floor_released, %{agent_id: agent_id}}`
  on that room's topic so every connected client's button un-freezes
  even though nobody ever released it.

  ## Broadcasting is the caller's job, except for the stuck-claim case

  Every OTHER broadcast (`:ask_floor_taken` on a successful claim,
  `:ask_floor_released` on an explicit `release/3`) is emitted by
  `PlatformWeb.MeetingLive`, which already knows the room id and already
  owns every other room-topic publish for this feature. This module only
  broadcasts for the ONE event nothing else is listening for: its own
  internal stuck-claim timer firing with no LiveView process involved at
  all. `Platform.Meetings.PubSub.room_topic/1` — the existing per-room
  topic every connected client already subscribes to for participant
  join/leave — is reused rather than inventing a second one; there is
  nothing meeting-shaped about a floor ownership that a room-scoped
  topic can't already carry.

  ## Identity

  Mirrors `PressWindow`'s identity gate: a blank or non-binary identity
  is refused outright (`{:error, :invalid_identity}`) rather than stored
  as a claim nothing could ever legitimately dispute or release.
  """

  use GenServer

  alias Platform.Meetings
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  @table :meeting_ask_floor

  @type holder :: %{
          meeting_id: binary(),
          agent_id: binary(),
          identity: String.t(),
          display_name: String.t(),
          pressed_at: DateTime.t()
        }

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Start the floor-store owner. Creates the named public ETS table on
  init so reads and the atomic claim write from any process are
  lock-free. Booted from `Platform.Application`'s child list, after
  `Platform.Meetings.PressWindow` (this module reuses its
  `max_hold_ms/0`, so PressWindow must already be running — though in
  practice both are pure module-attribute reads with no runtime
  dependency on the OTHER process being alive).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # Defensive: a test harness that pre-created the table, or a
        # supervisor restart that raced the old owner's exit.
        :ok
    end

    {:ok, %{}}
  end

  @doc """
  Milliseconds a claim may sit unreleased before this server evicts it
  and (when it knows the room) broadcasts `:ask_floor_released` on its
  own. Delegates to `PressWindow.max_hold_ms/0` rather than defining a
  second constant that the same intent — "how long can a dropped socket
  lock this" — could silently drift from.
  """
  @spec stuck_claim_ms() :: pos_integer()
  def stuck_claim_ms, do: PressWindow.max_hold_ms()

  # ── Write ──────────────────────────────────────────────────────────────────

  @doc """
  Atomically claim `agent_id`'s floor in `meeting_id` for `identity`.

  `room_id`, when supplied, is stored only long enough to name the topic
  the stuck-claim timeout broadcasts on if this claim is never released
  — it is not part of the claim's identity and is never compared. Pass
  `nil` (the default) when no room is active yet; the claim still
  succeeds and still expires on schedule, it just cannot self-announce
  its own expiry (there is nobody on a room topic to tell).

  `space_id` (task 01a0e47c stage 2), when supplied, is stored the SAME
  way and for the SAME reason as `room_id` — purely so a stuck-claim
  eviction with no LiveView socket involved can still tell
  `Platform.Meetings.ask_floor_window_signal/3` which room's LiveKit
  data channel to signal "closed" on for the ONE agent kind that
  listens for it (a `services/meeting-voice-agent` worker). It is never
  compared, never part of the claim's identity, and every existing
  5-arg caller is unaffected — this is a new, defaulted 6th argument.

  Returns:

    * `{:ok, holder}` — claimed (or already held by the SAME identity,
      idempotent, original `pressed_at` intact).
    * `{:error, {:held_by, holder}}` — held by a DIFFERENT identity.
    * `{:error, :invalid_identity}` — blank/non-binary identity.
  """
  @spec claim(binary(), binary(), String.t(), String.t() | nil, binary() | nil, binary() | nil) ::
          {:ok, holder()} | {:error, {:held_by, holder()}} | {:error, :invalid_identity}
  def claim(meeting_id, agent_id, identity, display_name, room_id \\ nil, space_id \\ nil)

  def claim(meeting_id, agent_id, identity, display_name, room_id, space_id)
      when is_binary(meeting_id) and is_binary(agent_id) do
    case normalize_identity(identity) do
      nil ->
        {:error, :invalid_identity}

      known ->
        evict_if_stale(meeting_id, agent_id)
        do_claim(meeting_id, agent_id, known, display_name || known, room_id, space_id, 3)
    end
  end

  def claim(_meeting_id, _agent_id, _identity, _display_name, _room_id, _space_id),
    do: {:error, :invalid_identity}

  defp do_claim(meeting_id, agent_id, _identity, _display_name, _room_id, _space_id, 0) do
    # Practically unreachable — would need `retries` concurrent
    # claim/release races on the same key — but a bounded retry beats an
    # infinite recursion on a pathological interleaving.
    case lookup(meeting_id, agent_id) do
      nil -> {:error, :invalid_identity}
      existing -> {:error, {:held_by, existing}}
    end
  end

  defp do_claim(meeting_id, agent_id, identity, display_name, room_id, space_id, retries) do
    entry = %{
      meeting_id: meeting_id,
      agent_id: agent_id,
      identity: identity,
      display_name: display_name,
      pressed_at: DateTime.utc_now()
    }

    if :ets.insert_new(@table, {{meeting_id, agent_id}, entry}) do
      schedule_stuck_timeout(meeting_id, agent_id, entry.pressed_at, room_id, space_id)
      {:ok, entry}
    else
      case lookup(meeting_id, agent_id) do
        %{identity: ^identity} = existing ->
          {:ok, existing}

        %{} = existing ->
          {:error, {:held_by, existing}}

        nil ->
          # Raced with a release/eviction between insert_new and lookup.
          do_claim(meeting_id, agent_id, identity, display_name, room_id, space_id, retries - 1)
      end
    end
  end

  @doc """
  Release `agent_id`'s floor in `meeting_id`, but only for the identity
  that actually holds it — a release from anyone else is refused rather
  than letting a stale or mistaken release event steal the floor out
  from under its real holder.

  Returns `:ok`, `{:error, :not_holder}` (held, but by someone else),
  `{:error, :no_claim}` (nothing to release), or
  `{:error, :invalid_identity}`.
  """
  @spec release(binary(), binary(), String.t()) ::
          :ok | {:error, :not_holder | :no_claim | :invalid_identity}
  def release(meeting_id, agent_id, identity)
      when is_binary(meeting_id) and is_binary(agent_id) do
    case normalize_identity(identity) do
      nil ->
        {:error, :invalid_identity}

      known ->
        case lookup(meeting_id, agent_id) do
          nil ->
            {:error, :no_claim}

          %{identity: ^known} = entry ->
            :ets.delete_object(@table, {{meeting_id, agent_id}, entry})
            :ok

          %{} ->
            {:error, :not_holder}
        end
    end
  end

  def release(_meeting_id, _agent_id, _identity), do: {:error, :invalid_identity}

  # ── Read ───────────────────────────────────────────────────────────────────

  @doc "The current holder of `agent_id`'s floor in `meeting_id`, or `:none`."
  @spec holder(binary(), binary()) :: {:ok, holder()} | :none
  def holder(meeting_id, agent_id) when is_binary(meeting_id) and is_binary(agent_id) do
    case lookup(meeting_id, agent_id) do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  def holder(_meeting_id, _agent_id), do: :none

  @doc """
  Every held floor in `meeting_id`, in no guaranteed order. Used to seed
  a newly (re)subscribed client's view of who holds what — the room
  topic only carries events for presses/releases that happen AFTER a
  client subscribes, so a viewer joining mid-meeting needs this to see
  an already-held agent as held from their first render.
  """
  @spec list_meeting(binary()) :: [holder()]
  def list_meeting(meeting_id) when is_binary(meeting_id) do
    if table?() do
      :ets.select(@table, [{{{meeting_id, :_}, :"$1"}, [], [:"$1"]}])
    else
      []
    end
  end

  def list_meeting(_meeting_id), do: []

  @doc """
  Drop every claim for `meeting_id`. Called when a meeting ends (and by
  tests to keep the shared table from leaking state between them).
  Returns the number of rows removed.
  """
  @spec clear_meeting(binary()) :: non_neg_integer()
  def clear_meeting(meeting_id) when is_binary(meeting_id) do
    if table?() do
      :ets.select_delete(@table, [{{{meeting_id, :_}, :_}, [], [true]}])
    else
      0
    end
  end

  def clear_meeting(_meeting_id), do: 0

  # ── The stuck-claim eviction ─────────────────────────────────────────────

  @impl true
  def handle_info(
        {:stuck_claim_elapsed, meeting_id, agent_id, pressed_at, room_id, space_id},
        state
      ) do
    # Only act if this is still THE SAME claim that armed the timer — a
    # release-and-reclaim, or a claim that was never made stale in the
    # first place, carries a different `pressed_at` and this clause is a
    # no-op for it, exactly like `PressWindow`'s `:grace_elapsed` guard.
    case lookup(meeting_id, agent_id) do
      %{pressed_at: ^pressed_at} = entry ->
        :ets.delete_object(@table, {{meeting_id, agent_id}, entry})

        if is_binary(room_id) do
          MeetingsPubSub.broadcast_room(room_id, {:ask_floor_released, %{agent_id: agent_id}})
        end

        # Task 01a0e47c stage 2: the ONLY place a stuck (dropped-socket)
        # claim's LiveKit "listening window" ever gets told to close —
        # there is no LiveView process left to have called
        # `release_ask_floor/4` for this claim, so this GenServer, which
        # already runs exactly once regardless of how many viewers are
        # connected, is the single correct place to do it. A no-op for
        # every agent but the one LiveKit-dispatched voice worker (see
        # `Meetings.ask_floor_window_signal/3`), and a no-op outright
        # when this claim never had a `space_id` (an older/positional
        # 5-arg caller, or no room active yet at claim time).
        Meetings.ask_floor_window_signal(agent_id, space_id, :closed)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Internals ──────────────────────────────────────────────────────────────

  defp schedule_stuck_timeout(meeting_id, agent_id, pressed_at, room_id, space_id) do
    Process.send_after(
      __MODULE__,
      {:stuck_claim_elapsed, meeting_id, agent_id, pressed_at, room_id, space_id},
      stuck_claim_ms()
    )
  end

  # Compare-and-delete: reads the current entry and, only if it is
  # already past `stuck_claim_ms/0`, deletes THAT EXACT object.
  # `:ets.delete_object/2` matches on the full stored tuple, so a claim
  # that changed between this read and the delete (a release, or a fresh
  # claim after this one expired and was already reaped by the timer)
  # is left alone rather than being deleted out from under its new
  # holder.
  defp evict_if_stale(meeting_id, agent_id) do
    case lookup(meeting_id, agent_id) do
      nil ->
        :ok

      %{pressed_at: pressed_at} = entry ->
        if DateTime.diff(DateTime.utc_now(), pressed_at, :millisecond) > stuck_claim_ms() do
          :ets.delete_object(@table, {{meeting_id, agent_id}, entry})
        end

        :ok
    end
  end

  defp normalize_identity(identity) when is_binary(identity) do
    case String.trim(identity) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_identity(_identity), do: nil

  defp lookup(meeting_id, agent_id) do
    if table?() do
      case :ets.lookup(@table, {meeting_id, agent_id}) do
        [{_key, entry}] -> entry
        _ -> nil
      end
    else
      nil
    end
  end

  # Wrapped so calls during early boot (before `init/1` installed the
  # table) return benign defaults instead of crashing the caller — the
  # same guard `Platform.Meetings.PressWindow` uses.
  defp table?, do: :ets.info(@table) != :undefined
end
