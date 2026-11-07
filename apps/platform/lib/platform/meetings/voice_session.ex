defmodule Platform.Meetings.VoiceSession do
  @moduledoc """
  The Voice tab's 1:1 spoken conversation with an agent (task 01a1557a-eab7).

  Composes the meetings Ask pipeline; it reimplements none of it. Everything
  is keyed by the user<->agent DM space, so no `Meeting` record is needed:

    * `Chat.find_or_create_dm/3` gives the space;
    * `Meetings.ensure_room/1` gives the LiveKit room `"space-<dm id>"`;
    * `Meetings.invite_agent/4` dispatches the voice worker with
      `"mode" => "voice_1to1"` and the chosen `"voice_context"`;
    * `Meetings.generate_token/2` mints the viewer's token;
    * `AskFloor.claim/6` + `Meetings.ask_floor_window_signal/3` open and close
      the worker's listening window, exactly as the meeting press does.

  ## The room is shared with a DM call on purpose

  A call or quick-meet started in the same DM lands in the same room,
  `"space-<dm id>"`. A DM call with the agent and a Voice-tab session are the
  same 1:1 conversation, so there is deliberately no separate room key.

  The room is not a meeting while only the Voice tab uses it, so LiveKit's
  `room_finished` must not finalize it as one (task 01a174e2: no Meeting
  Summary in the DM). The session therefore says so in the room's config
  (`Meetings.set_session_mode/2`, `"voice_1to1"`), and the webhook skips the
  summary path for a stamped room. The rule, because the room is shared:

    * `start/3` stamps the mode right after `ensure_room/1` (before the token
      and the dispatch, so it lands before LiveKit's `room_started`), UNLESS
      the room's status is `"active"` with a human still in it. Only a human
      call join sets that status, never a voice session, so a live call is
      never relabelled; an "active" room whose callers have all left (the
      status stays until `room_finished`) is stamped.
    * `Meetings.join_for_user/3`, the one human call join path, always
      clears the mode: the call wins and is summarized.
    * `room_finished` clears the mode after handling.

  So voice then call is summarized as a call, call then voice is summarized
  as a call, and voice alone produces no summary. A stale stamp left by a
  missed `room_finished` is cleared by the next call join. The transcriber is
  still dispatched (it rides on room creation and a later call in the same
  room needs it); the webhook discards what it recorded for the voice session.

  ## Context

  "No context" or ONE space the viewer participates in. Projects and tasks
  are out of scope. The worker is told on dispatch (`voice_context`) and on
  every change (`set_context/2`, topic `"mva.context"`).

  ## What is recorded (task 01a1b6c3)

  Both sides of every session land in the user<->agent DM, ONE MESSAGE PER
  TURN (`record_turn/5`), each tagged with metadata
  `%{"source" => "voice", "voice_session_id" => <session id>, "voice_turn" =>
  <1-based index>, "input" => "voice" | "typed"}`:

    * a user turn posts AS the user's DM participant, an agent turn AS the
      agent's DM participant;
    * a user turn spoken while a context is set posts ONLY to that context
      (`post_transcript/4`, tagged the same way) and is not copied into the
      DM. The DM gets ONE pointer row per (session, context) instead
      (`"voice_kind" => "context_pointer"`, "Your side was posted to
      #<name>"). A refused context post (`:forbidden`) falls back to the DM,
      so nothing is lost. Known limit: in a with-context session the DM shows
      the agent's replies and the pointer; the user's side lives in the
      context;
    * only FINAL captions are turns: an explicit `final: false` posts
      nothing, and a repeated segment id posts once per session;
    * at session end `finish/1` posts ONE summary row (`content_type:
      "system"`, the agent's participant, `"voice_kind" => "summary"`, "Voice
      chat · N turns · M min"), idempotent per session id, none for a session
      with no turns. `finish_unfinished/1` is the `room_finished` fallback.

  None of these rows routes: in a DM `AttentionRouter.dm_voice_record?/2`
  skips them (no agent reply, no push), `Chat` creates no inbox row for them,
  and every DM row is written with `post_message/2`'s `:mark_read_for` the
  user's DM participant, so the DM's unread count does not move: the user
  just heard the conversation. A context post in a channel routes as a normal
  message, as before.
  """

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.SpaceAccess
  alias Platform.Meetings
  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room

  @default_partner_slug "meeting-assistant"
  @context_topic "mva.context"
  @mode "voice_1to1"

  @type context :: nil | :none | %{required(:id) => binary(), optional(:name) => String.t()}

  @type session :: %{
          required(:space_id) => binary(),
          required(:agent_id) => binary(),
          optional(:id) => binary(),
          optional(:started_at) => DateTime.t() | nil,
          optional(:room_name) => String.t(),
          optional(:token) => String.t(),
          optional(:livekit_url) => String.t() | nil,
          optional(:user_participant_id) => binary(),
          optional(:agent_participant_id) => binary(),
          optional(:turns) => non_neg_integer(),
          optional(:segments) => MapSet.t(),
          optional(:pointers) => MapSet.t()
        }

  # How far back `finish_unfinished/1` looks for a session a room left
  # without a summary.
  @unfinished_window_s 24 * 60 * 60
  @max_segment_id 200

  @doc "The topic `set_context/2` sends on."
  def context_topic, do: @context_topic

  @doc "The dispatch `mode` a voice session's worker is started with."
  def mode, do: @mode

  @doc """
  The default voice partner: the viewer-visible agent with slug
  `"meeting-assistant"` (Burrow), or nil.
  """
  @spec default_partner(map()) :: Agent.t() | nil
  def default_partner(user) do
    user
    |> visible_agents()
    |> Enum.find(&(&1.slug == @default_partner_slug))
  end

  @doc """
  Every agent visible to the viewer, Burrow first, each as
  `%{agent: agent, reachable?: boolean}`. `reachable?` is
  `Meetings.voice_reachable?/1`, the same check `invite_agent/3` refuses on.
  """
  @spec partners(map()) :: [%{agent: Agent.t(), reachable?: boolean()}]
  def partners(user) do
    {burrow, others} =
      user
      |> visible_agents()
      |> Enum.split_with(&(&1.slug == @default_partner_slug))

    Enum.map(burrow ++ others, fn agent ->
      %{agent: agent, reachable?: Meetings.voice_reachable?(agent) == :ok}
    end)
  end

  @doc """
  Start (or rejoin) a voice session between `user` and `agent`.

  Idempotent per (user, agent): the DM and room are found, not recreated, and
  the agent is not dispatched again while its participant row in the room is
  live (a worker actually published, i.e. the row carries a LiveKit
  identity). An invite that never arrived is re-dispatched, the same recovery
  `invite_agent/3` documents.
  """
  @spec start(map(), Agent.t(), context()) ::
          {:ok, session()}
          | {:error, :voice_runtime_offline | :no_runtime | :livekit_not_configured | term()}
  def start(%{id: user_id} = user, %Agent{} = agent, context) do
    with :ok <- Meetings.voice_reachable?(agent),
         {:ok, voice_context} <- normalize_context(user, context),
         {:ok, dm} <- Chat.find_or_create_dm(user_id, "agent", agent.id),
         {:ok, %Room{} = room} <- Meetings.ensure_room(dm.id),
         {:ok, %Room{} = room} <- stamp_session_mode(room),
         {:ok, token} <-
           Meetings.generate_token(room, %{identity: identity(user), name: display_name(user)}),
         :ok <- ensure_agent_dispatched(room, agent, user, voice_context),
         {:ok, user_participant} <- SpaceAccess.authorize_writer(dm.id, user),
         {:ok, agent_participant} <- SpaceAccess.authorize_writer(dm.id, {:agent, agent.id}) do
      {:ok,
       %{
         id: Platform.Types.UUIDv7.generate(),
         started_at: DateTime.utc_now(),
         space_id: dm.id,
         room_name: room.livekit_room_name,
         token: token,
         livekit_url: Meetings.livekit_url(),
         agent_id: agent.id,
         user_participant_id: user_participant.id,
         agent_participant_id: agent_participant.id,
         turns: 0,
         segments: MapSet.new(),
         pointers: MapSet.new()
       }}
    end
  end

  @doc """
  Record one FINAL turn of `session` (see the moduledoc's "What is
  recorded"). `who` is `:me` or `:agent`.

  Options: `:input` (`:voice`, the default, or `:typed`), `:context` (the
  conversation's `%{id, name}` or nil, read for `:me` turns only),
  `:segment_id` (the caption's segment id, deduped per session) and
  `:final` (an explicit `false` posts nothing).

  Returns `{:ok, session, %{message: message, posted_to: name | nil}}`,
  `posted_to` naming the context a `:me` turn went to; `{:skip, session,
  :not_final | :duplicate | :blank}` when nothing was posted; or `{:error,
  reason, session}` when the post itself failed. Always thread the returned
  session into the next call: it carries the turn index, the seen segment ids
  and the contexts already pointed to.
  """
  @spec record_turn(session(), map(), :me | :agent, String.t() | nil, keyword()) ::
          {:ok, session(), %{message: Chat.Message.t(), posted_to: String.t() | nil}}
          | {:skip, session(), :not_final | :duplicate | :blank}
          | {:error, term(), session()}
  def record_turn(session, user, who, text, opts \\ []) when who in [:me, :agent] do
    content = if is_binary(text), do: String.trim(text), else: ""
    segment_id = segment_id(Keyword.get(opts, :segment_id))
    session = with_defaults(session)

    cond do
      Keyword.get(opts, :final) == false ->
        {:skip, session, :not_final}

      segment_id && MapSet.member?(session.segments, segment_id) ->
        {:skip, session, :duplicate}

      content == "" ->
        {:skip, session, :blank}

      true ->
        turn = session.turns + 1
        meta = turn_metadata(session, turn, Keyword.get(opts, :input, :voice))

        case write_turn(session, user, who, content, meta, Keyword.get(opts, :context)) do
          {:ok, message, posted_to, session} ->
            session = %{
              session
              | turns: turn,
                segments:
                  if(segment_id,
                    do: MapSet.put(session.segments, segment_id),
                    else: session.segments
                  )
            }

            {:ok, session, %{message: message, posted_to: posted_to}}

          {:error, reason} ->
            {:error, reason, session}
        end
    end
  end

  @doc """
  Close `session`: post its ONE summary row into the DM (see the moduledoc).
  Idempotent per session id, across processes: the check and the write run
  under a cluster-wide lock on the id, so `VoiceLive`'s end of session and the
  `room_finished` fallback racing each other post once. Returns
  `{:ok, message}`, `{:ok, :already_finished}` or `{:ok, :no_turns}`.
  """
  @spec finish(session() | nil) ::
          {:ok, Chat.Message.t() | :already_finished | :no_turns | :no_session}
          | {:error, term()}
  def finish(%{id: id, space_id: space_id} = session)
      when is_binary(id) and is_binary(space_id) do
    :global.trans({{__MODULE__, :finish, id}, self()}, fn -> do_finish(session) end)
  end

  def finish(_session), do: {:ok, :no_session}

  @doc """
  The `room_finished` fallback for a `"voice_1to1"`-stamped room: `finish/1`
  every session recorded in the DM `dm_space_id` (in the last 24 hours) that
  has no summary yet. Returns how many summaries it posted.
  """
  @spec finish_unfinished(binary()) :: {:ok, non_neg_integer()}
  def finish_unfinished(dm_space_id) when is_binary(dm_space_id) do
    since = DateTime.add(DateTime.utc_now(), -@unfinished_window_s, :second)

    posted =
      [dm_space_id]
      |> Chat.list_voice_records(since: since)
      |> Enum.group_by(& &1.metadata["voice_session_id"])
      |> Enum.reject(fn {_id, rows} -> Enum.any?(rows, &summary?/1) end)
      |> Enum.count(fn {id, _rows} ->
        match?({:ok, %Chat.Message{}}, finish(%{id: id, space_id: dm_space_id, started_at: nil}))
      end)

    {:ok, posted}
  end

  @doc """
  Open the agent's listening window: `AskFloor.claim/6` on key
  `"voice:" <> dm_space_id`, then the `:open` room-data signal. A repeat
  press by the identity already holding the floor is a no-op that returns
  the original holder and sends nothing.
  """
  @spec press(session(), map()) :: {:ok, AskFloor.holder()} | {:error, term()}
  def press(%{space_id: space_id, agent_id: agent_id}, user) do
    key = floor_key(space_id)
    identity = identity(user)

    case AskFloor.holder(key, agent_id) do
      {:ok, %{identity: ^identity} = holder} ->
        {:ok, holder}

      _ ->
        with {:ok, holder} <-
               AskFloor.claim(key, agent_id, identity, display_name(user), nil, space_id) do
          :ok = Meetings.ask_floor_window_signal(agent_id, space_id, :open)
          {:ok, holder}
        end
    end
  end

  @doc "Close the listening window opened by `press/2`; mirrors it with `:closed`."
  @spec release(session(), map()) :: :ok | {:error, term()}
  def release(%{space_id: space_id, agent_id: agent_id}, user) do
    with :ok <- AskFloor.release(floor_key(space_id), agent_id, identity(user)) do
      Meetings.ask_floor_window_signal(agent_id, space_id, :closed)
    end
  end

  @doc """
  Tell the live worker the conversation's context changed. Sends RELIABLE
  room data on `"mva.context"`: `{"kind": "space", "id", "name"}` or
  `{"kind": "none", "id": null, "name": null}`.

  `context` must already be resolved (a map with `:id`/`:name`, or nil);
  `start/3` and the caller's own membership check are where it is validated.
  """
  @spec set_context(session(), context()) :: :ok | {:error, term()}
  def set_context(%{room_name: room_name}, context) do
    payload = context |> context_payload() |> Jason.encode!()
    Meetings.send_livekit_room_data(room_name, @context_topic, payload)
  end

  @doc """
  Post the user's own transcribed turn into `context_space_id` as the USER's
  participant, with metadata `%{"source" => "voice"}` merged over
  `metadata` (`record_turn/5` passes the session tags). Refuses blank text
  (`{:error, :blank}`) and a space the user cannot write to
  (`{:error, :forbidden}`).
  """
  @spec post_transcript(map(), binary(), String.t() | nil, map()) ::
          {:ok, Chat.Message.t()} | {:error, :blank | :forbidden | term()}
  def post_transcript(user, context_space_id, text, metadata \\ %{}) do
    content = if is_binary(text), do: String.trim(text), else: ""

    if content == "" do
      {:error, :blank}
    else
      with {:ok, participant} <- SpaceAccess.authorize_writer(context_space_id, user) do
        Chat.post_message(%{
          space_id: context_space_id,
          participant_id: participant.id,
          content_type: "text",
          content: content,
          metadata: Map.put(metadata, "source", "voice")
        })
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp with_defaults(session) do
    session
    |> Map.put_new(:turns, 0)
    |> Map.put_new(:segments, MapSet.new())
    |> Map.put_new(:pointers, MapSet.new())
  end

  defp segment_id(id) when is_binary(id) and id != "" and byte_size(id) <= @max_segment_id,
    do: id

  defp segment_id(_), do: nil

  defp session_tag(session), do: %{"source" => "voice", "voice_session_id" => session.id}

  defp turn_metadata(session, turn, input) do
    session
    |> session_tag()
    |> Map.merge(%{
      "voice_turn" => turn,
      "input" => if(input == :typed, do: "typed", else: "voice")
    })
  end

  # A user turn with a context posts there only; a refused context post
  # (`:forbidden`) falls through to the DM so nothing is lost.
  defp write_turn(session, user, :me, content, meta, %{id: ctx_id} = context)
       when is_binary(ctx_id) do
    case post_transcript(user, ctx_id, content, meta) do
      {:ok, message} ->
        name = Map.get(context, :name)
        session = ensure_pointer(session, ctx_id, name)
        {:ok, message, name, session}

      {:error, _refused} ->
        write_turn(session, user, :me, content, meta, nil)
    end
  end

  defp write_turn(session, _user, :me, content, meta, _no_context) do
    with {:ok, message} <- post_dm(session, session.user_participant_id, "text", content, meta) do
      {:ok, message, nil, session}
    end
  end

  defp write_turn(session, _user, :agent, content, meta, _context) do
    with {:ok, message} <- post_dm(session, session.agent_participant_id, "text", content, meta) do
      {:ok, message, nil, session}
    end
  end

  # ONE pointer row per (session, context), posted the first time a turn
  # lands in that context. A failed pointer write is not retried here: the
  # turn itself is already in the context.
  defp ensure_pointer(session, ctx_id, name) do
    if MapSet.member?(session.pointers, ctx_id) do
      session
    else
      meta =
        session
        |> session_tag()
        |> Map.merge(%{
          "voice_kind" => "context_pointer",
          "context_space_id" => ctx_id,
          "context_name" => name
        })

      case post_dm(
             session,
             session.user_participant_id,
             "system",
             "Your side was posted to ##{name}",
             meta
           ) do
        {:ok, _pointer} -> %{session | pointers: MapSet.put(session.pointers, ctx_id)}
        {:error, _} -> session
      end
    end
  end

  # Every DM row moves the user's read cursor past itself before it is
  # broadcast (`Chat.post_message/2` `:mark_read_for`), so it never counts as
  # unread.
  defp post_dm(session, participant_id, content_type, content, metadata) do
    Chat.post_message(
      %{
        space_id: session.space_id,
        participant_id: participant_id,
        content_type: content_type,
        content: content,
        metadata: metadata
      },
      mark_read_for: session.user_participant_id
    )
  end

  defp summary?(%{metadata: %{"voice_kind" => "summary"}}), do: true
  defp summary?(_), do: false

  defp turn_row?(%{metadata: %{"voice_turn" => n}}) when is_integer(n), do: true
  defp turn_row?(_), do: false

  defp do_finish(%{id: id, space_id: space_id} = session) do
    dm_rows = Chat.list_voice_records([space_id], voice_session_id: id)

    if Enum.any?(dm_rows, &summary?/1) do
      {:ok, :already_finished}
    else
      context_ids =
        dm_rows
        |> Enum.flat_map(fn
          %{metadata: %{"voice_kind" => "context_pointer", "context_space_id" => c}}
          when is_binary(c) ->
            [c]

          _ ->
            []
        end)
        |> Enum.uniq()

      turns =
        (dm_rows ++ Chat.list_voice_records(context_ids, voice_session_id: id))
        |> Enum.filter(&turn_row?/1)
        |> Enum.sort_by(& &1.id)

      case turns do
        [] -> {:ok, :no_turns}
        _ -> post_summary(session, turns)
      end
    end
  end

  defp post_summary(session, [first | _] = turns) do
    with {:ok, session} <- resolve_participants(session) do
      started_at = Map.get(session, :started_at) || first.inserted_at
      last = List.last(turns)
      duration_ms = max(DateTime.diff(last.inserted_at, started_at, :millisecond), 0)
      n = length(turns)

      metadata =
        session
        |> session_tag()
        |> Map.merge(%{
          "voice_kind" => "summary",
          "turns" => n,
          "duration_ms" => duration_ms,
          "started_at" => DateTime.to_iso8601(started_at)
        })

      post_dm(
        session,
        session.agent_participant_id,
        "system",
        summary_content(n, duration_ms),
        metadata
      )
    end
  end

  @doc false
  def summary_content(turns, duration_ms) do
    "Voice chat · #{turns_label(turns)} · #{minutes_label(duration_ms)}"
  end

  @doc "`\"18 turns\"` / `\"1 turn\"`: the count as the summary row words it."
  @spec turns_label(non_neg_integer()) :: String.t()
  def turns_label(1), do: "1 turn"
  def turns_label(n) when is_integer(n), do: "#{n} turns"

  @doc "`\"12 min\"`: a duration as the summary row words it (rounded, at least 1)."
  @spec minutes_label(non_neg_integer()) :: String.t()
  def minutes_label(duration_ms) when is_integer(duration_ms) do
    "#{max(div(duration_ms + 30_000, 60_000), 1)} min"
  end

  # The `room_finished` fallback has only the DM: its one user and one agent
  # participant are the session's two sides.
  defp resolve_participants(%{user_participant_id: u, agent_participant_id: a} = session)
       when is_binary(u) and is_binary(a),
       do: {:ok, session}

  defp resolve_participants(%{space_id: space_id} = session) do
    participants = Chat.list_participants(space_id)
    user = Enum.find(participants, &(&1.participant_type == "user"))
    agent = Enum.find(participants, &(&1.participant_type == "agent"))

    if user && agent do
      {:ok,
       session
       |> Map.put(:user_participant_id, user.id)
       |> Map.put(:agent_participant_id, agent.id)}
    else
      {:error, :no_dm_participants}
    end
  end

  defp visible_agents(user), do: Chat.dm_agent_candidates(user, "")

  # A live call owns the room; see the moduledoc's shared-room rule. "Live"
  # means an "active" room with a human still in it: a hung-up call leaves the
  # room "active" until LiveKit's `room_finished`, and a session started in
  # that gap is a Voice tab session, not the call.
  defp stamp_session_mode(%Room{status: "active"} = room) do
    if human_in_room?(room), do: {:ok, room}, else: Meetings.set_session_mode(room, @mode)
  end

  defp stamp_session_mode(%Room{} = room), do: Meetings.set_session_mode(room, @mode)

  defp floor_key(space_id), do: "voice:" <> space_id

  defp identity(%{id: id}), do: "user:" <> id

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}) when is_binary(email), do: email
  defp display_name(_), do: "User"

  # A live row for this agent (the worker published, so the row carries the
  # LiveKit identity `upsert_live_participant/2` stamps) means the agent is
  # already in the room: do not dispatch a second worker into it.
  defp ensure_agent_dispatched(room, agent, user, voice_context) do
    if agent_live_in_room?(room, agent) do
      :ok
    else
      case Meetings.invite_agent(room, agent, user, mode: @mode, voice_context: voice_context) do
        {:ok, _participant} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp human_in_room?(room) do
    room.id
    |> Meetings.active_participants()
    |> Enum.any?(&is_binary(&1.user_id))
  end

  defp agent_live_in_room?(room, agent) do
    room.id
    |> Meetings.active_participants()
    |> Enum.any?(fn
      %Participant{agent_id: agent_id, metadata: %{"identity" => identity}}
      when is_binary(identity) ->
        agent_id == agent.id

      _ ->
        false
    end)
  end

  defp normalize_context(_user, context) when context in [nil, :none], do: {:ok, nil}

  defp normalize_context(user, %{id: space_id} = context) when is_binary(space_id) do
    case SpaceAccess.authorize_writer(space_id, user) do
      {:ok, _participant} ->
        {:ok, %{"kind" => "space", "id" => space_id, "name" => Map.get(context, :name)}}

      {:error, :forbidden} = error ->
        error
    end
  end

  defp normalize_context(_user, _context), do: {:error, :invalid_context}

  defp context_payload(%{id: id} = context) when is_binary(id),
    do: %{"kind" => "space", "id" => id, "name" => Map.get(context, :name)}

  defp context_payload(_none), do: %{"kind" => "none", "id" => nil, "name" => nil}
end
