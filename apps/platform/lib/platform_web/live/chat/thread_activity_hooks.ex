defmodule PlatformWeb.ChatLive.ThreadActivityHooks do
  @moduledoc """
  The main log's "↳ N new replies to …" rows (task 01a174f5 stage 2, design
  canvas 01a175ca): which threads show a row at the bottom of the log, and
  keeping them live. Attached by `PlatformWeb.ChatLive.MessagesHooks.attach/1`
  BEFORE that module's own `:messages_info` handler (which halts every
  `{:new_message, _}`), so it runs from `ChatLive.mount/3` without a line in
  the ratcheted `chat_live.ex`.

  ## A footer region, not a moved stream row

  The rows are their own stream, `:thread_activity_rows`, rendered by
  `Partials.Composer.message_scroller/1` BELOW `#message-list`. Nothing here
  ever inserts into, moves or deletes from `:messages`: that stream's day
  labels, `:reply_quote_last_id`, `:rendered_message_ids` and prune/evict
  bookkeeping all assume its items are messages in log order.

  The stream holds at most 3 rows and is re-streamed with `reset: true`
  on every change; the threads above that cap collapse into one summary
  driven by the integer `:thread_activity_overflow`.

  ## Where the state comes from

  Everything is derived on the server from stage 1's per-thread cursor
  (`Platform.Chat.ThreadActivity`): `Chat.thread_activity_for/2` when a
  message window loads, `Chat.thread_activity_entry/3` for one thread when
  something about it changes. Nothing is kept client-side.

  ## Removed on open

  Every path that opens a thread inline ends in
  `MessagesHooks.expand_inline_thread/3` or `MessagesHooks.open_thread_context/3`,
  and both call `thread_opened/3`: the cursor moves to the newest reply at
  open time and the row goes. A reply that arrives while the parent's thread
  is EXPANDED in this LiveView counts as seen (the cursor advances and no row
  shows). Collapsing does nothing; the next reply brings the row back at the
  bottom with a fresh count.

  Another device of the same viewer opening the thread reaches this one as
  `{:thread_read, _}` on `Platform.Chat.PubSub.thread_reads_topic/1`, which
  this module subscribes for the current participant on every window load.

  ## Assigns owned

    * `:thread_activity_entries` — `[Chat.ThreadActivity.entry()]`, oldest
      first (newest last), at most 50;
    * `:thread_activity_rows` (stream) — the newest 3 entries whose parent
      resolves as `:visible` for this viewer, as row maps;
    * `:thread_activity_overflow` — how many more visible entries there are;
    * `:thread_activity_participant_id` — whose thread-reads topic is
      subscribed.

  ## Info handled

    * `{:new_message, reply}` (a thread reply in the active space from
      someone else) — bump or insert that thread's entry at the end, or mark
      it read when its parent is expanded. Always `{:cont, socket}`.
    * `{:thread_read, %{thread_id: t}}` — recompute `t`. Halted: it is this
      module's message.
    * `{:message_deleted, msg}` — recompute the reply's thread, or drop the
      entry whose parent was deleted. Always `{:cont, socket}`.

  Every other message passes through with `{:cont, socket}`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, stream: 4]

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.QuotedMessage

  @row_cap 3
  @entry_cap 50

  @doc "The most rows shown before the rest collapse into the summary."
  @spec row_cap() :: pos_integer()
  def row_cap, do: @row_cap

  @doc "Attach the thread-activity state and handler. Called from `MessagesHooks.attach/1`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:thread_activity_entries, [])
    |> assign(:thread_activity_overflow, 0)
    |> assign(:thread_activity_participant_id, nil)
    |> stream(:thread_activity_rows, [], reset: true)
    |> attach_hook(:thread_activity_info, :handle_info, &handle_info/2)
  end

  @doc """
  Load the viewer's active threads for the space just entered, and point the
  `{:thread_read, _}` subscription at the current participant. Called from
  `MessagesHooks`' window load.
  """
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    participant = socket.assigns[:current_participant]
    socket = resubscribe(socket, participant)

    entries =
      case participant do
        %Participant{} = p -> Chat.thread_activity_for(p, scope: socket.assigns[:access_scope])
        _ -> []
      end

    socket
    |> assign(:thread_activity_entries, entries)
    |> render_rows()
  end

  @doc """
  The thread `thread_id` was opened inline in this LiveView, showing replies
  up to `latest_reply_id` (nil when it has none): advance the cursor there
  and drop its row.
  """
  @spec thread_opened(Phoenix.LiveView.Socket.t(), binary() | nil, binary() | nil) ::
          Phoenix.LiveView.Socket.t()
  def thread_opened(socket, nil, _latest_reply_id), do: socket

  def thread_opened(socket, thread_id, latest_reply_id) do
    case {socket.assigns[:current_participant], latest_reply_id} do
      {%Participant{id: participant_id}, reply_id} when is_binary(reply_id) ->
        Chat.mark_thread_read(participant_id, thread_id, reply_id)

      _ ->
        :ok
    end

    drop(socket, thread_id)
  end

  # ── Info ───────────────────────────────────────────────────────────

  defp handle_info({:new_message, %{thread_id: thread_id} = msg}, socket)
       when is_binary(thread_id) do
    case socket.assigns[:current_participant] do
      %Participant{id: viewer_id} = viewer ->
        if msg.participant_id != viewer_id and active_space?(socket, msg.space_id),
          do: {:cont, on_reply(socket, viewer, thread_id)},
          else: {:cont, socket}

      _ ->
        {:cont, socket}
    end
  end

  defp handle_info({:thread_read, %{participant_id: pid, thread_id: thread_id}}, socket) do
    if socket.assigns[:thread_activity_participant_id] == pid,
      do: {:halt, recompute(socket, thread_id)},
      else: {:halt, socket}
  end

  defp handle_info({:message_deleted, %{space_id: space_id} = msg}, socket) do
    cond do
      not active_space?(socket, space_id) ->
        {:cont, socket}

      is_binary(Map.get(msg, :thread_id)) ->
        {:cont, recompute(socket, msg.thread_id)}

      true ->
        {:cont, drop_parent(socket, msg.id)}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Internals ──────────────────────────────────────────────────────

  defp on_reply(socket, viewer, thread_id) do
    case Chat.thread_activity_entry(viewer, thread_id, scope: socket.assigns[:access_scope]) do
      nil ->
        drop(socket, thread_id)

      %{parent_message_id: parent_id} = entry ->
        if MapSet.member?(socket.assigns[:expanded_threads] || MapSet.new(), parent_id) do
          # On screen already: seen. The broadcast back to this process is a
          # no-op recompute.
          Chat.mark_thread_read(viewer.id, thread_id, entry.latest_reply_id)
          drop(socket, thread_id)
        else
          move_to_end(socket, entry)
        end
    end
  end

  defp recompute(socket, thread_id) do
    case socket.assigns[:current_participant] do
      %Participant{} = viewer ->
        case Chat.thread_activity_entry(viewer, thread_id, scope: socket.assigns[:access_scope]) do
          nil -> drop(socket, thread_id)
          entry -> replace(socket, entry)
        end

      _ ->
        drop(socket, thread_id)
    end
  end

  defp move_to_end(socket, %{thread_id: thread_id} = entry) do
    entries =
      socket.assigns.thread_activity_entries
      |> Enum.reject(&(&1.thread_id == thread_id))
      |> Kernel.++([entry])
      |> Enum.take(-@entry_cap)

    socket
    |> assign(:thread_activity_entries, entries)
    |> render_rows()
  end

  # In place: a cursor change elsewhere is not new activity, so it does not
  # move the row.
  defp replace(socket, %{thread_id: thread_id} = entry) do
    entries = socket.assigns.thread_activity_entries

    if Enum.any?(entries, &(&1.thread_id == thread_id)) do
      entries = Enum.map(entries, &if(&1.thread_id == thread_id, do: entry, else: &1))

      socket
      |> assign(:thread_activity_entries, entries)
      |> render_rows()
    else
      socket
    end
  end

  defp drop(socket, thread_id) do
    entries = socket.assigns[:thread_activity_entries] || []

    if Enum.any?(entries, &(&1.thread_id == thread_id)) do
      socket
      |> assign(:thread_activity_entries, Enum.reject(entries, &(&1.thread_id == thread_id)))
      |> render_rows()
    else
      socket
    end
  end

  defp drop_parent(socket, parent_id) do
    case Enum.find(
           socket.assigns[:thread_activity_entries] || [],
           &(&1.parent_message_id == parent_id)
         ) do
      nil -> socket
      %{thread_id: thread_id} -> drop(socket, thread_id)
    end
  end

  # The rows are the newest `@row_cap` entries whose parent this viewer may
  # see; one query resolves every parent.
  defp render_rows(socket) do
    entries = socket.assigns.thread_activity_entries
    states = QuotedMessage.resolve_many(socket, Enum.map(entries, & &1.parent_message_id))

    visible =
      Enum.flat_map(entries, fn entry ->
        case Map.get(states, entry.parent_message_id) do
          %{status: :visible} = state -> [row(socket, entry, state)]
          _ -> []
        end
      end)

    socket
    |> assign(:thread_activity_overflow, max(length(visible) - @row_cap, 0))
    |> stream(:thread_activity_rows, Enum.take(visible, -@row_cap), reset: true)
  end

  defp row(socket, entry, state) do
    participants_map = socket.assigns[:participants_map] || %{}
    replier = entry.latest_participant_id

    %{
      id: entry.thread_id,
      thread_id: entry.thread_id,
      parent_message_id: entry.parent_message_id,
      new_count: entry.new_count,
      excerpt: state.preview,
      parent_author: state.author,
      replier_name: PresenceHooks.sender_name(participants_map, replier),
      replier_avatar_url: PresenceHooks.sender_avatar_url(participants_map, replier),
      replier_avatar_seed: PresenceHooks.sender_avatar_seed(participants_map, replier),
      replier_agent?:
        MapSet.member?(socket.assigns[:agent_participant_ids] || MapSet.new(), replier),
      # The accent ring's slot, as chat_message.ex stamps it on an agent row.
      replier_agent_slot:
        Platform.Agents.ColorPalette.slot_for(
          Map.get(socket.assigns[:agent_slots_map] || %{}, replier)
        )
    }
  end

  defp active_space?(socket, space_id) do
    match?(%{id: ^space_id}, socket.assigns[:active_space])
  end

  # One topic per LiveView: the current participant's. Re-entering the same
  # space (an anchored jump) keeps the subscription it has.
  defp resubscribe(socket, participant) do
    previous = socket.assigns[:thread_activity_participant_id]
    next = match_id(participant)

    cond do
      previous == next ->
        socket

      not connected?(socket) ->
        assign(socket, :thread_activity_participant_id, next)

      true ->
        if previous, do: ChatPubSub.unsubscribe_thread_reads(previous)
        if next, do: ChatPubSub.subscribe_thread_reads(next)
        assign(socket, :thread_activity_participant_id, next)
    end
  end

  defp match_id(%Participant{id: id}), do: id
  defp match_id(_), do: nil
end
