defmodule PlatformWeb.ChatLive.MessageAttentionHooks do
  @moduledoc """
  Lifecycle hook module for "Get someone's attention" (redesign rung 12,
  task 01a1557a-a30a stage 2): a member asks agents or people to look at an
  already-sent message without editing it. The server side is
  `Platform.Chat.add_message_attention/4` (stage 1).

  Attached by `PlatformWeb.ChatLive.MessageActionsHooks.attach/1`, so it
  runs from `ChatLive.mount/3` without a line in `chat_live.ex` (its code
  lines are ratcheted).

  ## Assigns owned

    * `:open_message_attention` — nil when the picker is closed, else
      `%{message_id, own?, title, preview, query, suggestions, added}` for
      `Partials.Overlays.message_attention_sheet/1` (the phone sheet and the
      desktop popover, from this ONE assign).

  ## Events

    * `open_message_attention` {message-id} — from the sheet row, the tap
      pill's +@ and the "+@ add someone" button. The message must be live
      and in the active space.
    * `close_message_attention`
    * `attention_query` {query} — the picker's own search field. It re-runs
      rung 10's `MentionsHooks.build_suggestions/3`.
    * `add_message_attention` {message-id, ids} — calls ONLY
      `Chat.add_message_attention({:user, user_id}, active_space.id, …)`.
      The space id is the socket's, never a param, and the writer authorizes
      the actor, so a forged id from another space or a non-member's socket
      is refused and nothing renders. Added: the toast "@<Name> notified".
      A refused summon reuses the mention path's refused-summon notice.

    * `decline_attention_prefill` — "Not <Name>" on the learned pre-fill
      (task 01a1b6a1 stage 3): records `overridden` at rung `prefill` and
      clears the pre-fill.
    * `undo_learned_action` {message-id} — the notice's Undo on an ask the
      habits engine made: `Platform.Habits.LearnedAttention.undo/3`.
    * `toggle_attention_why` {principal-id} — the learned row's reason
      line opens (or closes) its "Why this?" line (stage 4): `:why` on the
      assign holds the principal id whose line is open.
    * `stop_learned_action` {message-id} — the notice's stop control:
      `Platform.Habits.LearnedAttention.stop/3`, which drops the pattern to
      rank for this space.

  ## Learned defaults (task 01a1b6a1 stage 3, `0061-learned-defaults.md`)

  `open/3` asks `Platform.Habits.suggest/3` once per opened message. The
  suggestions are re-ordered by its `ranked` (learned rows first, marked
  `learned: true, reason: {:usually, display_name}`), and its `prefill` (nil
  below threshold, or when that person is already asked) is kept on the
  assign as the suggestion row. Every pick, the decline and a close after a
  pre-fill record a signal (`Platform.Habits.record/1`, never failing the
  event): the pre-filled target picked = `accepted` at `prefill`; someone
  else picked while a pre-fill or learned rank was shown = `overridden` for
  the shown target plus `chosen` for the pick, at the rung shown, but only
  at rung `prefill` or `act` (at `rank` a pick rejects nothing and is just
  `chosen`); closing
  with the pre-fill still up = `ignored`; a pick with nothing learned =
  `chosen` at `none`.

  ## Info

    * `{:message_attention_changed, msg}` — broadcast by the writer on the
      space topic to every viewer (the actor included). The row is
      reinserted through `MessagesHooks.reinsert_stream_message/2`, which
      re-reads the attention, so each viewer renders its own copy of the
      added line. An open picker on that message refreshes its "added".
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Habits
  alias Platform.Habits.Capture
  alias Platform.Habits.LearnedAttention
  alias PlatformWeb.ChatLive.MentionsHooks
  alias PlatformWeb.ChatLive.MessagesHooks

  # The rungs at which picking someone else overrides the shown suggestion.
  @override_rungs ~w(prefill act)

  @doc "Attach the attention handlers. Called from `MessageActionsHooks.attach/1`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:open_message_attention, nil)
    |> attach_hook(:message_attention_events, :handle_event, &handle_event/3)
    |> attach_hook(:message_attention_info, :handle_info, &handle_info/2)
  end

  defp handle_event("open_message_attention", %{"message-id" => msg_id}, socket)
       when is_binary(msg_id) do
    case active_space_message(socket, msg_id) do
      %Message{} = msg -> {:halt, open(socket, msg, "")}
      nil -> {:halt, assign(socket, :open_message_attention, nil)}
    end
  end

  defp handle_event("open_message_attention", _params, socket), do: {:halt, socket}

  defp handle_event("close_message_attention", _params, socket) do
    record_ignored(socket, socket.assigns[:open_message_attention])
    {:halt, assign(socket, :open_message_attention, nil)}
  end

  defp handle_event("decline_attention_prefill", _params, socket) do
    case socket.assigns[:open_message_attention] do
      %{prefill: %{} = prefill} = state ->
        record_signal(socket, target(prefill), "overridden", "prefill")

        {:halt,
         assign(socket, :open_message_attention, %{
           state
           | prefill: nil,
             shown: nil,
             rung: if(state.learned_rows?, do: "rank", else: "none")
         })}

      _ ->
        {:halt, socket}
    end
  end

  # "Why this?" under a learned row's reason line (stage 4): toggles which
  # row's one-line why is open. Never a pick.
  defp handle_event("toggle_attention_why", %{"principal-id" => pid}, socket)
       when is_binary(pid) do
    case socket.assigns[:open_message_attention] do
      %{} = state ->
        why = if state[:why] == pid, do: nil, else: pid
        {:halt, assign(socket, :open_message_attention, Map.put(state, :why, why))}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event("toggle_attention_why", _params, socket), do: {:halt, socket}

  defp handle_event("undo_learned_action", %{"message-id" => msg_id}, socket)
       when is_binary(msg_id) do
    with %{id: space_id} <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id] do
      _ = LearnedAttention.undo(user_id, space_id, msg_id)
    end

    {:halt, socket}
  end

  defp handle_event("undo_learned_action", _params, socket), do: {:halt, socket}

  defp handle_event("stop_learned_action", %{"message-id" => msg_id}, socket)
       when is_binary(msg_id) do
    with %{id: space_id} <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id] do
      _ = LearnedAttention.stop(user_id, space_id, msg_id)
    end

    {:halt, socket}
  end

  defp handle_event("stop_learned_action", _params, socket), do: {:halt, socket}

  defp handle_event("attention_query", %{"query" => query}, socket) when is_binary(query) do
    with %{message_id: msg_id} <- socket.assigns[:open_message_attention],
         %Message{} = msg <- active_space_message(socket, msg_id) do
      {:halt, open(socket, msg, query)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("attention_query", _params, socket), do: {:halt, socket}

  defp handle_event("add_message_attention", %{"message-id" => msg_id, "ids" => ids}, socket)
       when is_binary(msg_id) and is_list(ids) do
    with %{id: space_id} <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id],
         {:ok, result} <-
           Chat.add_message_attention({:user, user_id}, space_id, msg_id, ids) do
      record_pick(socket, socket.assigns[:open_message_attention], ids)
      {:halt, socket |> assign(:open_message_attention, nil) |> report(msg_id, result)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("add_message_attention", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:message_attention_changed, %Message{} = msg}, socket) do
    case socket.assigns[:active_space] do
      %{id: space_id} when space_id == msg.space_id ->
        rendered = socket.assigns[:rendered_message_ids] || MapSet.new()

        socket =
          if MapSet.member?(rendered, msg.id),
            do: MessagesHooks.reinsert_stream_message(socket, msg.id),
            else: socket

        {:halt, refresh_open(socket, msg)}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Picker state ──────────────────────────────────────────────────────

  defp open(socket, %Message{} = msg, query) do
    viewer = socket.assigns[:current_participant]
    own? = viewer != nil and msg.participant_id == viewer.id
    previous = same_message_state(socket, msg.id)
    learned = (previous && previous.learned) || learned(socket)
    added = added_principals(socket, msg.id)
    suggestions = suggestions(socket, msg, query, learned)
    learned_rows? = Enum.any?(suggestions(socket, msg, "", learned), &(&1[:learned] == true))

    prefill =
      if previous,
        do: previous.prefill,
        else: prefill_row(socket, msg, learned)

    # A pre-fill for someone already asked is no pre-fill.
    prefill = if prefill && MapSet.member?(added, prefill.principal_id), do: nil, else: prefill

    {shown, rung} =
      cond do
        previous && is_nil(previous.prefill) -> {previous.shown, previous.rung}
        prefill -> {target(prefill), "prefill"}
        learned_rows? -> {top_learned(socket, msg, learned), "rank"}
        true -> {nil, "none"}
      end

    assign(socket, :open_message_attention, %{
      message_id: msg.id,
      own?: own?,
      title: if(own?, do: "Get someone's attention", else: "Ask someone to look"),
      preview: preview(msg, socket),
      query: query,
      suggestions: suggestions,
      added: added,
      prefill: prefill,
      learned: learned,
      learned_rows?: learned_rows?,
      shown: shown,
      rung: rung,
      why: previous && previous[:why]
    })
  end

  defp same_message_state(socket, msg_id) do
    case socket.assigns[:open_message_attention] do
      %{message_id: ^msg_id, learned: %{}} = state -> state
      _ -> nil
    end
  end

  # `Platform.Habits.suggest/3` for the viewer in the active space. Never
  # fails the open: any error is "nothing learned".
  defp learned(socket) do
    with %{id: space_id} <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id] do
      Habits.suggest(user_id, space_id, LearnedAttention.action())
    else
      _ -> %{ranked: [], prefill: nil, act: nil}
    end
  rescue
    _ -> %{ranked: [], prefill: nil, act: nil}
  end

  defp prefill_row(socket, msg, %{prefill: %{} = prefill}) do
    socket
    |> suggestions(msg, "", %{ranked: [], prefill: nil})
    |> Enum.find(&(key(&1) == {prefill.target_type, prefill.target_id}))
  end

  defp prefill_row(_socket, _msg, _learned), do: nil

  defp top_learned(socket, msg, learned) do
    case suggestions(socket, msg, "", learned) do
      [%{learned: true} = row | _] -> target(row)
      _ -> nil
    end
  end

  defp refresh_open(socket, %Message{id: id} = msg) do
    case socket.assigns[:open_message_attention] do
      %{message_id: ^id, query: query} -> open(socket, msg, query)
      _ -> socket
    end
  end

  @doc """
  The picker's rows: rung 10's suggestions for `query`, minus the `@here`
  sentinel, the message's author and the viewer (none of them can be asked
  to look; the writer drops them too).
  """
  @spec suggestions(Phoenix.LiveView.Socket.t(), Message.t(), String.t()) :: [map()]
  def suggestions(socket, %Message{} = msg, query),
    do: suggestions(socket, msg, query, learned(socket))

  @doc """
  `suggestions/3` re-ordered by a `Platform.Habits.suggest/3` result: the
  rows whose principal is in `ranked` come first, in rank order, each marked
  `learned: true, reason: {:usually, display_name}`; the rest keep rung 10's
  order after them. With a query the ranking applies within the matches.
  """
  @spec suggestions(Phoenix.LiveView.Socket.t(), Message.t(), String.t(), map()) :: [map()]
  def suggestions(socket, %Message{} = msg, query, learned) do
    socket
    |> base_suggestions(msg, query)
    |> apply_learned(Map.get(learned, :ranked, []))
  end

  defp apply_learned(rows, []), do: rows

  defp apply_learned(rows, ranked) do
    index =
      ranked
      |> Enum.with_index()
      |> Map.new(fn {r, i} -> {{r.target_type, r.target_id}, i} end)

    {learned, rest} = Enum.split_with(rows, &Map.has_key?(index, key(&1)))

    learned =
      learned
      |> Enum.sort_by(&Map.fetch!(index, key(&1)))
      |> Enum.map(&Map.merge(&1, %{learned: true, reason: {:usually, &1[:display_name]}}))

    learned ++ rest
  end

  defp key(row), do: {row[:participant_type], row[:principal_id]}

  defp target(row), do: %{target_type: row[:participant_type], target_id: row[:principal_id]}

  defp base_suggestions(socket, %Message{} = msg, query) do
    participants = socket.assigns[:participants_map] || %{}
    excluded = excluded_principals(participants, msg, socket)

    query
    |> MentionsHooks.build_suggestions(participants,
      external?: socket.assigns[:external?] == true,
      user_id: socket.assigns[:user_id],
      addable_agents: socket.assigns[:mention_addable_agents] || []
    )
    |> Enum.reject(fn s ->
      s[:participant_type] == "broadcast" or MapSet.member?(excluded, s[:principal_id])
    end)
  end

  defp excluded_principals(participants, %Message{} = msg, socket) do
    author = participants |> Map.get(msg.participant_id, %{}) |> Map.get(:principal_id)
    [author, socket.assigns[:user_id]] |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  # Principal ids already asked to look at the message, for the "added"
  # marks. Attention rows name chat participants; the picker's rows name
  # principals, so map through `@participants_map`.
  defp added_principals(socket, msg_id) do
    participants = socket.assigns[:participants_map] || %{}

    msg_id
    |> Chat.list_message_attention()
    |> Enum.flat_map(fn a ->
      case Map.get(participants, a.participant_id) do
        %{principal_id: pid} when is_binary(pid) -> [pid]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  # The masters' one-line preview (mobile 1387): the text, else "<n>
  # image(s)", else "message".
  defp preview(%Message{content: content} = msg, socket) do
    case content && String.trim(content) do
      text when is_binary(text) and text != "" ->
        text

      _ ->
        case image_count(msg, socket) do
          0 -> "message"
          1 -> "1 image"
          n -> "#{n} images"
        end
    end
  end

  defp image_count(%Message{id: id}, socket) do
    socket.assigns
    |> Map.get(:attachments_map, %{})
    |> Map.get(id, [])
    |> Enum.count(fn a -> String.starts_with?(to_string(Map.get(a, :content_type)), "image/") end)
  end

  # ── Learned-default signals ───────────────────────────────────────────

  defp record_pick(socket, state, ids) do
    state = state || %{prefill: nil, shown: nil, rung: "none", suggestions: []}
    picked = ids |> Enum.uniq() |> Enum.flat_map(&pick_target(socket, state, &1))
    picked_keys = MapSet.new(picked, &{&1.target_type, &1.target_id})
    prefill = state.prefill && target(state.prefill)

    Enum.each(picked, fn t ->
      if t == prefill,
        do: record_signal(socket, t, "accepted", "prefill"),
        else: record_signal(socket, t, "chosen", state.rung)
    end)

    # An override rejects a suggestion that was acted on: the rung 2
    # pre-fill or the rung 3 automatic ask. At rung 1 (`rank`) the learned
    # person was only sorted first, so picking someone else rejects nothing
    # and records only the pick (architect ruling on task 01a1b6a1 case 7002).
    with true <- state.rung in @override_rungs,
         %{target_type: type, target_id: id} = shown <- state.shown,
         false <- MapSet.member?(picked_keys, {type, id}) do
      record_signal(socket, shown, "overridden", state.rung)
    end

    :ok
  end

  # A picked principal id -> its target, from the rows shown, else the
  # space's participants.
  defp pick_target(socket, state, id) when is_binary(id) do
    row =
      Enum.find(state.suggestions || [], &(&1[:principal_id] == id)) ||
        (socket.assigns[:participants_map] || %{})
        |> Map.values()
        |> Enum.find(&(&1[:principal_id] == id))

    case row do
      %{participant_type: type} when type in ["user", "agent"] -> [target(row)]
      _ -> []
    end
  end

  defp pick_target(_socket, _state, _id), do: []

  defp record_ignored(socket, %{prefill: %{} = prefill}),
    do: record_signal(socket, target(prefill), "ignored", "prefill")

  defp record_ignored(_socket, _state), do: :ok

  defp record_signal(socket, %{target_type: type, target_id: id}, outcome, rung) do
    with %{id: space_id} <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id] do
      Capture.record(%{
        actor_user_id: user_id,
        space_id: space_id,
        action: LearnedAttention.action(),
        target_type: type,
        target_id: id,
        outcome: outcome,
        rung: rung,
        source_message_id: get_in(socket.assigns, [:open_message_attention, :message_id])
      })
    end

    :ok
  end

  # ── After a pick ──────────────────────────────────────────────────────

  defp report(socket, msg_id, %{added: added, refused: refused}) do
    socket
    |> toast_added(added)
    |> notify_refused(msg_id, refused)
  end

  defp toast_added(socket, []), do: socket

  defp toast_added(socket, added) do
    names = added |> Enum.map(&"@#{&1.display_name}") |> Enum.join(", ")
    put_flash(socket, :info, "#{names} notified")
  end

  # A refused summon reads exactly as a refused @mention does: the same
  # `{:mention_summon_refused, msg_id, names}` the post path sends its
  # author, handled (and rendered under the message) by `MessagesHooks`.
  defp notify_refused(socket, _msg_id, []), do: socket

  defp notify_refused(socket, msg_id, agents) do
    send(self(), {:mention_summon_refused, msg_id, Enum.map(agents, &(&1.name || &1.slug))})
    socket
  end

  defp active_space_message(socket, msg_id) do
    with %{id: space_id} <- socket.assigns[:active_space],
         %Message{deleted_at: nil, space_id: ^space_id} = msg <-
           Chat.get_message(msg_id, scope: socket.assigns[:external_scope]) do
      msg
    else
      _ -> nil
    end
  end
end
