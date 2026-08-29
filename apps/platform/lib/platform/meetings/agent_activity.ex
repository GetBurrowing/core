defmodule Platform.Meetings.AgentActivity do
  @moduledoc """
  Per-meeting agent activity — what an agent is doing *in this meeting,
  right now* (task `01a04a98`).

  Before this module the meeting bottom strip's `<.agent_tile>` was
  passed `activity_state={:idle}` as a literal at its only call site,
  and the participant rail's status dot read `agents.status` — a
  GLOBAL column that says nothing about the meeting being viewed. Both
  surfaces claimed to be activity signals; neither was.

  ## The two real signals

  There is no `meeting_activity` table and this module does not add
  one. It folds the two per-meeting signals that already exist:

    * **`:computing`** — `Platform.Meetings.IntentQueue` is meeting- AND
      agent-scoped and already tracks `@in_flight_statuses
      [:dispatched, :acked]` against a `target_agent_id`. An in-flight
      row IS "this agent is working on something for this meeting".
      Mirrored onto the meeting shell topic from the queue server's
      single transition write path, and hydrated at mount from
      `IntentQueue.list/1`.

    * **`:typing`** — `{:agent_typing, %{space_id, participant_id,
      typing}}`, broadcast on the meeting's chat-space topic by
      `Platform.Chat.AgentResponder` and `PlatformWeb.RuntimeChannel`.
      `participant_id` there is a `Platform.Chat.Participant` id, not
      an `Agents.Agent` id, so it has to be bridged —
      `agent_id_for_chat_participant/1` is that bridge.

  ## `:listening` has no producer

  `:listening` is a declared state of `<.agent_tile>` and is
  deliberately left UNREACHABLE. Nothing in the system emits "this
  agent is listening": LiveKit's `ActiveSpeakersChanged` is a
  client-side signal about *audio* that never identifies an agent tile
  (the client's identity space is `"agent:" <> slug`; the tile's is
  `"agent:" <> agent_id`), and TTS playback is not modelled anywhere.
  Faking it — deriving it from "the agent is in the room" — would
  rebuild exactly the always-on lie this task exists to remove. It
  stays in the enum so the tile keeps a slot for a real producer.

  ## Precedence

  `:typing` beats `:computing`. Both mean the agent is working, but
  typing is the narrower and more recent claim about the same agent —
  an agent that is emitting output is by definition still working, so
  `:computing` adds nothing on top of it.

  ## What this is NOT

  Not a process and not a store. `%AgentActivity{}` is a value a
  consumer (today, `PlatformWeb.MeetingLive`) holds in its own state
  and folds signals into. Two consequences worth naming:

    * A socket that mounts mid-meeting hydrates `:computing` from the
      live queue, but **cannot** hydrate `:typing` — the typing signal
      is a transient broadcast with nowhere to read it back from. A
      late joiner sees a typing agent from its next toggle onward.
    * If a meeting's queue owner stops (`:meeting_finished`) while a
      row is in flight, no terminal transition is broadcast and a live
      socket keeps that agent `:computing` until it remounts. The
      alternative — inventing a terminal state the queue never
      reached — would be a worse lie than a stale one.
  """

  alias Platform.Chat.Participant
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  @typedoc "The activity states `PlatformWeb.Components.Meeting.AgentTile` renders."
  @type state :: :idle | :typing | :computing | :listening

  @typedoc "A raw signal name. `:listening` is absent — it has no producer."
  @type signal :: :computing | :typing

  @states [:idle, :typing, :computing, :listening]
  @signals [:computing, :typing]

  # Ordered by precedence, highest first. `resolve/1` walks this, so
  # adding a producer means adding its signal here rather than editing
  # a cond.
  @precedence [:typing, :computing]

  defstruct computing: MapSet.new(), typing: MapSet.new()

  @type t :: %__MODULE__{computing: MapSet.t(), typing: MapSet.t()}

  @doc "The four states an agent tile can render."
  @spec states() :: [state()]
  def states, do: @states

  @doc "The signals that actually have a producer."
  @spec signals() :: [signal()]
  def signals, do: @signals

  @doc "An empty activity value — every agent resolves `:idle`."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Seed `:computing` from `meeting_id`'s LIVE intent queue.

  This is the mount-time hydration, and it is the difference between a
  late-joining viewer seeing the truth and seeing an agent frozen at
  whatever the tile's default happened to be. `IntentQueue.list/1`
  returns `[]` when no owner is running, which correctly resolves to
  "every agent idle".
  """
  @spec hydrate(binary()) :: t()
  def hydrate(meeting_id) when is_binary(meeting_id) do
    in_flight = IntentQueue.in_flight_statuses()

    computing =
      meeting_id
      |> IntentQueue.list()
      |> Enum.filter(fn row ->
        Map.get(row, :status) in in_flight and is_binary(Map.get(row, :target_agent_id))
      end)
      |> MapSet.new(& &1.target_agent_id)

    %__MODULE__{computing: computing}
  end

  def hydrate(_), do: new()

  @doc """
  Fold one signal into the activity value.

  `active?` false removes the agent from that signal without touching
  the other — an agent can stop typing while an intent is still in
  flight, and that must resolve `:computing`, not `:idle`.
  """
  @spec put(t(), signal(), binary(), boolean()) :: t()
  def put(%__MODULE__{} = activity, signal, agent_id, active?)
      when signal in @signals and is_binary(agent_id) and is_boolean(active?) do
    set = Map.fetch!(activity, signal)

    updated =
      if active?, do: MapSet.put(set, agent_id), else: MapSet.delete(set, agent_id)

    Map.put(activity, signal, updated)
  end

  def put(%__MODULE__{} = activity, _signal, _agent_id, _active?), do: activity

  @doc """
  The `%{agent_id => state}` map. Idle agents are ABSENT rather than
  mapped to `:idle`, so the map's size is the number of agents actually
  doing something.
  """
  @spec resolve(t()) :: %{binary() => state()}
  def resolve(%__MODULE__{} = activity) do
    Enum.reduce(@precedence, %{}, fn signal, acc ->
      activity
      |> Map.fetch!(signal)
      |> Enum.reduce(acc, fn agent_id, inner ->
        Map.put_new(inner, agent_id, signal)
      end)
    end)
  end

  @doc """
  This agent's state, defaulting to `:idle`.

  Accepts either the struct or an already-resolved map so a render can
  take whichever it holds.
  """
  @spec for_agent(t() | %{binary() => state()} | nil, binary() | nil) :: state()
  def for_agent(nil, _agent_id), do: :idle
  def for_agent(_activity, agent_id) when not is_binary(agent_id), do: :idle

  def for_agent(%__MODULE__{} = activity, agent_id) do
    Enum.find_value(@precedence, :idle, fn signal ->
      if MapSet.member?(Map.fetch!(activity, signal), agent_id), do: signal
    end)
  end

  def for_agent(map, agent_id) when is_map(map), do: Map.get(map, agent_id, :idle)

  # ── Publishing ─────────────────────────────────────────────────────────────

  @doc """
  Mirror an intent row's in-flight-ness onto the meeting SHELL topic.

  Called from `Platform.Meetings.IntentQueue.Server`'s single status
  write path, so there is exactly one publisher per transition. The
  shell topic (`meeting:<id>`) is used rather than
  `meeting:<id>:intents` because **guests subscribe to the shell topic
  and not to the intents topic** — an agent tile that only lit up for
  authenticated viewers would be a second half-truth.

  A row with no `target_agent_id` is not about any one agent and is
  silently ignored.
  """
  @spec mirror_intent_row(binary(), map()) :: :ok
  def mirror_intent_row(meeting_id, %{target_agent_id: agent_id} = row)
      when is_binary(meeting_id) and is_binary(agent_id) do
    broadcast(
      meeting_id,
      :computing,
      agent_id,
      Map.get(row, :status) in IntentQueue.in_flight_statuses()
    )
  end

  def mirror_intent_row(_meeting_id, _row), do: :ok

  @doc """
  Publish `{:agent_activity, %{meeting_id, agent_id, signal, active?}}`
  on the meeting shell topic.

  The payload is the RAW signal, not the resolved state, because
  resolution needs both signals at once and only the consumer holds
  both.
  """
  @spec broadcast(binary(), signal(), binary(), boolean()) :: :ok
  def broadcast(meeting_id, signal, agent_id, active?)
      when is_binary(meeting_id) and signal in @signals and is_binary(agent_id) and
             is_boolean(active?) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      MeetingsPubSub.meeting_topic(meeting_id),
      {:agent_activity,
       %{meeting_id: meeting_id, agent_id: agent_id, signal: signal, active?: active?}}
    )
  end

  # ── The Chat.Participant <-> Agent bridge ──────────────────────────────────

  @doc """
  Resolve a `Platform.Chat.Participant` id to the `Agents.Agent` id it
  seats, or `nil`.

  `{:agent_typing, …}` carries a chat participant id; every meeting
  surface keys agents by `agents.id` (that is what
  `Meetings.Participant.agent_id` and the tile's `data-agent` are).
  Without this bridge the typing signal arrives addressed to an id no
  meeting surface has ever heard of — which is why the event was
  reaching `MeetingLive` and being dropped by its catch-all.

  Returns `nil` for a human participant, so a human's typing indicator
  can never light an agent tile.
  """
  @spec agent_id_for_chat_participant(binary() | nil) :: binary() | nil
  def agent_id_for_chat_participant(participant_id) when is_binary(participant_id) do
    # `Platform.UUID.valid?/1`, not a bare `is_binary`: this id arrives on a
    # PubSub payload rather than out of a query, `Repo.get/2` RAISES
    # `Ecto.Query.CastError` on a malformed one, and the raise would land
    # inside a `handle_info` and take the whole MeetingLive down. `nil` — "no
    # agent behind that id" — is already the honest answer for every other
    # miss on this path.
    if Platform.UUID.valid?(participant_id) do
      lookup_agent_id(participant_id)
    else
      nil
    end
  end

  def agent_id_for_chat_participant(_), do: nil

  defp lookup_agent_id(participant_id) do
    case Repo.get(Participant, participant_id) do
      %Participant{participant_type: "agent", participant_id: agent_id}
      when is_binary(agent_id) ->
        agent_id

      _ ->
        nil
    end
  end
end
