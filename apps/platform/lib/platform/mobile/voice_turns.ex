defmodule Platform.Mobile.VoiceTurns do
  @moduledoc """
  The native Voice turn (task 01a21e75 stage 2): what a Voice control,
  Action button or widget on the iPhone needs when it starts a turn with NO
  web view, so no `/voice` LiveView is there to send the turn or hear the
  reply.

  Composes `Platform.Meetings.OnDeviceVoice`'s public functions only, so the
  native path and the Voice tab post and read exactly the same messages: a
  turn is a plain DM message tagged `metadata.input = "on_device"` with the
  device's `client_turn_id`, and the reply is the agent's next message in
  that DM (or its `{:agent_reply_chunk, _}` stream).

    * `last_partner/1`: the agent of the user's newest on-device turn, still
      active and still one the user may DM (`Chat.dm_agent_candidates/3`).
      The app compares `last_used_at` across installs.
    * `send_turn/4`: idempotent on `client_turn_id` (a retry posts nothing).
    * `await_reply/4`: a long-poll, at most #{25_000} ms, that returns the
      sentences not yet spoken. Only the caller's OWN turn resolves. While
      it waits, the caller is tracked as a Voice listener in the DM
      (`Platform.Chat.Presence`, meta `Presence.voice_listener_meta/0`), so the reply the
      device shows in its Live Activity is not pushed on top of it (the
      push rule of task 01a21e8d).

  Nothing here logs. The turn text and the reply are message text: they are
  stored as the DM message and returned to the person's own device only.
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, Presence, Space}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings.OnDeviceVoice
  alias Platform.Repo

  @max_wait_ms 25_000

  @type reply :: %{
          state: String.t(),
          sentences: [String.t()],
          spoken: non_neg_integer(),
          final: boolean()
        }

  @doc "The longest `await_reply/4` waits, in milliseconds."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  # ── partner ────────────────────────────────────────────────────────────

  @doc """
  The agent of `user`'s most recent on-device turn, as
  `%{agent_id, name, last_used_at}`, or nil. Turns whose agent is no longer
  active or no longer DM-able are skipped, so an older partner can answer.
  """
  @spec last_partner(map()) ::
          %{agent_id: binary(), name: String.t(), last_used_at: DateTime.t()} | nil
  def last_partner(%{id: user_id} = user) do
    from(m in Message,
      join: me in Participant,
      on: me.id == m.participant_id,
      join: s in Space,
      on: s.id == m.space_id,
      join: ap in Participant,
      on: ap.space_id == s.id and ap.participant_type == "agent",
      join: a in Agent,
      on: a.id == ap.participant_id,
      where: me.participant_type == "user" and me.participant_id == ^user_id,
      where: s.kind == "dm" and is_nil(s.archived_at),
      where: is_nil(m.deleted_at),
      where: fragment("? @> ?::jsonb", m.metadata, ^%{"input" => "on_device"}),
      where: a.status == "active",
      group_by: [a.id, a.name],
      order_by: [desc: max(m.inserted_at)],
      select: %{agent_id: a.id, name: a.name, last_used_at: max(m.inserted_at)}
    )
    |> Repo.all()
    |> Enum.find(&dm_able?(user, &1.agent_id))
  end

  defp dm_able?(user, agent_id),
    do: Chat.dm_agent_candidates(user, nil, ids: [agent_id]) != []

  # ── send ───────────────────────────────────────────────────────────────

  @doc """
  Sends one turn as `user` to `agent_id`: opens the DM
  (`OnDeviceVoice.open/2`), and posts the words unless a turn with this
  `client_turn_id` is already there (`find_turn/2`), in which case nothing
  is posted. Returns the DM's id and path segment.

  Errors: `:blank` (no words), `:invalid` (no `client_turn_id`),
  `:not_found` (no such agent), `:forbidden` (not one the user may DM).
  """
  @spec send_turn(map(), term(), term(), term()) ::
          {:ok, %{space_id: binary(), path_segment: String.t(), message_id: binary()}}
          | {:error, :blank | :invalid | :not_found | :forbidden}
  def send_turn(user, agent_id, text, client_turn_id) do
    with :ok <- check_text(text),
         :ok <- check_turn_id(client_turn_id),
         {:ok, agent} <- fetch_agent(agent_id),
         :ok <- if(dm_able?(user, agent.id), do: :ok, else: {:error, :forbidden}),
         {:ok, conn} <- open(user, agent),
         {:ok, message} <- post_once(conn, text, client_turn_id) do
      space = Repo.get!(Space, conn.space_id)

      {:ok,
       %{
         space_id: space.id,
         path_segment: Chat.space_path_segment(space),
         message_id: message.id
       }}
    end
  end

  defp check_text(text) when is_binary(text),
    do: if(String.trim(text) == "", do: {:error, :blank}, else: :ok)

  defp check_text(_text), do: {:error, :blank}

  defp check_turn_id(id) when is_binary(id) and byte_size(id) in 1..128, do: :ok
  defp check_turn_id(_id), do: {:error, :invalid}

  defp fetch_agent(id) when is_binary(id) do
    with {:ok, uuid} <- Platform.UUID.cast(id),
         %Agent{} = agent <- Repo.get(Agent, uuid) do
      {:ok, agent}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_agent(_id), do: {:error, :not_found}

  defp open(user, agent) do
    case OnDeviceVoice.open(user, agent) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp post_once(conn, text, client_turn_id) do
    case OnDeviceVoice.find_turn(conn, client_turn_id) do
      %Message{} = message ->
        _conn = OnDeviceVoice.mark_turn(conn, message)
        {:ok, message}

      nil ->
        case OnDeviceVoice.send_turn(conn, text, client_turn_id) do
          {:ok, _conn, message} -> {:ok, message}
          {:error, :blank} -> {:error, :blank}
          {:error, _reason} -> {:error, :forbidden}
        end
    end
  end

  # ── reply ──────────────────────────────────────────────────────────────

  @doc """
  Waits up to `timeout_ms` (capped at #{@max_wait_ms}) for the reply to
  `user`'s turn `client_turn_id`, past the `spoken` sentences the device has
  already spoken.

    * The posted reply (`OnDeviceVoice.agent_reply?/2`) gives
      `state: "done", final: true` and the sentences after `spoken`.
    * A streamed chunk (`agent_chunk?/2`) that completes new sentences gives
      `state: "speaking", final: false`.
    * Nothing in time gives `state: "thinking"` (or `"speaking"` once some
      sentences were spoken) and `[]`.

  Only the caller's own turn resolves: another user's `client_turn_id` is
  `{:error, :not_found}`. The DM topic subscription is dropped, and any
  frames it delivered are flushed, on every exit.
  """
  @spec await_reply(map(), term(), term(), term()) :: {:ok, reply()} | {:error, :not_found}
  def await_reply(user, client_turn_id, spoken, timeout_ms) do
    spoken = if is_integer(spoken) and spoken >= 0, do: spoken, else: 0
    timeout_ms = if is_integer(timeout_ms), do: timeout_ms |> max(0) |> min(@max_wait_ms), else: 0

    with :ok <- check_turn_id(client_turn_id),
         %Message{} = turn <- own_turn(user, client_turn_id),
         {:ok, conn} <- reopen(user, turn) do
      {:ok, as_voice_listener(conn.space_id, user.id, fn -> wait(conn, spoken, timeout_ms) end)}
    else
      _ -> {:error, :not_found}
    end
  end

  # The caller's own on-device turn with this id, in any of their DMs.
  defp own_turn(%{id: user_id}, client_turn_id) do
    from(m in Message,
      join: me in Participant,
      on: me.id == m.participant_id,
      where: me.participant_type == "user" and me.participant_id == ^user_id,
      where:
        fragment(
          "? @> ?::jsonb",
          m.metadata,
          ^%{"input" => "on_device", "client_turn_id" => client_turn_id}
        ),
      order_by: [asc: m.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  # Only the caller's own DM is re-opened: the turn's space must be a DM the
  # caller already participates in, checked BEFORE `OnDeviceVoice.open/2`,
  # whose `find_or_create_dm` would otherwise create a DM for a caller who is
  # not in it. A refused turn creates nothing.
  defp reopen(%{id: user_id} = user, %Message{space_id: space_id} = turn) do
    member? =
      Repo.exists?(
        from(p in Participant,
          join: s in Space,
          on: s.id == p.space_id,
          where: p.space_id == ^space_id and s.kind == "dm",
          where: p.participant_type == "user" and p.participant_id == ^user_id
        )
      )

    agent =
      if member?,
        do:
          from(a in Agent,
            join: p in Participant,
            on: p.participant_id == a.id and p.participant_type == "agent",
            where: p.space_id == ^space_id,
            limit: 1
          )
          |> Repo.one()

    with %Agent{} <- agent,
         {:ok, conn} <- OnDeviceVoice.open(user, agent),
         true <- conn.space_id == space_id do
      {:ok, OnDeviceVoice.mark_turn(conn, turn)}
    else
      _ -> {:error, :not_found}
    end
  end

  # While the device waits for the reply it is a Voice listener in the DM,
  # exactly as the Voice page is: tracked in `Platform.Chat.Presence` with
  # `%{participant_type: "user", surface: "voice"}`, so the reply it is about
  # to show in the Live Activity is not also pushed (task 01a21e8d's rule).
  # Tracked on THIS process, so a dropped connection clears the entry with
  # the process; untracked on every exit. A tracker that cannot be reached
  # fails open: the wait goes on and the reply may also be pushed.
  defp as_voice_listener(space_id, user_id, fun) do
    tracked? =
      match?(
        {:ok, _},
        Presence.safe_track_in_space(self(), space_id, user_id, Presence.voice_listener_meta())
      )

    try do
      fun.()
    after
      if tracked?, do: Presence.safe_untrack_in_space(self(), space_id, user_id)
    end
  end

  defp wait(conn, spoken, timeout_ms) do
    case posted_reply(conn) do
      %Message{} = reply ->
        done(reply, spoken)

      nil ->
        :ok = ChatPubSub.subscribe(conn.space_id)

        try do
          # Re-check: the reply may have been posted between the read and
          # the subscription.
          case posted_reply(conn) do
            %Message{} = reply -> done(reply, spoken)
            nil -> receive_reply(conn, spoken, deadline(timeout_ms))
          end
        after
          ChatPubSub.unsubscribe(conn.space_id)
          flush(conn.space_id)
        end
    end
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp receive_reply(conn, spoken, deadline) do
    receive do
      {:new_message, %{} = message} ->
        if OnDeviceVoice.agent_reply?(conn, message),
          do: done(message, spoken),
          else: receive_reply(conn, spoken, deadline)

      {:agent_reply_chunk, %{} = chunk} ->
        with true <- OnDeviceVoice.agent_chunk?(conn, chunk),
             {[_ | _] = sentences, count} <-
               OnDeviceVoice.speakable_sentences(spoken, chunk.text, false) do
          %{state: "speaking", sentences: sentences, spoken: count, final: false}
        else
          _ -> receive_reply(conn, spoken, deadline)
        end
    after
      remaining(deadline) ->
        state = if spoken == 0, do: "thinking", else: "speaking"
        %{state: state, sentences: [], spoken: spoken, final: false}
    end
  end

  defp done(%Message{content: content}, spoken) do
    {sentences, count} = OnDeviceVoice.speakable_sentences(spoken, content, true)
    %{state: "done", sentences: sentences, spoken: count, final: true}
  end

  # The agent's first posted message at or after the turn.
  defp posted_reply(conn) do
    from(m in Message,
      where: m.space_id == ^conn.space_id and m.participant_id == ^conn.agent_participant_id,
      where: m.inserted_at >= ^conn.turn_at and is_nil(m.deleted_at),
      order_by: [asc: m.inserted_at, asc: m.id],
      limit: 10
    )
    |> Repo.all()
    |> Enum.find(&OnDeviceVoice.agent_reply?(conn, &1))
  end

  # Frames already delivered for this space before the unsubscribe; a
  # keep-alive connection's next request may run in this same process.
  defp flush(space_id), do: flush(space_id, ChatPubSub.space_topic(space_id))

  defp flush(space_id, topic) do
    receive do
      {:new_message, %{space_id: ^space_id}} -> flush(space_id, topic)
      {:agent_reply_chunk, %{space_id: ^space_id}} -> flush(space_id, topic)
      %Phoenix.Socket.Broadcast{topic: ^topic} -> flush(space_id, topic)
    after
      0 -> :ok
    end
  end
end
