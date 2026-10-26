defmodule PlatformWeb.ChatLive.ReplyQuoteHooks do
  @moduledoc """
  The main-log reply quote (task 01a174f5 stage 3, design canvas 01a174f6):
  which top-level rows show a `PlatformWeb.Components.ReplyQuote` block above
  their body, and what it says. Attached by
  `PlatformWeb.ChatLive.MessagesHooks.attach/1`, ahead of that module's own
  handlers, so it runs from `ChatLive.mount/3` without a line in the
  ratcheted `chat_live.ex`.

  ## The rule

  A TOP-LEVEL message whose `metadata["reply_to_message_id"]` is set carries
  `:reply_quote` (a `PlatformWeb.ChatLive.QuotedMessage` state, re-read for
  THIS viewer: scope, active space, history grant) on its stream item:

    * a person's reply always shows its quote, even directly under the
      message it answers;
    * an AGENT's answer drops it when ADJACENT: when the top-level,
      non-deleted message immediately before it in main-log order
      (`Chat.message_ordered_at/1`) is the very message it quotes. Nothing came
      in between, so the quote would only repeat the row above;
    * thread messages are never stream items, and `:reply_quote` is nil for
      any message with a `thread_id`.

  Adjacency is decided at RENDER time and never stored. It is computed in the
  same window pass that assigns day labels (`MessagesHooks`): a window's
  first row costs one query for its predecessor, every later row compares
  against the row before it, and a live insert compares against the last
  rendered top-level id. A re-insert (edit, reaction, delete of the target)
  keeps the adjacency decided when the row first rendered, as a re-insert
  keeps its day label.

  ## Assigns owned

    * `:reply_quote_adjacent` — `%{msg_id => boolean}` for rendered rows that
      carry a reply target;
    * `:reply_quote_targets` — `%{msg_id => target_id}`, the same rows;
    * `:reply_quote_last_id` — the last rendered top-level id (the live
      tail), or nil.

  ## Info handled

    * `{:message_deleted, msg}` — every rendered row whose quote targets
      `msg` is re-inserted, so the 'Original message deleted' state shows
      live. Always `{:cont, socket}`: `MessagesHooks` still removes the row.

  Every other message and event passes through with `{:cont, socket}`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat
  alias PlatformWeb.ChatLive.MessagesHooks
  alias PlatformWeb.ChatLive.QuotedMessage

  @doc "Attach the reply-quote state and handler. Called from `MessagesHooks.attach/1`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> reset()
    |> attach_hook(:reply_quote_info, :handle_info, &handle_info/2)
  end

  defp reset(socket) do
    socket
    |> assign(:reply_quote_adjacent, %{})
    |> assign(:reply_quote_targets, %{})
    |> assign(:reply_quote_last_id, nil)
  end

  @doc """
  Annotate a message WINDOW (ASC, top-level, non-deleted, as
  `Chat.list_messages/2` returns it). `:reset` replaces the bookkeeping (a
  fresh window); `:prepend` merges an older batch into it.
  """
  @spec annotate_window(Phoenix.LiveView.Socket.t(), [map()], :reset | :prepend) ::
          {[map()], Phoenix.LiveView.Socket.t()}
  def annotate_window(socket, [], :reset), do: {[], reset(socket)}
  def annotate_window(socket, [], :prepend), do: {[], socket}

  def annotate_window(socket, [first | _] = messages, mode) do
    socket = if mode == :reset, do: reset(socket), else: socket

    first_prev = if needs_prev?(socket, first), do: previous_id(socket, first)

    prevs =
      messages
      |> Enum.map(& &1.id)
      |> Enum.drop(-1)
      |> then(&[first_prev | &1])

    states =
      QuotedMessage.resolve_many(
        socket,
        messages |> Enum.map(&target_id/1) |> Enum.reject(&is_nil/1)
      )

    {annotated, socket} =
      messages
      |> Enum.zip(prevs)
      |> Enum.map_reduce(socket, fn {msg, prev}, acc ->
        case target_id(msg) do
          nil ->
            {msg, acc}

          target ->
            adjacent? = prev == target
            acc = remember(acc, msg.id, target, adjacent?)
            {put_quote(acc, msg, Map.get(states, target), adjacent?), acc}
        end
      end)

    socket =
      if mode == :reset,
        do: assign(socket, :reply_quote_last_id, List.last(messages).id),
        else: socket

    {annotated, socket}
  end

  @doc """
  Annotate a NEW row appended at the live tail (a post, a broadcast, a
  re-hydrated newer batch): its predecessor is the last rendered top-level
  id, which it then becomes.
  """
  @spec annotate_new(Phoenix.LiveView.Socket.t(), map()) :: {map(), Phoenix.LiveView.Socket.t()}
  def annotate_new(socket, msg) do
    prev = socket.assigns[:reply_quote_last_id]

    socket =
      if is_nil(Map.get(msg, :thread_id)),
        do: assign(socket, :reply_quote_last_id, msg.id),
        else: socket

    case target_id(msg) do
      nil ->
        {msg, socket}

      target ->
        adjacent? = prev == target
        socket = remember(socket, msg.id, target, adjacent?)
        {put_quote(socket, msg, QuotedMessage.resolve(socket, target), adjacent?), socket}
    end
  end

  @doc """
  Annotate a RE-INSERTED row: the adjacency decided when it first rendered,
  the quote state read afresh (so a deleted target shows as deleted).
  """
  @spec annotate_existing(Phoenix.LiveView.Socket.t(), map()) :: map()
  def annotate_existing(socket, msg) do
    case target_id(msg) do
      nil ->
        msg

      target ->
        adjacent? = Map.get(socket.assigns[:reply_quote_adjacent] || %{}, msg.id, false)
        put_quote(socket, msg, QuotedMessage.resolve(socket, target), adjacent?)
    end
  end

  @doc "Set the live tail (the last rendered top-level id) before appending a batch after it."
  @spec put_tail(Phoenix.LiveView.Socket.t(), binary() | nil) :: Phoenix.LiveView.Socket.t()
  def put_tail(socket, id), do: assign(socket, :reply_quote_last_id, id)

  # ── Info ───────────────────────────────────────────────────────────

  defp handle_info({:message_deleted, %{id: deleted_id, space_id: space_id} = msg}, socket) do
    if space_id == MessagesHooks.active_space_id(socket) do
      quoting =
        for {row_id, ^deleted_id} <- socket.assigns[:reply_quote_targets] || %{},
            row_id != deleted_id,
            do: row_id

      socket =
        socket
        |> MessagesHooks.reinsert_stream_messages(quoting, space_id: space_id)
        |> forget(deleted_id)
        |> retreat_tail(msg)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Internals ──────────────────────────────────────────────────────

  defp target_id(%{thread_id: thread_id}) when not is_nil(thread_id), do: nil
  defp target_id(msg), do: QuotedMessage.reply_to_id(msg)

  # Only an agent's answer can be dropped for adjacency, so only an agent's
  # answer at the head of a window costs the predecessor query.
  defp needs_prev?(socket, msg), do: not is_nil(target_id(msg)) and agent_authored?(socket, msg)

  defp agent_authored?(socket, msg) do
    MapSet.member?(socket.assigns[:agent_participant_ids] || MapSet.new(), msg.participant_id)
  end

  # The top-level, non-deleted message immediately before `msg` in main-log
  # order: one query.
  defp previous_id(socket, msg) do
    case Chat.list_messages(msg.space_id,
           limit: 1,
           before_id: msg.id,
           top_level_only: true,
           scope: socket.assigns[:external_scope]
         ) do
      [%{id: id}] -> id
      _ -> nil
    end
  end

  defp put_quote(socket, msg, state, adjacent?) do
    quote =
      cond do
        is_nil(state) -> nil
        adjacent? and agent_authored?(socket, msg) -> nil
        true -> state
      end

    %{msg | reply_quote: quote}
  end

  defp remember(socket, msg_id, target, adjacent?) do
    socket
    |> assign(
      :reply_quote_adjacent,
      Map.put(socket.assigns[:reply_quote_adjacent] || %{}, msg_id, adjacent?)
    )
    |> assign(
      :reply_quote_targets,
      Map.put(socket.assigns[:reply_quote_targets] || %{}, msg_id, target)
    )
  end

  defp forget(socket, msg_id) do
    socket
    |> assign(
      :reply_quote_adjacent,
      Map.delete(socket.assigns[:reply_quote_adjacent] || %{}, msg_id)
    )
    |> assign(
      :reply_quote_targets,
      Map.delete(socket.assigns[:reply_quote_targets] || %{}, msg_id)
    )
  end

  # The tail was deleted: the next live row follows the one before it.
  defp retreat_tail(socket, %{id: id} = msg) do
    if socket.assigns[:reply_quote_last_id] == id and is_nil(Map.get(msg, :thread_id)),
      do: assign(socket, :reply_quote_last_id, previous_id(socket, msg)),
      else: socket
  end
end
