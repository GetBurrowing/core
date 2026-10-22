defmodule PlatformWeb.ChatLive.MessagesHooks do
  @moduledoc """
  Lifecycle hook for MessageList + Threads + Reactions + Attachments +
  Drafts in `PlatformWeb.ChatLive`.

  See ADR 0035. These concerns share `:messages` stream, `:attachments_map`,
  `:thread_previews`, and `:inline_thread_messages`. Splitting them across
  separate hooks would require fan-out coordination for every PubSub event,
  so they live in one module together — honestly representing the domain as
  "chat messages, some with thread children."

  ## State shape

  Reactions live **on the stream item itself** via the `:reactions` virtual
  field on `Platform.Chat.Message`. Every `stream_insert` re-renders the
  item against a fresh, DB-derived reaction list — so reaction broadcasts
  are idempotent (duplicate delivery doesn't double-count), in-order (the
  DB is source of truth), and don't require parallel-map bookkeeping.

  Attachments still live in the parallel `:attachments_map` assign; the
  same refactor applies to them and is a follow-up.

  ## Assigns owned

    * `:messages` (stream — items are `%Message{}` enriched with `:reactions`)
    * `:attachments_map` — msg_id → [attachments]
    * `:reaction_picker_for` — msg_id | nil — when set, the picker is open for that message
    * `:longpress_menu_for` — msg_id | nil — when set, the mobile quick-react popover (double-tap entry) is open for that message
    * `:compose_form`
    * `:thread_compose_form`
    * `:active_thread`
    * `:thread_messages`
    * `:thread_attachments_map`
    * `:thread_previews` — parent_msg_id → %{thread_id, reply_count, last_reply_at}
    * `:expanded_threads` — MapSet of parent_msg_ids with inline threads open
    * `:inline_thread_messages` — parent_msg_id → [thread messages]
    * `:highlighted_message_id`
    * `:streaming_replies`
    * `:drafts` — space_id → compose text
    * `:refused_summons` — msg_id → [agent name] for this session's own
      messages whose `@[agent]` mention was refused (task 01a0fd62 stage 2).
      Author-only and ephemeral: it is fed by a direct `send/2` from
      `Platform.Chat` to the posting process, never by PubSub.
    * `:mounted_inline_canvas_ids` — MapSet of message ids whose inline canvas
      renders its document rather than a placeholder (task 01a13884 stage 4;
      see `PlatformWeb.Components.ChatInlineCanvas`). Reset with every message
      window; canvases that arrive live are mounted on insert.
    * `:load_older_failed?` — the last `load_older_messages` raised, so the
      top sentinel offers "Couldn't load earlier messages. Retry".

  ## Events

    * Compose: `"send_message"`, `"compose_changed"` (+ draft save),
      `"open_lightbox"`, `"close_lightbox"`
    * Reactions: `"react"`, `"open_reaction_picker"`, `"close_reaction_picker"`
    * Threads: `"open_thread"`, `"close_thread"`, `"send_thread_message"`,
      `"toggle_inline_thread"`, `"send_inline_thread_message"`
    * Refused summons: `"dismiss_refused_summon"`
    * Lazy canvases: `"inline_canvas_mount"` (`message_id` or `message_ids`)

  ## Info handled

    * `{:new_message, msg}` — three-destination dispatch (main stream,
      inline thread, thread previews) depending on msg shape
    * `{:message_updated, msg}`, `{:message_deleted, msg}`
    * `{:reaction_added, r}`, `{:reaction_removed, data}`
    * `{:agent_reply_chunk, %{...}}`
    * `{:mention_summon_refused, msg_id, names}` — sent only to the author's
      own process by `Platform.Chat` when a mention could not add an agent

  ## Public helpers for cross-feature coordinators

    * `enter_space/3` — called from parent handle_params
    * `enter_space_anchored/4` — …with a history window centred on a
      deep-linked message instead of the newest page
    * `resolve_anchor/1` — classify a deep-link target as top-level vs.
      thread reply
    * `stream_insert_message/2` — used by `canvas_create` (parent)
    * `reset_thread_panel/1` — used by `canvas_open`, `canvas_create`
    * `open_thread_context/3` — used by `search_open_result` when target
      is in a thread
    * `set_highlight/2` — used by `search_open_result`
    * `set_highlight/3` — …with a thread message id too
    * `maybe_refresh/1` — compat shim; delegates to SearchHooks for now
    * `clear_draft/2` — used by send_message after successful post
  """

  require Logger

  import Phoenix.Component, only: [assign: 3, to_form: 2, update: 3]

  import Phoenix.LiveView,
    only: [
      attach_hook: 4,
      push_event: 3,
      put_flash: 3,
      stream: 3,
      stream: 4,
      stream_delete: 3,
      stream_insert: 3,
      stream_insert: 4,
      consume_uploaded_entries: 3,
      uploaded_entries: 2
    ]

  alias Platform.Chat
  alias Platform.Chat.AttachmentLinks
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.ClosedDms
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.SearchHooks
  alias PlatformWeb.NativeDonation

  @message_limit 50

  # Messages loaded on EACH side of the anchor by
  # `enter_space_anchored/4`. Half of `@message_limit` per side, so an
  # anchored window is the same total size as the default one — the
  # bounded-DOM budget below is unchanged by deep-linking.
  @anchor_half 25

  # Bounded-DOM cap for the chat message stream (task 019e18fc Stage 2,
  # "virtual list", product decision 2026-05-15). Phoenix LiveView's
  # built-in stream `:limit` only evicts from one fixed end (positive =
  # evict beginning; negative = evict end), which doesn't handle the
  # bidirectional case (prepend older = evict newest; append live tail
  # = evict oldest). We manage eviction manually below in
  # `load_older_messages/2` and `load_newer_messages/2`. UUIDv7 message
  # ids sort lexicographically by time, so MapSet → sort → take-last gives
  # the newest-end ids cheaply.
  @stream_size_limit 300

  @doc "Attach message/thread/reactions handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:attachments_map, %{})
    |> assign(:reaction_picker_for, nil)
    |> assign(:longpress_menu_for, nil)
    |> assign(:active_thread, nil)
    |> assign(:thread_messages, [])
    |> assign(:thread_attachments_map, %{})
    |> assign(:thread_previews, %{})
    |> assign(:expanded_threads, MapSet.new())
    |> assign(:inline_thread_messages, %{})
    |> assign(:streaming_replies, %{})
    |> assign(:drafts, %{})
    |> assign(:msg_day_labels, %{})
    |> assign(:last_msg_day, nil)
    |> assign(:first_msg_day, nil)
    |> assign(:rendered_message_ids, MapSet.new())
    |> assign(:earliest_message_id, nil)
    |> assign(:latest_message_id, nil)
    # Deep-link arrival target (`?message=<id>`, task 019fabe8 stage 2).
    # Owned by `ChatLive.handle_params/3`, defaulted here so every chat
    # surface — including the embedded meeting panel, which never sees
    # URL params — has the assign the message list renders off.
    |> assign(:anchor_message_id, nil)
    |> assign(:has_more_older, false)
    |> assign(:loading_older, false)
    |> assign(:loading_newer, false)
    |> assign(:newest_evicted?, false)
    |> assign(:evicted_tail_message_ids, MapSet.new())
    |> assign_compose("")
    |> assign_thread_compose("")
    |> assign(:refused_summons, %{})
    |> assign(:mounted_inline_canvas_ids, MapSet.new())
    |> assign(:load_older_failed?, false)
    |> stream(:messages, [])
    |> attach_hook(:messages_events, :handle_event, &handle_event/3)
    |> attach_hook(:messages_info, :handle_info, &handle_info/2)
  end

  @doc """
  Load the message list + derived state for a newly-entered space.
  Returns the socket with all message-related assigns populated.
  Called from `ChatLive.handle_params/3` after the active_space is set.
  """
  @spec enter_space(Phoenix.LiveView.Socket.t(), map(), map() | nil) ::
          Phoenix.LiveView.Socket.t()
  def enter_space(socket, space, participant) do
    messages = load_channel_messages(space.id)

    mark_read_at_channel_tip(participant, messages)

    # The default window always ends at the live tail, so nothing newer
    # has been evicted.
    assign_message_window(socket, space, messages, false)
  end

  @doc """
  Load a history window centred on `anchor_message_id` instead of the
  newest `@message_limit` messages.

  `enter_space/3` loads only the newest 50 top-level messages, so a
  deep-linked message older than that is not in the DOM at all — and
  `chat_scroll_to_message.js` returns silently when the node is absent,
  so the reader lands nowhere with no explanation. This builds
  `@anchor_half` messages of history on either side of the anchor so the
  message can be read *in context*, and seeds both boundary flags so the
  existing top and bottom sentinels can re-hydrate outward from there.

  Falls back to `enter_space/3` when the anchor cannot be resolved: an
  unknown or malformed id, a soft-deleted message (`list_messages/2`
  filters `deleted_at` but `get_message/2` does not), a message in a
  different space (a hand-edited `?message=` must not leak or anchor),
  or a thread reply — the window is `top_level_only: true` and can never
  contain one. Callers wanting the thread branch should consult
  `resolve_anchor/1` first.

  ## Unread semantics

  Anchored entry marks the space read at the channel's TRUE newest
  top-level message, not at the window's last message.
  `Chat.mark_space_read/2` is a blind `update_all` with no monotonic
  guard, so passing the anchored window's tail would move the read cursor
  BACKWARD and resurrect unread counts on a channel the reader just
  visited. Landing mid-history must behave exactly as an ordinary entry
  does.
  """
  @spec enter_space_anchored(Phoenix.LiveView.Socket.t(), map(), map() | nil, binary() | nil) ::
          Phoenix.LiveView.Socket.t()
  def enter_space_anchored(socket, space, participant, anchor_message_id) do
    case resolvable_anchor(space, anchor_message_id) do
      nil ->
        enter_space(socket, space, participant)

      anchor ->
        messages = load_anchored_messages(space.id, anchor)

        # NOT `List.last(messages)` — see the unread note above.
        mark_read_at_channel_tip(participant, newest_channel_message(space.id))

        newest_evicted? =
          Chat.has_more_messages_after?(space.id,
            after_id: List.last(messages).id,
            top_level_only: true
          )

        assign_message_window(socket, space, messages, newest_evicted?)
    end
  end

  @doc """
  Classify a deep-link target so the caller picks the right entry point.

  The anchored window is `top_level_only: true`, but mentions fire for
  thread replies too (`Chat.emit_inbox_for_mentions/1`), so a naive
  caller would build a window that structurally cannot contain the
  target. `{:thread, thread_id}` says "take the thread branch instead."
  """
  @spec resolve_anchor(Chat.Message.t() | nil) ::
          {:top_level, binary()} | {:thread, binary()} | :none
  def resolve_anchor(%Chat.Message{thread_id: nil, id: id}), do: {:top_level, id}

  def resolve_anchor(%Chat.Message{thread_id: thread_id}) when is_binary(thread_id),
    do: {:thread, thread_id}

  def resolve_anchor(_), do: :none

  # Resolve `anchor_message_id` to a message that the main window can
  # actually hold, or nil. `get_message/2` validates the uuid itself.
  defp resolvable_anchor(_space, nil), do: nil

  defp resolvable_anchor(space, anchor_message_id) do
    with %Chat.Message{} = msg <- Chat.get_message(anchor_message_id),
         true <- msg.space_id == space.id,
         true <- is_nil(msg.deleted_at),
         {:top_level, _id} <- resolve_anchor(msg) do
      msg
    else
      _ -> nil
    end
  end

  # `older` uses the default DESC ordering (the limit lands on the
  # messages immediately BEFORE the cursor); `newer` must ask for
  # `order: :asc` or the limit lands on the newest messages in the space
  # instead, leaving a hole between the anchor and the rest of the
  # window. Both come back needing to end up ASC.
  defp load_anchored_messages(space_id, anchor) do
    older =
      space_id
      |> Chat.list_messages(limit: @anchor_half, before_id: anchor.id, top_level_only: true)
      |> Enum.reverse()

    newer =
      Chat.list_messages(space_id,
        limit: @anchor_half,
        after_id: anchor.id,
        top_level_only: true,
        order: :asc
      )

    older ++ [anchor] ++ newer
  end

  defp newest_channel_message(space_id) do
    Chat.list_messages(space_id, limit: 1, top_level_only: true)
  end

  defp mark_read_at_channel_tip(participant, messages) do
    case {participant, List.last(messages)} do
      {%{id: participant_id}, %{id: message_id}} ->
        Chat.mark_space_read(participant_id, message_id)

      _ ->
        :ok
    end
  end

  # Shared tail of both entry points: enrich → day-label → assign → reset
  # the stream. Kept in one place because `load_older_messages/2` and
  # `load_newer_messages/2` both extend the `:rendered_message_ids` /
  # `:msg_day_labels` / boundary-day bookkeeping this establishes, and a
  # second copy would drift out from under them.
  #
  # `messages` must be ASC (oldest first).
  defp assign_message_window(socket, space, messages, newest_evicted?) do
    enriched =
      messages
      |> Enum.map(&enrich_versions_count/1)
      |> enrich_messages_with_reactions(socket)

    {labelled, day_labels, last_day} = label_messages_for_initial_load(enriched)

    # Cursor + boundary state for infinite scroll. `labelled` is in ASC
    # order (oldest first), so the head is the cursor for "load older"
    # and its day is the prepend-boundary day. The tail (last item) is
    # the live-tail cursor for "load newer" — used to re-hydrate after
    # the bottom of the bounded stream is evicted.
    earliest = List.first(labelled)
    earliest_id = earliest && earliest.id
    first_day = earliest && message_day(earliest)

    latest = List.last(labelled)
    latest_id = latest && latest.id

    has_more_older =
      case earliest_id do
        nil -> false
        id -> Chat.has_more_messages_before?(space.id, before_id: id, top_level_only: true)
      end

    attachments_map = build_attachments_map(messages, socket)
    thread_previews = Chat.thread_previews_for_messages(Enum.map(messages, & &1.id))

    socket
    |> assign(:attachments_map, attachments_map)
    |> assign(:reaction_picker_for, nil)
    |> assign(:longpress_menu_for, nil)
    |> assign(:thread_previews, thread_previews)
    |> assign(:active_thread, nil)
    |> assign(:thread_messages, [])
    |> assign(:thread_attachments_map, %{})
    |> assign(:expanded_threads, MapSet.new())
    |> assign(:inline_thread_messages, %{})
    |> assign(:streaming_replies, %{})
    |> assign(:refused_summons, %{})
    |> assign(:msg_day_labels, day_labels)
    |> assign(:last_msg_day, last_day)
    |> assign(:first_msg_day, first_day)
    |> assign(:rendered_message_ids, MapSet.new(labelled, & &1.id))
    |> assign(:earliest_message_id, earliest_id)
    |> assign(:latest_message_id, latest_id)
    |> assign(:has_more_older, has_more_older)
    |> assign(:loading_older, false)
    |> assign(:loading_newer, false)
    |> assign(:newest_evicted?, newest_evicted?)
    |> assign(:evicted_tail_message_ids, MapSet.new())
    |> assign(:mounted_inline_canvas_ids, MapSet.new())
    |> assign(:load_older_failed?, false)
    |> stream(:messages, labelled, reset: true)
    |> restore_draft(space.id)
  end

  @doc """
  `load_older_messages/2` for the top sentinel: a raise clears
  `:loading_older` and sets `:load_older_failed?` instead of crashing the
  LiveView, so the sentinel can offer a retry (task 01a13884 stage 4). The
  stream is untouched on failure, so the reading position is unchanged.
  """
  @spec try_load_older_messages(Phoenix.LiveView.Socket.t(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def try_load_older_messages(socket, space_id) when is_binary(space_id) do
    socket
    |> load_older_messages(space_id)
    |> assign(:load_older_failed?, false)
  rescue
    e ->
      Logger.warning("load_older_messages failed: #{Exception.message(e)}")

      socket
      |> assign(:loading_older, false)
      |> assign(:load_older_failed?, true)
  end

  @doc """
  Fetch + prepend an older batch of messages to the stream (infinite
  scroll, task 019e18fc). No-ops when there is no cursor or no more
  history before the cursor.

  Returns the socket with:
    * the older batch `stream_insert`ed at the top (with day labels
      computed against the existing `:first_msg_day` so the boundary
      separator only fires when crossing a calendar day)
    * `:earliest_message_id` updated to the new oldest
    * `:has_more_older` updated via a fresh peek against the new cursor
    * `:first_msg_day` updated to the new oldest day
    * `:rendered_message_ids` extended with the new ids
    * `:msg_day_labels` extended with the new id→label entries
    * `:loading_older` cleared

  `:attachments_map` and `:thread_previews` are extended via `Map.merge/2`
  so existing entries (which the live tail may have just refreshed) are
  preserved over the older-batch lookup.
  """
  @spec load_older_messages(Phoenix.LiveView.Socket.t(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def load_older_messages(socket, space_id) when is_binary(space_id) do
    case socket.assigns[:earliest_message_id] do
      nil ->
        assign(socket, :loading_older, false)

      cursor ->
        older =
          space_id
          |> Chat.list_messages(
            limit: @message_limit,
            before_id: cursor,
            top_level_only: true
          )
          |> Enum.reverse()

        if older == [] do
          socket
          |> assign(:has_more_older, false)
          |> assign(:loading_older, false)
        else
          enriched =
            older
            |> Enum.map(&enrich_versions_count/1)
            |> enrich_messages_with_reactions(socket)

          {labelled, new_day_labels, new_first_day} =
            label_messages_for_older_batch(enriched, socket.assigns[:first_msg_day])

          new_ids = Enum.map(labelled, & &1.id)

          new_earliest_id = List.first(labelled).id

          has_more_older =
            Chat.has_more_messages_before?(space_id,
              before_id: new_earliest_id,
              top_level_only: true
            )

          attachments_delta = build_attachments_map(older, socket)

          thread_previews_delta =
            Chat.thread_previews_for_messages(new_ids)

          :telemetry.execute(
            [:platform, :chat, :older_messages_loaded],
            %{count: length(older), system_time: System.system_time()},
            %{space_id: space_id}
          )

          merged_attachments =
            Map.merge(attachments_delta, socket.assigns.attachments_map || %{})

          merged_thread_previews =
            Map.merge(thread_previews_delta, socket.assigns.thread_previews || %{})

          merged_day_labels =
            Map.merge(socket.assigns[:msg_day_labels] || %{}, new_day_labels)

          merged_rendered =
            (socket.assigns[:rendered_message_ids] || MapSet.new())
            |> MapSet.union(MapSet.new(new_ids))

          # Prepend each labelled message to the stream. Consecutive
          # `at: 0` inserts REVERSE the iteration order (each new item
          # becomes the new index 0, shoving the previous one down), so
          # iterate `labelled` from newest → oldest. That lands the
          # oldest item at index 0 (top of stream) and the newest just
          # above the existing top — giving ASC visual order within the
          # batch.
          socket =
            Enum.reduce(Enum.reverse(labelled), socket, fn msg, acc ->
              stream_insert(acc, :messages, msg, at: 0)
            end)
            |> assign(:attachments_map, merged_attachments)
            |> assign(:thread_previews, merged_thread_previews)
            |> assign(:msg_day_labels, merged_day_labels)
            |> assign(:rendered_message_ids, merged_rendered)
            |> assign(:earliest_message_id, new_earliest_id)
            |> assign(:first_msg_day, new_first_day)
            |> assign(:has_more_older, has_more_older)
            |> assign(:loading_older, false)

          # Bounded-DOM cap (task 019e18fc Stage 2). If the prepend pushed
          # us past @stream_size_limit, evict the newest-end (tail) ids
          # to keep the DOM bounded. UUIDv7 ids sort lexicographically by
          # time, so the LARGEST ids are the newest end.
          prune_tail_if_over_limit(socket)
        end
    end
  end

  @doc """
  Fetch + append a fresh slice of newer messages to re-hydrate the
  live tail after `load_older_messages/2` evicted it (task 019e18fc
  Stage 2). No-ops when `:newest_evicted?` is false or no cursor is
  available.

  Mirrors `load_older_messages/2`: uses the `:after_id` keyset, batch-
  fetches per-message data, enriches with the existing initial-load
  pipeline, appends via `stream_insert` (default `at: -1`).

  After the append, if the in-DOM message count is once again over
  `@stream_size_limit`, the OLD end (top) is pruned — this is the
  symmetric case to `load_older_messages/2`'s tail-prune. The eviction
  of older messages from the top is acceptable since the user is
  scrolling toward the live tail and the older history can be re-
  fetched via `load_older_messages/2` if they scroll back up.

  Flips `:newest_evicted?` to false when the fetched batch reaches the
  current live tail (no more `has_more_messages_after?`).
  """
  @spec load_newer_messages(Phoenix.LiveView.Socket.t(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def load_newer_messages(socket, space_id) when is_binary(space_id) do
    cond do
      not socket.assigns[:newest_evicted?] ->
        assign(socket, :loading_newer, false)

      is_nil(socket.assigns[:latest_message_id]) ->
        assign(socket, :loading_newer, false)

      true ->
        cursor = socket.assigns.latest_message_id

        newer =
          space_id
          |> Chat.list_messages(
            limit: @message_limit,
            after_id: cursor,
            top_level_only: true
          )
          # `list_messages` returns DESC (newest first). Reverse to ASC
          # so we append the oldest-of-the-batch first and the newest
          # last — that puts the live tail at the bottom of the stream.
          |> Enum.reverse()

        if newer == [] do
          socket
          |> assign(:newest_evicted?, false)
          |> assign(:evicted_tail_message_ids, MapSet.new())
          |> assign(:loading_newer, false)
        else
          enriched =
            newer
            |> Enum.map(&enrich_versions_count/1)
            |> enrich_messages_with_reactions(socket)

          # Use the existing stream_insert_with_day_label helper for each
          # message so the day-label state (`:last_msg_day`,
          # `:msg_day_labels`) stays consistent with what `:on_post` /
          # `:on_broadcast` would produce. The helper appends at the
          # default `at: -1` (end of stream) and updates the rendered
          # set + day labels in lockstep.
          attachments_delta = build_attachments_map(newer, socket)
          new_ids = Enum.map(enriched, & &1.id)

          thread_previews_delta = Chat.thread_previews_for_messages(new_ids)

          merged_attachments =
            Map.merge(socket.assigns.attachments_map || %{}, attachments_delta)

          merged_thread_previews =
            Map.merge(socket.assigns.thread_previews || %{}, thread_previews_delta)

          new_latest = List.last(enriched).id

          :telemetry.execute(
            [:platform, :chat, :newer_messages_loaded],
            %{count: length(newer), system_time: System.system_time()},
            %{space_id: space_id}
          )

          socket =
            Enum.reduce(enriched, socket, &stream_insert_with_day_label(&2, &1))
            |> assign(:attachments_map, merged_attachments)
            |> assign(:thread_previews, merged_thread_previews)
            |> assign(:latest_message_id, new_latest)
            |> assign(:loading_newer, false)

          # If we caught up to the current tip, clear the evicted-tail
          # state. Otherwise the user can keep paging forward.
          caught_up? =
            not Chat.has_more_messages_after?(space_id,
              after_id: new_latest,
              top_level_only: true
            )

          socket =
            if caught_up? do
              socket
              |> assign(:newest_evicted?, false)
              |> assign(:evicted_tail_message_ids, MapSet.new())
            else
              socket
            end

          # Bounded-DOM cap: with the live tail now back in DOM, evict
          # the OLDEST end if we're over the limit. Symmetric to the
          # tail-prune on `load_older_messages/2`.
          prune_head_if_over_limit(socket)
        end
    end
  end

  # Evict the newest-end (largest UUIDv7) ids if the in-DOM count is over
  # the stream size cap. Called after `load_older_messages/2` prepends.
  # Sets `:newest_evicted?` true so the bottom sentinel renders and the
  # user can scroll back to rehydrate.
  defp prune_tail_if_over_limit(socket) do
    rendered = socket.assigns[:rendered_message_ids] || MapSet.new()
    overflow = MapSet.size(rendered) - @stream_size_limit

    if overflow > 0 do
      sorted_ids = rendered |> Enum.sort()
      ids_to_evict = Enum.take(sorted_ids, -overflow)

      remaining = rendered |> MapSet.difference(MapSet.new(ids_to_evict))
      new_latest_id = remaining |> Enum.sort() |> List.last()

      evicted_set =
        (socket.assigns[:evicted_tail_message_ids] || MapSet.new())
        |> MapSet.union(MapSet.new(ids_to_evict))

      socket =
        Enum.reduce(ids_to_evict, socket, fn id, acc ->
          stream_delete(acc, :messages, %{id: id})
        end)

      socket
      |> assign(:rendered_message_ids, remaining)
      |> assign(:latest_message_id, new_latest_id)
      |> assign(:newest_evicted?, true)
      |> assign(:evicted_tail_message_ids, evicted_set)
    else
      socket
    end
  end

  # Symmetric to `prune_tail_if_over_limit/1` — called after
  # `load_newer_messages/2` appends. Evicts the oldest-end (smallest
  # UUIDv7) ids when the stream size cap is exceeded. Updates
  # `:earliest_message_id` and re-checks `:has_more_older` because the
  # cursor for "load older" now points further forward in time.
  defp prune_head_if_over_limit(socket) do
    rendered = socket.assigns[:rendered_message_ids] || MapSet.new()
    overflow = MapSet.size(rendered) - @stream_size_limit

    if overflow > 0 do
      sorted_ids = rendered |> Enum.sort()
      ids_to_evict = Enum.take(sorted_ids, overflow)

      remaining = rendered |> MapSet.difference(MapSet.new(ids_to_evict))
      new_earliest_id = remaining |> Enum.sort() |> List.first()

      socket =
        Enum.reduce(ids_to_evict, socket, fn id, acc ->
          stream_delete(acc, :messages, %{id: id})
        end)

      space_id = socket.assigns[:active_space] && socket.assigns.active_space.id

      has_more_older =
        case {space_id, new_earliest_id} do
          {sid, eid} when is_binary(sid) and is_binary(eid) ->
            Chat.has_more_messages_before?(sid, before_id: eid, top_level_only: true)

          _ ->
            true
        end

      socket
      |> assign(:rendered_message_ids, remaining)
      |> assign(:earliest_message_id, new_earliest_id)
      |> assign(:has_more_older, has_more_older)
    else
      socket
    end
  end

  @doc """
  Insert a message into the stream and populate its attachments map
  entry. Used by `canvas_create` and `upload_send` coordinators.

  Enriches the message with its current reaction groups so the stream
  item carries everything the template needs — no :reactions_map lookup.
  """
  @spec stream_insert_message(Phoenix.LiveView.Socket.t(), map(), [map()] | nil) ::
          Phoenix.LiveView.Socket.t()
  def stream_insert_message(socket, message, attachments \\ nil) do
    # Task 01a1655c stage 5: the sender's own LiveView never sees its own
    # broadcast (`from_pid: self()`), so resolve linked attachments here the
    # same way the PubSub path does. `nil` (edits, canvases) loads the
    # message's stored attachments instead of blanking the entry.
    attachments =
      case attachments do
        nil -> attachments_with_links(message, socket)
        uploads -> attachments_with_links(message, socket, uploads)
      end

    enriched =
      message
      |> enrich_versions_count()
      |> enrich_with_reactions(socket)

    socket
    |> mount_live_canvas(enriched)
    |> stream_insert_with_day_label(enriched)
    |> put_attachment_map_entry(message.id, attachments)
  end

  @doc "Clear the thread panel. Used by canvas_open and canvas_create."
  @spec reset_thread_panel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_thread_panel(socket) do
    socket
    |> assign(:active_thread, nil)
    |> assign(:thread_messages, [])
    |> assign(:thread_attachments_map, %{})
  end

  @doc """
  Expand an inline thread for a given parent message and pre-load the
  thread messages. Used by `search_open_result` on the parent when a
  search hit is inside a thread.
  """
  @spec open_thread_context(Phoenix.LiveView.Socket.t(), binary(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def open_thread_context(socket, parent_msg_id, thread_msgs) do
    socket
    |> update(:expanded_threads, &MapSet.put(&1, parent_msg_id))
    |> update(:inline_thread_messages, &Map.put(&1, parent_msg_id, thread_msgs))
    |> reinsert_stream_message(parent_msg_id)
  end

  @doc "Parent-visible helper to load thread messages for a thread id."
  @spec load_thread_messages(binary(), binary()) :: [map()]
  def load_thread_messages(space_id, thread_id) do
    space_id
    |> Chat.list_messages(thread_id: thread_id, limit: 100)
    |> Enum.reverse()
  end

  @doc "Persist a draft for a space — used when switching spaces."
  @spec save_draft(Phoenix.LiveView.Socket.t(), binary()) :: Phoenix.LiveView.Socket.t()
  def save_draft(socket, space_id) do
    text = socket.assigns.compose_form[:text].value || ""
    update(socket, :drafts, &Map.put(&1, space_id, text))
  end

  @doc """
  Drop the outgoing space's rendered-message bookkeeping — call from the
  space-switch teardown, next to `save_draft/2`.

  `:rendered_message_ids` and `:msg_day_labels` are keyed by message id with
  no space in them, so between leaving space A and the new space's loader
  running they describe rows that are no longer on screen. Anything that
  re-hydrates from them in that gap (task 01a0119e: the presence-hook
  re-insert, which runs one line ahead of the loader) writes space A's
  messages into space B's stream. The loader repopulates both assigns a
  moment later; clearing them here removes the stale window entirely rather
  than relying on every reader to filter.

  `:last_msg_day` / `:first_msg_day` go with them because they are the same
  bookkeeping seen from the other end: `stream_reinsert_with_day_label/2` falls
  through to `stream_insert_with_day_label/2` for any id missing from
  `:msg_day_labels`, and that computes its separator against `:last_msg_day`.
  Clearing the map while keeping the day would date a row in the incoming space
  against the outgoing one — worse than clearing neither. The window CURSORS
  (`:earliest_message_id`, `:latest_message_id`, `:newest_evicted?`,
  `:evicted_tail_message_ids`) are deliberately left to the loader: nothing
  reads them between the teardown and the load, and they are not what a stale
  re-insert consults.
  """
  @spec clear_rendered_messages(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear_rendered_messages(socket) do
    socket
    |> assign(:rendered_message_ids, MapSet.new())
    |> assign(:msg_day_labels, %{})
    |> assign(:last_msg_day, nil)
    |> assign(:first_msg_day, nil)
  end

  @doc """
  The id of the space currently on screen, or `nil` when no space is open.

  Every hook that re-inserts stream rows needs it for `:space_id`, and the
  `:messages` stream belongs to this module, so the accessor lives here rather
  than being copied into each hook.
  """
  @spec active_space_id(Phoenix.LiveView.Socket.t()) :: binary() | nil
  def active_space_id(socket) do
    case socket.assigns[:active_space] do
      %{id: id} -> id
      _ -> nil
    end
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("send_message", %{"compose" => %{"text" => content}}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = %{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: String.trim(content || "")
      }

      case post_message_with_upload(socket, :attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          enriched = enrich_with_reactions(msg, socket)

          # `assign_compose("")` clears the form server-side, but morphdom
          # doesn't reliably re-sync a textarea's `.value` from the new
          # `defaultValue` once the user has typed into it (browser quirk).
          # Push the `compose_reset` event so the JS hook
          # (compose_input.js:128) explicitly clears `el.value` AND removes
          # the localStorage draft for this space.
          {:halt,
           socket
           |> stream_insert_with_day_label(enriched)
           |> put_attachment_map_entry(msg.id, attachments_with_links(msg, socket, attachments))
           |> assign_compose("")
           |> update(:drafts, &Map.delete(&1, space.id))
           |> Phoenix.LiveView.push_event("compose_reset", %{})}

        {:noop, socket} ->
          {:halt, socket}

        {:error, socket, reason} ->
          {:halt, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("compose_changed", %{"compose" => %{"text" => text}}, socket) do
    socket = assign_compose(socket, text)

    socket =
      case socket.assigns.active_space do
        %{id: space_id} -> update(socket, :drafts, &Map.put(&1, space_id, text))
        _ -> socket
      end

    {:halt, socket}
  end

  defp handle_event("compose_changed", _params, socket), do: {:halt, socket}

  defp handle_event("open_lightbox", %{"url" => url}, socket),
    do: {:halt, assign(socket, :lightbox_url, url)}

  defp handle_event("close_lightbox", _params, socket),
    do: {:halt, assign(socket, :lightbox_url, nil)}

  defp handle_event("open_reaction_picker", %{"message-id" => msg_id}, socket),
    do: {:halt, assign(socket, :reaction_picker_for, msg_id)}

  defp handle_event("close_reaction_picker", _params, socket),
    do: {:halt, assign(socket, :reaction_picker_for, nil)}

  defp handle_event("open_longpress_menu", %{"message_id" => msg_id}, socket),
    do: {:halt, assign(socket, :longpress_menu_for, msg_id)}

  defp handle_event("close_longpress_menu", _params, socket),
    do: {:halt, assign(socket, :longpress_menu_for, nil)}

  # Jump-to-latest (task 01a03c76 stage 1; second boolean added by task
  # 01a0419a stage 4).
  #
  # Both pixel thresholds — NEAR_BOTTOM_PX and DEEP_HISTORY_PX — live in the
  # ScrollToBottom JS hook and are NOT duplicated here. The client compares and
  # sends two booleans, so there is exactly one definition of "near the bottom"
  # and exactly one of "deep in history". `deep` is defaulted rather than
  # matched so an older client mid-deploy degrades to the shallow bands instead
  # of crashing the LiveView.
  defp handle_event("jump_to_latest_distance", %{"away" => away} = params, socket) do
    {:halt,
     socket
     |> assign(:jump_away_from_bottom, away == true)
     |> assign(:jump_deep_in_history, params["deep"] == true)}
  end

  # Pressing the control clears the count server-side and asks the client to
  # scroll. The count is cleared here rather than waiting for the client's
  # follow-up distance report so the pill disappears on the same round trip.
  defp handle_event("jump_to_latest", _params, socket) do
    {:halt,
     socket
     |> assign(:jump_new_message_count, 0)
     |> Phoenix.LiveView.push_event("chat:scroll-to-latest", %{})}
  end

  defp handle_event("react", %{"message-id" => msg_id, "emoji" => emoji}, socket),
    do: {:halt, socket |> react_to_message(msg_id, emoji) |> close_picker()}

  defp handle_event("open_thread", %{"message-id" => message_id}, socket),
    do: handle_event("toggle_inline_thread", %{"message-id" => message_id}, socket)

  defp handle_event("open_thread", %{"message_id" => message_id}, socket),
    do: handle_event("toggle_inline_thread", %{"message-id" => message_id}, socket)

  defp handle_event("close_thread", _params, socket) do
    {:halt,
     socket
     |> assign(:active_thread, nil)
     |> assign(:thread_messages, [])
     |> assign(:thread_attachments_map, %{})}
  end

  defp handle_event(
         "send_thread_message",
         %{"thread_compose" => %{"text" => content}},
         socket
       ) do
    with thread when not is_nil(thread) <- socket.assigns.active_thread,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = %{
        space_id: thread.space_id,
        thread_id: thread.id,
        participant_id: participant.id,
        content_type: "text",
        content: String.trim(content || "")
      }

      case post_message_with_upload(socket, :thread_attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:halt,
           socket
           |> update(:thread_messages, &(&1 ++ [msg]))
           |> put_thread_attachment_map_entry(
             msg.id,
             attachments_with_links(msg, socket, attachments)
           )
           |> assign_thread_compose("")}

        {:noop, socket} ->
          {:halt, socket}

        {:error, socket, reason} ->
          {:halt, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("toggle_inline_thread", %{"message_id" => msg_id}, socket),
    do: handle_event("toggle_inline_thread", %{"message-id" => msg_id}, socket)

  defp handle_event("toggle_inline_thread", %{"message-id" => msg_id}, socket) do
    if MapSet.member?(socket.assigns.expanded_threads, msg_id) do
      socket =
        socket
        |> update(:expanded_threads, &MapSet.delete(&1, msg_id))
        |> update(:inline_thread_messages, &Map.delete(&1, msg_id))
        |> reinsert_stream_message(msg_id)

      {:halt, socket}
    else
      space = socket.assigns.active_space

      thread =
        Chat.get_thread_for_message(msg_id) ||
          case Chat.create_thread(space.id, %{parent_message_id: msg_id}) do
            {:ok, t} -> t
            {:error, _} -> nil
          end

      case thread do
        nil ->
          {:halt, put_flash(socket, :error, "Could not open thread.")}

        thread ->
          thread_msgs = load_thread_messages(space.id, thread.id)

          socket =
            socket
            |> update(:expanded_threads, &MapSet.put(&1, msg_id))
            |> update(:inline_thread_messages, &Map.put(&1, msg_id, thread_msgs))
            |> update(
              :thread_previews,
              &Map.put(&1, msg_id, %{
                thread_id: thread.id,
                reply_count: length(thread_msgs),
                last_reply_at: List.last(thread_msgs) && List.last(thread_msgs).inserted_at
              })
            )
            |> push_event("focus_inline_thread_compose", %{message_id: msg_id})
            |> reinsert_stream_message(msg_id)

          {:halt, socket}
      end
    end
  end

  defp handle_event(
         "send_inline_thread_message",
         %{"inline_thread_compose" => %{"text" => content, "message_id" => msg_id}},
         socket
       ) do
    content = String.trim(content || "")

    with true <- content != "",
         space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      {:ok, thread} = Chat.create_thread_for_message(space.id, msg_id)

      attrs = %{
        space_id: space.id,
        thread_id: thread.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      }

      case Chat.post_message(attrs, from_pid: self()) do
        {:ok, msg} ->
          {:halt,
           socket
           # Burrow personal context (task 01a111bb): recipients only.
           |> NativeDonation.message_sent(space, participant.id)
           |> update(:inline_thread_messages, fn itm ->
             Map.update(itm, msg_id, [msg], &(&1 ++ [msg]))
           end)
           |> update(:thread_previews, fn tp ->
             preview =
               Map.get(tp, msg_id, %{thread_id: thread.id, reply_count: 0, last_reply_at: nil})

             Map.put(tp, msg_id, %{
               preview
               | reply_count: preview.reply_count + 1,
                 last_reply_at: msg.inserted_at
             })
           end)
           |> reinsert_stream_message(msg_id)}

        {:error, _reason} ->
          {:halt, put_flash(socket, :error, "Failed to send reply.")}
      end
    else
      _ -> {:halt, socket}
    end
  end

  # Author-only refused-summon notice (task 01a0fd62 stage 2). Dropping the
  # key and re-rendering the row is the whole of it: the notice was never
  # persisted, so there is nothing else to undo.
  # Lazy inline canvases (task 01a13884 stage 4). The LazyInlineCanvas hook
  # pushes the ids of placeholders that came within 600px of the viewport.
  # Only a canvas message of the ACTIVE space that is already in this
  # window is mounted: the id comes from the client, and
  # `reinsert_stream_message/2`'s fetch is not space-scoped, so the same
  # `same_active_space?/2` guard the `{:canvas_updated, _}` clause uses
  # decides, and membership of `:rendered_message_ids` stops an id from
  # appending a row the window never held.
  defp handle_event("inline_canvas_mount", params, socket) do
    {:halt, mount_inline_canvases(socket, inline_canvas_mount_ids(params))}
  end

  defp handle_event("dismiss_refused_summon", %{"id" => msg_id}, socket) do
    {:halt,
     socket
     |> update(:refused_summons, &Map.delete(&1, msg_id))
     |> reinsert_refused_summon_row(msg_id)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── Info callbacks ────────────────────────────────────────────────────

  defp handle_info({:new_message, msg}, socket) do
    active_space = socket.assigns[:active_space]
    current_participant = socket.assigns[:current_participant]

    is_background_dm =
      is_nil(active_space) or msg.space_id != active_space.id

    # Kept boolean at the point of assignment: `x && y` yields `nil` (not `false`)
    # when `x` is nil, and `not/1` accepts only booleans.
    #
    # Stage 3 swept the whole chat surface (chat_live.ex, live/chat/*.ex,
    # components/chat_message.ex) for the same `name = expr && expr` shape.
    # Sixteen assignments carry an `&&` on the right; seven are the bare
    # two-operand form; every one of the seven flows only into a context that
    # tolerates nil (an explicit `nil ->` case clause, a catch-all function
    # clause, `in`, or a class list Phoenix drops nil from). This site was the
    # only one whose result reached a strict boolean operator, so there is no
    # sibling defect to fix and no follow-up ticket to file.
    is_own_message =
      not is_nil(current_participant) and msg.participant_id == current_participant.id

    socket =
      if is_background_dm and not is_own_message do
        socket
        |> increment_unread(msg.space_id)
        |> maybe_return_closed_dm(msg)
      else
        streaming =
          socket.assigns.streaming_replies
          |> Enum.reject(fn {_k, v} -> v.participant_id == msg.participant_id end)
          |> Map.new()

        assign(socket, :streaming_replies, streaming)
      end

    if is_nil(active_space) or msg.space_id != active_space.id do
      {:halt, socket}
    else
      streaming =
        socket.assigns.streaming_replies
        |> Enum.reject(fn {_k, v} -> v.participant_id == msg.participant_id end)
        |> Map.new()

      socket = assign(socket, :streaming_replies, streaming)

      attachments = attachments_with_links(msg, socket)

      if is_nil(msg.thread_id) && current_participant do
        Chat.mark_space_read(current_participant.id, msg.id)
      end

      if is_nil(msg.thread_id) do
        enriched = enrich_with_reactions(msg, socket)

        # Jump-to-latest count (task 01a03c76 stage 1). Only counts what the
        # reader would actually miss: a top-level message (this branch —
        # thread replies never reach it), from someone else, arriving while
        # they are scrolled away from the tip. Sending a message of your own
        # snaps you to the bottom, so counting it would show a pill for a
        # message already on screen.
        socket =
          if socket.assigns[:jump_away_from_bottom] == true and not is_own_message do
            update(socket, :jump_new_message_count, &((&1 || 0) + 1))
          else
            socket
          end

        {:halt,
         socket
         |> mount_live_canvas(enriched)
         |> stream_insert_with_day_label(enriched)
         |> put_attachment_map_entry(msg.id, attachments)
         |> SearchHooks.maybe_refresh()}
      else
        socket =
          if socket.assigns.active_thread && socket.assigns.active_thread.id == msg.thread_id do
            socket
            |> update(:thread_messages, &(&1 ++ [msg]))
            |> put_thread_attachment_map_entry(msg.id, attachments)
          else
            socket
          end

        socket = maybe_update_inline_thread(socket, msg)

        {:halt, SearchHooks.maybe_refresh(socket)}
      end
    end
  end

  defp handle_info({:message_updated, msg}, socket) do
    if same_active_space?(socket, msg) do
      attachments = attachments_with_links(msg, socket)
      enriched = enrich_with_reactions(msg, socket)

      {:halt,
       socket
       |> stream_reinsert_with_day_label(enriched)
       |> put_attachment_map_entry(msg.id, attachments)
       |> SearchHooks.maybe_refresh()}
    else
      {:halt, socket}
    end
  end

  # Realtime edit event (task 019e0f29 Stage 6, contract Section c).
  # `Platform.Chat.Messages.Edit.apply_edit/3` broadcasts this on the space
  # topic after every successful edit. The payload carries the post-edit
  # `Message` struct plus diff metadata. Stream-update the row so all
  # subscribers see the new body + bumped `versions_count` + refreshed
  # `(edited)` affix without a page reload. Agents interested in the diff
  # (Section F.1 routing) consume the payload at their own layer; the LV
  # only cares about the visible message changing.
  defp handle_info({:message_edited, %{message: msg}}, socket) do
    if same_active_space?(socket, msg) do
      enriched = msg |> enrich_versions_count() |> enrich_with_reactions(socket)

      # Task 01a1655c stage 5: an edit can add or drop a linked clip.
      {:halt,
       socket
       |> stream_reinsert_with_day_label(enriched)
       |> put_attachment_map_entry(msg.id, attachments_with_links(msg, socket))}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:message_edited, _}, socket), do: {:halt, socket}

  # Policy 2 freeze broadcast (task 019e1e80 Stage 3). Fired after a task
  # transitions to :in_progress and Platform.Tasks.transition_task freezes
  # the messages in its execution space. We re-stream each affected message
  # so the bubble's `(edited)` pencil-button re-renders from
  # `chat_message.ex:159–180`, which reads `frozen_at` to switch its
  # affordance tooltip to the disabled state — no full reload required.
  defp handle_info(
         {:messages_frozen, message_ids, %{} = _meta},
         socket
       )
       when is_list(message_ids) do
    case message_ids do
      [] ->
        {:halt, socket}

      [first_id | rest_ids] ->
        # Fetch the first message once for the space-identity check and
        # reuse the same struct in the stream-insert loop — avoids a
        # duplicate Repo.get on the hot path.
        case Platform.Chat.get_message(first_id) do
          %Platform.Chat.Message{} = first_msg ->
            if same_active_space?(socket, first_msg) do
              socket = stream_insert_frozen(socket, first_msg)

              socket =
                Enum.reduce(rest_ids, socket, fn id, acc ->
                  case Platform.Chat.get_message(id) do
                    %Platform.Chat.Message{} = msg -> stream_insert_frozen(acc, msg)
                    _ -> acc
                  end
                end)

              {:halt, socket}
            else
              {:halt, socket}
            end

          _ ->
            {:halt, socket}
        end
    end
  end

  defp handle_info({:message_deleted, msg}, socket) do
    if same_active_space?(socket, msg) do
      rendered_ids = MapSet.delete(socket.assigns[:rendered_message_ids] || MapSet.new(), msg.id)

      {:halt,
       socket
       |> stream_delete(:messages, msg)
       |> drop_day_label(msg.id)
       |> assign(:rendered_message_ids, rendered_ids)
       |> delete_attachment_map_entry(msg.id)
       |> delete_thread_attachment_map_entry(msg.id)
       |> SearchHooks.maybe_refresh()}
    else
      {:halt, socket}
    end
  end

  # `reinsert_stream_message/2` fetches fresh from the DB (now with
  # `deleted_at: nil`) and stream-inserts it. The chat template's
  # `:if={is_nil(msg.deleted_at)}` predicate then renders the row
  # again. Idempotent under duplicate delivery — DB is truth.
  defp handle_info({:message_restored, msg}, socket) do
    if same_active_space?(socket, msg) do
      {:halt,
       socket
       |> reinsert_stream_message(msg.id)
       |> SearchHooks.maybe_refresh()}
    else
      {:halt, socket}
    end
  rescue
    e ->
      Logger.error("Message restore broadcast crashed: #{Exception.message(e)}")
      {:halt, socket}
  end

  # Reaction broadcasts just re-insert the affected message — `reinsert_stream_message/2`
  # fetches fresh from the DB and enriches with the current reaction groups, so the
  # stream item carries everything the template reads. Idempotent under duplicate
  # delivery (DB is truth), immune to out-of-order events.
  defp handle_info({:reaction_added, reaction}, socket) do
    if message_in_active_space?(socket, reaction.message_id) do
      {:halt, reinsert_stream_message(socket, reaction.message_id)}
    else
      {:halt, socket}
    end
  rescue
    e ->
      Logger.error("Reaction broadcast (added) crashed: #{Exception.message(e)}")
      {:halt, socket}
  end

  defp handle_info({:reaction_removed, data}, socket) do
    if message_in_active_space?(socket, data.message_id) do
      {:halt, reinsert_stream_message(socket, data.message_id)}
    else
      {:halt, socket}
    end
  rescue
    e ->
      Logger.error("Reaction broadcast (removed) crashed: #{Exception.message(e)}")
      {:halt, socket}
  end

  # LiveView streams render items once on insert and don't auto-refresh when
  # external assigns change. Inline canvas cards read `@canvases_by_id[msg.canvas_id]`,
  # so a canvas patch that only updates that assign leaves the stream item frozen
  # at its insert-time snapshot. Re-insert the referencing message(s) here so the
  # template re-renders with the updated canvas. `:cont` so CanvasHooks still runs
  # after us and refreshes `canvases_by_id` before the final diff is computed.
  #
  # `same_active_space?/2` gates the reinsert, the same guard the nine sibling
  # handlers in this module already use. `Chat.list_message_ids_for_canvas/1`
  # filters on `canvas_id` and `deleted_at` only, and `reinsert_stream_message/2`
  # reads through the unscoped `Chat.get_message/1`, so an ungated clause appends
  # a foreign space's messages to whatever pane the viewer has open.
  #
  # The guard has to sit HERE, upstream of the reinsert, not on the rendered row.
  # A foreign message id is absent from `:msg_day_labels`, so
  # `stream_reinsert_with_day_label/2` misses its label cache and falls through to
  # `stream_insert_with_day_label/2`, which writes `:last_msg_day`. The next
  # genuine message in the space the user IS viewing would then compute its day
  # separator against a foreign space's date. Suppressing the row after the fact
  # would leave that corruption in place.
  #
  # `:cont` on BOTH paths. On the pass path CanvasHooks must run after us and
  # refresh `canvases_by_id`. On the reject path `:cont` is equally deliberate:
  # halting here would stop the event reaching CanvasHooks and would make this
  # module's hook ordering load-bearing for a guard that belongs to CanvasHooks.
  # Each hook decides for itself what it will render.
  defp handle_info({:canvas_updated, canvas}, socket) do
    socket =
      if same_active_space?(socket, canvas) do
        canvas.id
        |> Chat.list_message_ids_for_canvas()
        |> Enum.reduce(socket, &reinsert_stream_message(&2, &1))
      else
        socket
      end

    {:cont, socket}
  end

  defp handle_info(
         {:agent_reply_chunk,
          %{
            space_id: space_id,
            chunk_id: chunk_id,
            text: text,
            done: done,
            participant_id: participant_id
          }},
         socket
       ) do
    active_space_id =
      case socket.assigns[:active_space] do
        %{id: id} -> id
        _ -> nil
      end

    cond do
      space_id != active_space_id ->
        # BACKLOG #9 — privacy gate. ChatLive subscribes to every
        # accessible space at mount so unread-count badges work, but
        # agent reasoning chunks must only render in the space the
        # user is currently viewing. Without this guard, a chunk from
        # #general lands in the user's DM panel whenever they happen
        # to be viewing the DM. Subscribers still receive the event
        # (broadcast scope is unchanged); the render is gated.
        {:halt, socket}

      done ->
        {:halt, update(socket, :streaming_replies, &Map.delete(&1, chunk_id))}

      true ->
        entry = %{text: text, participant_id: participant_id}
        {:halt, update(socket, :streaming_replies, &Map.put(&1, chunk_id, entry))}
    end
  end

  # Sent by `Platform.Chat` straight to the posting process (`from_pid`), so
  # only the author's own LiveView ever receives it. A message outside the
  # space on screen is ignored: the notice is tied to a row the author can
  # see, and switching space resets the map anyway.
  defp handle_info({:mention_summon_refused, msg_id, names}, socket)
       when is_binary(msg_id) and is_list(names) do
    case socket.assigns[:active_space] do
      %{id: space_id} ->
        case Chat.get_message(msg_id, scope: socket.assigns[:external_scope]) do
          %{space_id: ^space_id} ->
            {:halt,
             socket
             |> update(:refused_summons, &Map.put(&1, msg_id, names))
             |> reinsert_refused_summon_row(msg_id)}

          _ ->
            {:halt, socket}
        end

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # The notice for a top-level message renders inside its own stream row; the
  # notice for an inline-thread reply renders inside the PARENT's row (the
  # reply is not a stream item), so that is the row to re-render.
  defp reinsert_refused_summon_row(socket, msg_id) do
    case Chat.get_message(msg_id, scope: socket.assigns[:external_scope]) do
      %{thread_id: thread_id} when is_binary(thread_id) ->
        case Chat.get_thread(thread_id) do
          %{parent_message_id: parent_id} when is_binary(parent_id) ->
            reinsert_stream_message(socket, parent_id)

          _ ->
            socket
        end

      %{} ->
        reinsert_stream_message(socket, msg_id)

      nil ->
        socket
    end
  end

  defp stream_insert_frozen(socket, %Platform.Chat.Message{} = msg) do
    enriched = msg |> enrich_versions_count() |> enrich_with_reactions(socket)
    stream_insert(socket, :messages, enriched)
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp react_to_message(socket, msg_id, emoji) do
    with participant when not is_nil(participant) <- socket.assigns.current_participant do
      # DB is truth for "did this participant already react with this emoji".
      # Previously this read from :reactions_map — kept in sync locally but
      # vulnerable to stale state under duplicate delivery.
      Chat.toggle_reaction(msg_id, participant.id, emoji)
    end

    socket
  rescue
    e ->
      Logger.error("Reaction handler crashed: #{Exception.message(e)}")
      socket
  end

  defp close_picker(socket) do
    socket
    |> assign(:reaction_picker_for, nil)
    |> assign(:longpress_menu_for, nil)
  end

  defp assign_compose(socket, text) do
    assign(socket, :compose_form, to_form(%{"text" => text}, as: :compose))
  end

  defp assign_thread_compose(socket, text) do
    assign(socket, :thread_compose_form, to_form(%{"text" => text}, as: :thread_compose))
  end

  defp restore_draft(socket, space_id) do
    draft = Map.get(socket.assigns.drafts, space_id, "")
    assign_compose(socket, draft)
  end

  defp load_channel_messages(space_id) do
    space_id
    |> Chat.list_messages(limit: @message_limit, top_level_only: true)
    |> Enum.reverse()
  end

  @inline_canvas_mount_cap 50

  defp inline_canvas_mount_ids(%{"message_ids" => ids}) when is_list(ids),
    do: ids |> Enum.filter(&is_binary/1) |> Enum.take(@inline_canvas_mount_cap)

  defp inline_canvas_mount_ids(%{"message_id" => id}) when is_binary(id), do: [id]
  defp inline_canvas_mount_ids(_params), do: []

  defp mount_inline_canvases(socket, []), do: socket

  defp mount_inline_canvases(socket, ids) do
    mounted = socket.assigns[:mounted_inline_canvas_ids] || MapSet.new()
    rendered = socket.assigns[:rendered_message_ids] || MapSet.new()

    ids
    |> Enum.uniq()
    |> Enum.filter(&(MapSet.member?(rendered, &1) and not MapSet.member?(mounted, &1)))
    |> Chat.get_messages_by_ids(scope: socket.assigns[:external_scope])
    |> Enum.filter(&(&1.content_type == "canvas" and same_active_space?(socket, &1)))
    |> Enum.reduce(socket, fn msg, acc ->
      acc
      |> update(:mounted_inline_canvas_ids, &MapSet.put(&1 || MapSet.new(), msg.id))
      |> stream_reinsert_with_day_label(enrich_with_reactions(msg, acc))
    end)
  end

  @doc """
  Re-renders a single stream row by fetching the latest message from the DB
  and stream_inserting it (with day-label bookkeeping). Used when a row-level
  attribute (e.g. editing flag, reactions, version count) changes and the
  stream row needs to pick up the new attrs without clobbering the
  attachments_map — unlike `stream_insert_message/3`, this helper does not
  touch attachment state.

  Returns the socket unchanged when the message no longer exists.
  """
  def reinsert_stream_message(socket, msg_id) do
    # Scoped for the same reason as the batched sibling below: the id arrives
    # from an in-memory assign (a pin set, a reaction payload, a thread
    # preview), so this re-fetch is the membership check or there isn't one.
    case Chat.get_message(msg_id, scope: socket.assigns[:external_scope]) do
      nil ->
        socket

      msg ->
        enriched = enrich_with_reactions(msg, socket)
        stream_reinsert_with_day_label(socket, enriched)
    end
  end

  @doc """
  Batched variant of `reinsert_stream_message/2`. Fetches the messages
  in a single DB query (via `Chat.get_messages_by_ids/2`) and reinserts
  each into the `:messages` stream with the same enrichment as the
  singular path. Missing or deleted ids are silently dropped.

  Used by hooks that mutate a parent assign affecting many rows — e.g.
  presence changes that update `@participants_map`, `@agent_colors_map`,
  `@agent_participant_ids`, `@highlighted_message_id`, or
  `@pinned_message_ids` — to avoid the N+1 that would result from
  per-message `reinsert_stream_message/2` calls. Returns the socket
  unchanged on empty input (no DB hit).

  Most stream effects are exercised via the chat LiveView integration
  tests (Stage 4 of task 019e273f). The standalone unit test in
  `messages_hooks_test.exs` covers the empty-input short-circuit.

  ## Options

    * `:space_id` — REQUIRED for a non-empty id list. Only messages belonging
      to this space are re-inserted. The `:messages` stream only ever holds one
      space's rows, so a row from anywhere else is a bug in every case, and
      omitting the option raises rather than silently writing whatever the ids
      resolve to. `nil` means "no space is on screen" and re-inserts nothing.

  The space is the one the CALLER is writing, not one read back off the socket:
  `PresenceHooks.enter_space/4` passes the space it was handed, because on a
  space switch it runs before `:active_space`-derived state has caught up
  (task 01a0119e).

  The external read scope (`@external_scope`) is threaded into
  `Chat.get_messages_by_ids/2` here. The ids come out of an in-memory MapSet,
  so without it the re-fetch would be the one Chat read on this path that is
  not scope-checked.
  """
  def reinsert_stream_messages(socket, message_ids, opts \\ [])

  def reinsert_stream_messages(socket, [], _opts), do: socket

  def reinsert_stream_messages(socket, message_ids, opts) when is_list(message_ids) do
    case Keyword.fetch!(opts, :space_id) do
      nil ->
        socket

      space_id ->
        message_ids
        |> Chat.get_messages_by_ids(scope: socket.assigns[:external_scope])
        |> Enum.filter(&(&1.space_id == space_id))
        |> Enum.reduce(socket, fn msg, acc ->
          enriched = enrich_with_reactions(msg, acc)
          stream_reinsert_with_day_label(acc, enriched)
        end)
    end
  end

  defp maybe_update_inline_thread(socket, %{thread_id: thread_id} = msg)
       when is_binary(thread_id) do
    msg_id =
      Enum.find_value(socket.assigns.thread_previews, fn {pmid, %{thread_id: tid}} ->
        if tid == thread_id, do: pmid
      end)

    if is_nil(msg_id) do
      socket
    else
      socket
      |> update(:inline_thread_messages, fn itm ->
        if MapSet.member?(socket.assigns.expanded_threads, msg_id) do
          Map.update(itm, msg_id, [msg], &(&1 ++ [msg]))
        else
          itm
        end
      end)
      |> update(:thread_previews, fn tp ->
        Map.update(tp, msg_id, nil, fn preview ->
          %{preview | reply_count: preview.reply_count + 1, last_reply_at: msg.inserted_at}
        end)
      end)
      |> reinsert_stream_message(msg_id)
    end
  end

  defp maybe_update_inline_thread(socket, _msg), do: socket

  # Cap on eagerly-hydrated reactor names per emoji. A message with more
  # reactors than this fills its :reactors list with the first N and
  # exposes the remainder via :extra_count so the UI can show
  # "and N others." 20 is a guess — tune if real data shows hot reactions
  # with many more participants.
  @reactor_list_cap 20

  # Bulk-enrich a list of messages with their current reaction groups.
  # Used when loading a space: one batched query, then group per message.
  defp enrich_messages_with_reactions(messages, socket) do
    my_id = socket.assigns[:current_participant] && socket.assigns.current_participant.id
    participants_map = socket.assigns[:participants_map] || %{}
    agent_ids = socket.assigns[:agent_participant_ids] || MapSet.new()

    raw = Chat.list_reactions_for_messages(Enum.map(messages, & &1.id))

    Enum.map(messages, fn msg ->
      reactions = Map.get(raw, msg.id, [])

      groups =
        reactions
        |> Enum.group_by(& &1.emoji)
        |> Enum.map(fn {emoji, rs} ->
          build_reaction_group(emoji, rs, my_id, participants_map, agent_ids)
        end)
        |> Enum.sort_by(& &1.emoji)

      %{msg | reactions: groups}
    end)
  end

  # Single-message enrichment. Used on every stream_insert (new message,
  # message updated, reaction added/removed) so the stream item always
  # carries the current reaction groups.
  # Populate the virtual `versions_count` field from chat_message_versions.
  # Stage 6 (task 019e0f29) — the (edited) affix in chat_message.ex reads
  # this. Cheap to call (single COUNT query); applied at every stream
  # insert/update so the affix stays in sync with the DB.
  defp enrich_versions_count(%Platform.Chat.Message{} = msg) do
    %{msg | versions_count: Platform.Chat.MessageVersions.count_versions(msg.id)}
  end

  defp enrich_versions_count(msg), do: msg

  defp enrich_with_reactions(msg, socket) do
    my_id = socket.assigns[:current_participant] && socket.assigns.current_participant.id
    participants_map = socket.assigns[:participants_map] || %{}
    agent_ids = socket.assigns[:agent_participant_ids] || MapSet.new()

    groups =
      msg.id
      |> Chat.list_reactions()
      |> Enum.group_by(& &1.emoji)
      |> Enum.map(fn {emoji, rs} ->
        build_reaction_group(emoji, rs, my_id, participants_map, agent_ids)
      end)
      |> Enum.sort_by(& &1.emoji)

    %{msg | reactions: groups}
  end

  # ── Day-bucket separator labels (task 019e21c7 Stage 5) ───────────────
  #
  # The chat message list lives inside `phx-update="stream"`, so anything
  # the JS hook injects as a SIBLING of a stream item gets ripped out by
  # morphdom's reconciliation on the next stream patch. The previous
  # `applyDateSeparators` JS hook rebuilt the separators in `updated()`
  # — visually stable, but every existing separator DOM node was being
  # destroyed and recreated on every `stream_insert`, exactly the thrash
  # commits a481f87 + b7a926b were supposed to prevent.
  #
  # The fix is structural: the separator must live INSIDE the
  # stream-managed message row. We attach a virtual `:day_label` (the
  # message's calendar date as YYYY-MM-DD) to each message that is the
  # *first* of its day in the visible stream; the row template renders
  # the divider above the message body when this is non-nil. Because the
  # separator is now a child of the LV-tracked stream item, morphdom
  # reconciles it via the stable phx-id and never destroys it.
  #
  # We track two pieces of socket state:
  #   * `:msg_day_labels` — `%{msg_id => YYYY-MM-DD | nil}`. Stable
  #     identity for re-inserts (reaction toggles, edits, canvas patches
  #     re-rendering the row) so the same message keeps the same label
  #     across the lifetime of the LV.
  #   * `:last_msg_day` — the calendar date of the most-recently *new*
  #     message appended to the stream. Compared against an incoming
  #     `stream_insert` to decide whether the new row crosses a day
  #     boundary.
  #
  # `stream_insert_with_day_label/2` is for *new* messages (post,
  # broadcast); `stream_reinsert_with_day_label/2` is for in-place
  # updates (edits, reactions, canvas re-renders) — those preserve the
  # existing label so the separator stays put.

  # Walk an older-batch message list (also ASC / oldest-first) left-to-
  # right, marking the first message of each calendar day with a
  # `:day_label`. The trailing day in the batch is compared against the
  # currently-rendered `:first_msg_day` boundary: if they match, the last
  # message of the batch must NOT be labelled (the existing top-of-list
  # message already carries that day's separator). Returns
  # `{labelled_messages, %{msg_id => label_or_nil}, new_first_day}`.
  defp label_messages_for_older_batch(messages, current_first_day) do
    {rev_labelled, day_labels, _} =
      Enum.reduce(messages, {[], %{}, nil}, fn msg, {acc, labels, prev_day} ->
        date = message_day(msg)

        label =
          cond do
            is_nil(date) -> nil
            date == prev_day -> nil
            true -> date
          end

        {[%{msg | day_label: label} | acc], Map.put(labels, msg.id, label), date || prev_day}
      end)

    labelled = Enum.reverse(rev_labelled)

    # If the trailing day of the older batch matches the existing
    # boundary day, suppress the label on the last batch message so the
    # separator stays anchored to the originally-rendered row above it.
    {labelled, day_labels} =
      case List.last(labelled) do
        nil ->
          {labelled, day_labels}

        last_msg ->
          last_date = message_day(last_msg)

          if last_date != nil and last_date == current_first_day do
            patched = List.replace_at(labelled, -1, %{last_msg | day_label: nil})
            {patched, Map.put(day_labels, last_msg.id, nil)}
          else
            {labelled, day_labels}
          end
      end

    new_first_day =
      case List.first(labelled) do
        nil -> current_first_day
        first -> message_day(first) || current_first_day
      end

    {labelled, day_labels, new_first_day}
  end

  # Walk the initial-load message list left-to-right, marking the first
  # message of each calendar day with a `:day_label`. Returns
  # `{labelled_messages, %{msg_id => label_or_nil}, last_day_seen}`.
  defp label_messages_for_initial_load(messages) do
    {rev_labelled, day_labels, last_day} =
      Enum.reduce(messages, {[], %{}, nil}, fn msg, {acc, labels, prev_day} ->
        date = message_day(msg)

        label =
          cond do
            is_nil(date) -> nil
            date == prev_day -> nil
            true -> date
          end

        {[%{msg | day_label: label} | acc], Map.put(labels, msg.id, label), date || prev_day}
      end)

    {Enum.reverse(rev_labelled), day_labels, last_day}
  end

  # `stream_insert` for a *new* message: compute the day_label by
  # comparing against `:last_msg_day`, update both `:msg_day_labels` and
  # `:last_msg_day`, then insert with the label baked into the message.
  defp stream_insert_with_day_label(socket, msg) do
    date = message_day(msg)
    prev_day = socket.assigns[:last_msg_day]

    label =
      cond do
        is_nil(date) -> nil
        date == prev_day -> nil
        true -> date
      end

    new_labels = Map.put(socket.assigns[:msg_day_labels] || %{}, msg.id, label)
    next_last_day = date || prev_day
    rendered_ids = MapSet.put(socket.assigns[:rendered_message_ids] || MapSet.new(), msg.id)

    socket
    |> assign(:msg_day_labels, new_labels)
    |> assign(:last_msg_day, next_last_day)
    |> assign(:rendered_message_ids, rendered_ids)
    |> stream_insert(:messages, %{msg | day_label: label})
  end

  # `stream_insert` for an *existing* message (edit, reaction, canvas
  # patch). Reuses the previously-computed label so the separator
  # doesn't shift; if the message somehow has no entry yet (e.g. a
  # canvas re-render firing before the message ever rode the new-message
  # path), fall back to the new-message logic so we still get a stable
  # label.
  defp stream_reinsert_with_day_label(socket, msg) do
    labels = socket.assigns[:msg_day_labels] || %{}

    case Map.fetch(labels, msg.id) do
      {:ok, label} ->
        stream_insert(socket, :messages, %{msg | day_label: label})

      :error ->
        stream_insert_with_day_label(socket, msg)
    end
  end

  # Called from the two LIVE insert paths only (`{:new_message, _}` and
  # `stream_insert_message/3`), never from `stream_insert_with_day_label/2`,
  # which `load_newer_messages/2` also uses for a 50-message re-hydration.
  # A canvas that arrives while the space is open (posted live, or created
  # by this viewer) renders mounted: it lands at the reader's position, so a
  # placeholder would only flash before the hook mounted it anyway.
  defp mount_live_canvas(socket, %{content_type: "canvas", id: id}),
    do: update(socket, :mounted_inline_canvas_ids, &MapSet.put(&1 || MapSet.new(), id))

  defp mount_live_canvas(socket, _msg), do: socket

  defp drop_day_label(socket, msg_id) do
    update(socket, :msg_day_labels, &Map.delete(&1 || %{}, msg_id))
  end

  # The day a message belongs to is read off `Chat.message_ordered_at/1`, the
  # same key the stream is ORDERED by — not off `inserted_at`. They differ
  # only for an agent's spoken line in a meeting whose ack came back late
  # (task 01a07401), and only there can they differ enough to cross
  # midnight; when they do, labelling by insert time would print a
  # separator for a day the row does not sit in.
  defp message_day(%{inserted_at: %DateTime{}} = msg) do
    case Chat.message_ordered_at(msg) do
      %DateTime{} = dt -> dt |> DateTime.to_date() |> Date.to_iso8601()
      _ -> nil
    end
  end

  defp message_day(_), do: nil

  # Build one `%{emoji, count, reacted_by_me, reactors, extra_count}` group
  # from an emoji and its raw `%Reaction{}` rows. Hydrates up to
  # @reactor_list_cap names via the live participants map, falls back to
  # the row's reactor snapshot (captured at write time, survives hard-
  # delete), then to `Chat.get_participant/1`, then to "Someone."
  defp build_reaction_group(emoji, raw_reactions, my_id, participants_map, agent_ids) do
    count = length(raw_reactions)
    participant_ids = Enum.map(raw_reactions, & &1.participant_id)

    reactors =
      raw_reactions
      |> Enum.take(@reactor_list_cap)
      |> Enum.map(fn r ->
        %{
          id: r.participant_id,
          name: resolve_reactor_name(r, participants_map),
          is_agent: reactor_is_agent?(r, agent_ids)
        }
      end)

    %{
      emoji: emoji,
      count: count,
      reacted_by_me: my_id in participant_ids,
      reactors: reactors,
      extra_count: max(0, count - @reactor_list_cap)
    }
  end

  # Live participants map wins (renames propagate). Row snapshot is the
  # fallback for hard-deleted / dismissed participants — it mirrors the
  # message author snapshot pattern from ADR 0038 but on `chat_reactions`.
  # No live-DB fallback: if both the live map AND the snapshot miss, we
  # return "Someone" rather than hit `Chat.get_participant/1` — that path
  # was an N+1 (fires once per reactor per emoji per message on every
  # render) and is only relevant for reactions created before the
  # `backfill_reactor_snapshots` migration landed. The backfill is
  # idempotent and runs back-to-back with the schema migration, so the
  # window is effectively sub-second; warn loudly if it somehow persists.
  defp resolve_reactor_name(%{participant_id: pid} = reaction, participants_map) do
    case Map.get(participants_map, pid) do
      %{name: name} when is_binary(name) and name != "" ->
        name

      _ ->
        case reaction.reactor_display_name do
          name when is_binary(name) and name != "" ->
            name

          _ ->
            Logger.warning(
              "reactor_name fallback: missing snapshot for participant_id=#{inspect(pid)} (backfill may be pending)"
            )

            "Someone"
        end
    end
  end

  # Prefer live presence (handles user→agent-account edge cases), then
  # fall back to the snapshot participant type (survives hard-delete).
  defp reactor_is_agent?(%{participant_id: pid} = reaction, agent_ids) do
    cond do
      MapSet.member?(agent_ids, pid) -> true
      reaction.reactor_participant_type == "agent" -> true
      true -> false
    end
  end

  # Real attachments plus the video/image attachments the message text links
  # to (task 01a1655c stage 3), authorized for THIS viewer by
  # `AttachmentLinks.resolve_for_viewer/2`. Real attachments come first; a
  # link to a file that is also a real attachment gives one entry.
  defp build_attachments_map(messages, socket) do
    messages
    |> Enum.map(& &1.id)
    |> Chat.list_attachments_for_messages()
    |> AttachmentLinks.merge(
      AttachmentLinks.resolve_for_viewer(messages, viewer_principal(socket))
    )
  end

  defp attachments_with_links(msg, socket) do
    attachments_with_links(msg, socket, Chat.list_attachments(msg.id))
  end

  # `real` (stored or just-uploaded rows) first, then the clips the text
  # links that this viewer may read, unique by id.
  defp attachments_with_links(msg, socket, real) do
    linked = AttachmentLinks.resolve_for_viewer([msg], viewer_principal(socket))

    %{msg.id => real}
    |> AttachmentLinks.merge(linked)
    |> Map.fetch!(msg.id)
  end

  defp viewer_principal(socket) do
    case socket.assigns do
      %{current_user_record: %{id: id}} when is_binary(id) -> {:user, id}
      %{current_user: %{id: id}} when is_binary(id) -> {:user, id}
      %{user_id: id} when is_binary(id) -> {:user, id}
      _ -> nil
    end
  end

  defp put_attachment_map_entry(socket, message_id, attachments) do
    assign(
      socket,
      :attachments_map,
      Map.put(socket.assigns.attachments_map, message_id, attachments)
    )
  end

  defp delete_attachment_map_entry(socket, message_id) do
    assign(socket, :attachments_map, Map.delete(socket.assigns.attachments_map, message_id))
  end

  defp put_thread_attachment_map_entry(socket, message_id, attachments) do
    assign(
      socket,
      :thread_attachments_map,
      Map.put(socket.assigns.thread_attachments_map, message_id, attachments)
    )
  end

  defp delete_thread_attachment_map_entry(socket, message_id) do
    assign(
      socket,
      :thread_attachments_map,
      Map.delete(socket.assigns.thread_attachments_map, message_id)
    )
  end

  defp increment_unread(socket, space_id) do
    current = Map.get(socket.assigns.unread_counts, space_id, 0)
    update(socket, :unread_counts, &Map.put(&1, space_id, current + 1))
  end

  # A closed DM comes back the moment the other person writes, and it has to
  # come back on the page the viewer is already looking at (task 019ffc5f
  # stage 4). Before this, a message in a background DM only moved the unread
  # count, and a closed one stayed off the rail until a reload — so the row
  # nobody could see was the row someone was writing to.
  #
  # NOTHING IS WRITTEN. The close is stored as a timestamp and the rail's
  # filter (`Platform.Chat.ClosedDms.filter/2`) is a comparison against the
  # conversation's `last_activity_at`. The arriving message already carries a
  # newer timestamp, so putting it on the DM the rail renders from is enough
  # to flip that comparison. `closed_at` is left exactly where it is. That is
  # the property the timestamp design buys: no clearing pass to schedule, no
  # background job, and no second copy of "is it closed" to drift.
  #
  # Patched in memory, never re-fetched. `{:new_message, _}` fires for every
  # space the viewer is subscribed to, so a query here would put a database
  # round-trip on the arrival of every message anyone sends them.
  #
  # Every assign is read defensively. `MessagesHooks` has one `attach/1`
  # caller today (`ChatLive.mount/3`), so in practice they are all there;
  # reading them through `assigns[...]` costs nothing and means a future
  # surface that attaches this hook without a rail gets a no-op instead of a
  # crash. Defaulting a MISSING one is not the safer branch and is not done
  # here: rebuilding the sections from an empty `channels` would empty the
  # rail.
  defp maybe_return_closed_dm(socket, msg) do
    assigns = socket.assigns

    with %{} = closed_dm_at <- assigns[:closed_dm_at],
         %DateTime{} = closed_at <- Map.get(closed_dm_at, msg.space_id),
         %DateTime{} = arrived_at <- msg.inserted_at,
         :gt <- DateTime.compare(arrived_at, closed_at),
         dms when is_list(dms) <- assigns[:dm_conversations],
         channels when is_list(channels) <- assigns[:channels],
         %{} <- assigns[:channel_sections],
         pinned when not is_nil(pinned) <- assigns[:pinned_space_ids],
         hidden when not is_nil(hidden) <- assigns[:hidden_channel_ids],
         dm when not is_nil(dm) <- Enum.find(dms, &(&1.id == msg.space_id)),
         # Only when the row is hidden RIGHT NOW, asked of the same module the
         # rail asks so the two can never disagree about the rule. Nothing
         # clears `closed_at` until the viewer opens the DM, so without this
         # the recompute would re-run for EVERY later message in that
         # conversation — and since the patched timestamp differs each time,
         # `assign/3`'s equality check would miss and LiveView would re-diff
         # the whole sidebar once per message, forever.
         #
         # It also settles three edge cases at no extra cost: a space that is
         # not in `@dm_conversations` never gets here, and neither does a
         # message that arrives out of order behind one already counted, so
         # `last_activity_at` can only ever move forward.
         {[], [^dm]} <- ClosedDms.filter([dm], closed_dm_at) do
      # Kept on the assign, not just handed to the recompute below. The next
      # unrelated rebuild of the sections — a pin toggle, a hide — reads
      # `@dm_conversations` again, and would put the row straight back into
      # hiding if the newer activity only ever lived in a local variable.
      #
      # `@spaces` holds the same structs and is deliberately NOT patched: no
      # template reads `last_activity_at` off it. A rail built from `@spaces`
      # later would need patching here too.
      patched =
        Enum.map(dms, fn
          %{id: id} = conversation when id == msg.space_id ->
            %{conversation | last_activity_at: arrived_at}

          conversation ->
            conversation
        end)

      socket
      |> assign(:dm_conversations, patched)
      |> assign(
        :channel_sections,
        ChatLive.channel_sections(channels, patched, pinned, hidden, closed_dm_at)
      )
    else
      _ -> socket
    end
  end

  # ── Upload plumbing shared between send_message, send_thread_message, upload_send ──

  @doc """
  Post a message that may have pending uploads. The upload slot (:attachments
  or :thread_attachments) is configured via `allow_upload` on the parent
  LiveView. Returns `{:ok, socket, msg, attachments}` | `{:noop, socket}`
  | `{:error, socket, reason}`.
  """
  @spec post_message_with_upload(Phoenix.LiveView.Socket.t(), atom(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t(), map(), [map()]}
          | {:noop, Phoenix.LiveView.Socket.t()}
          | {:error, Phoenix.LiveView.Socket.t(), String.t()}
  def post_message_with_upload(socket, upload_name, attrs) do
    content = String.trim(Map.get(attrs, :content, "") || "")
    attrs = Map.put(attrs, :content, content)

    cond do
      upload_in_progress?(socket, upload_name) ->
        {:error, socket, "Please wait for uploads to finish."}

      content == "" and not has_completed_uploads?(socket, upload_name) ->
        {:noop, socket}

      true ->
        case persist_uploaded_attachments(socket, upload_name) do
          {:ok, pending_attachments} ->
            # M9 (rbac-external-users): thread the composing user's id so the
            # external upload-scope gate fires at the write seam even if the
            # filtered composer (M5) is bypassed. Internal / nil users pass
            # through; `:out_of_external_scope` reuses the failure flash below.
            case Chat.post_message_with_attachments(attrs, pending_attachments,
                   from_pid: self(),
                   poster_user_id: socket.assigns[:user_id]
                 ) do
              {:ok, msg, saved_attachments} ->
                # Burrow personal context (task 01a111bb): every web send
                # (composer, thread with files, ChatLive's own) lands here.
                # Recipients only, never the message.
                socket =
                  NativeDonation.message_sent(
                    socket,
                    donation_space(socket, attrs[:space_id]),
                    attrs[:participant_id]
                  )

                {:ok, socket, msg, saved_attachments}

              {:error, _reason} ->
                AttachmentStorage.delete_many(pending_attachments)
                {:error, socket, "Failed to send message."}
            end

          {:error, :storage_failed} ->
            {:error, socket, "Failed to store attachment."}
        end
    end
  end

  defp donation_space(socket, space_id) do
    case socket.assigns[:active_space] do
      %{id: ^space_id} = space -> space
      _ -> nil
    end
  end

  defp persist_uploaded_attachments(socket, upload_name) do
    results =
      consume_uploaded_entries(socket, upload_name, fn %{path: path}, entry ->
        result =
          case AttachmentStorage.persist_upload(path, entry.client_name, entry.client_type) do
            {:ok, attrs} -> {:ok, attrs}
            {:error, _reason} -> {:error, :storage_failed}
          end

        {:ok, result}
      end)

    {ok_results, error_results} = Enum.split_with(results, &match?({:ok, _}, &1))
    attachments = Enum.map(ok_results, fn {:ok, attrs} -> attrs end)

    if error_results == [] do
      {:ok, attachments}
    else
      AttachmentStorage.delete_many(attachments)
      {:error, :storage_failed}
    end
  end

  defp has_completed_uploads?(socket, upload_name) do
    case uploaded_entries(socket, upload_name) do
      {[_ | _], _in_progress} -> true
      _ -> false
    end
  end

  defp upload_in_progress?(socket, upload_name) do
    case uploaded_entries(socket, upload_name) do
      {_completed, [_ | _]} -> true
      _ -> false
    end
  end

  @doc """
  Cross-space broadcast guard: does `payload` belong to the space this socket
  is currently viewing?

  The chat LiveView subscribes to ALL the user's spaces on mount so sidebar
  features like unread counts update in real time, and an internal user's
  subscribe set spans every channel in the workspace across every org. That
  breadth is intended (internal staff can see channels across client orgs) and
  belongs to the SUBSCRIPTION. It is not permission to RENDER. Broadcast
  handlers therefore receive events from every subscribed space, not just the
  active one, and each one has to ask this question before it touches the
  socket. Without the guard, edits / deletes / reactions / canvas writes in
  space A leak into the user's view of space B as ghost rows in the `:messages`
  stream.

  Accepts any payload with a binary `space_id`, which covers `Message`,
  `Canvas`, and the plain maps some broadcasts carry. Anything else is `false`:
  a payload that cannot prove which space it came from is not renderable here.
  `false` when there is no active space at all, for the same reason.

  Public so `PlatformWeb.ChatLive.CanvasHooks` can apply the SAME guard rather
  than growing a second copy of it. Both hook modules are attached to the one
  `ChatLive` socket, so one definition keeps them from drifting apart and
  disagreeing about what is renderable.
  """
  @spec same_active_space?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def same_active_space?(socket, %{space_id: space_id}) when is_binary(space_id) do
    case socket.assigns[:active_space] do
      %{id: ^space_id} -> true
      _ -> false
    end
  end

  def same_active_space?(_socket, _payload), do: false

  # Reaction payloads carry only `message_id`, not `space_id`. Look up the parent
  # message's space and compare. The DB hit only fires when the broadcast is
  # actually delivered to this LV process; in the cross-space case it gates the
  # leak with one extra `Repo.get/2`, which is cheap relative to the alternative
  # (ghost rows in the visible stream).
  defp message_in_active_space?(socket, message_id) when is_binary(message_id) do
    active_id =
      case socket.assigns[:active_space] do
        %{id: id} -> id
        _ -> nil
      end

    if is_nil(active_id) do
      false
    else
      case Chat.get_message(message_id) do
        %{space_id: ^active_id} -> true
        _ -> false
      end
    end
  end

  defp message_in_active_space?(_socket, _message_id), do: false
  # ── Jump-to-latest chip labelling (task 01a03c76 stage 4) ──────────
  #
  # THE CAP IS ONE LITERAL IN ONE PLACE. The design canvas specifies `99+`;
  # Chat's icon-rail badge caps at `9+`. That disagreement is an OPEN
  # question with the designer at the time of writing, so this ships the canvas's
  # 99 and confines the answer to `@jump_count_cap` below. Flipping the
  # ruling is editing this single integer — no second constant exists
  # anywhere, the template does not compare against a number, and the tests
  # read the threshold back through `jump_count_cap/0` rather than pinning
  # the string "99+".
  @jump_count_cap 99

  @doc """
  The largest count rendered as itself; anything above shows as `"<cap>+"`.

  Exposed so tests can assert the boundary behaviour against the threshold
  itself instead of hardcoding today's number in every assertion.
  """
  def jump_count_cap, do: @jump_count_cap

  @doc """
  The badge text for `count` new messages, saturating at `jump_count_cap/0`.
  """
  def jump_count_label(count) when count > @jump_count_cap, do: "#{@jump_count_cap}+"
  def jump_count_label(count), do: Integer.to_string(count)

  @doc """
  The chip's accessible name: the action, then the count as a sentence.

  The badge itself is `aria-hidden`, following the rail badge — the number
  reaches assistive tech only through this string, in words, singular at 1.
  The count is spoken in FULL here even when the badge is capped: "100 new
  messages" is what a screen reader user needs, and "99+ new messages" is
  not a sentence.

  There is deliberately no `aria-live` on the chip. It is a way back, not an
  announcement; re-announcing on every increment is the alarm tone the
  design explicitly rejected.
  """
  def jump_aria_label(0), do: "Jump to latest message."
  def jump_aria_label(1), do: "Jump to latest message. 1 new message."
  def jump_aria_label(count), do: "Jump to latest message. #{count} new messages."

  @doc """
  Whether the jump-to-latest control is in the DOM at all (task 01a0419a
  stage 4).

  THE FIVE BANDS. Position is reported by the ScrollToBottom hook as two
  booleans; `count` is this module's own tally of top-level messages from other
  participants that arrived while the reader was away from the tip.

      position     nothing new        a message arrived
      ─────────────────────────────────────────────────
      at bottom    nothing            nothing (it scrolls to you)
      shallow      NOTHING            pill WITH badge
      deep         pill, no badge     pill WITH badge

  The middle-left cell is the whole point. Before this, visibility was the
  distance predicate alone, so scrolling up to re-read three messages raised a
  pill nobody asked for — the operator's complaint in his own words. It is also the
  cell most easily left untested: at-bottom and deep both pass comfortably
  while it is broken in either direction.

  PROVENANCE: the two-threshold rule was proposed, WITHDRAWN by Saru in canvas
  revision 3, then REINSTATED BY THE OPERATOR DIRECTLY — the deep case is not the same
  as reading a few messages up. Collapsing `deep?` back into `away?` here
  restores behaviour that was explicitly rejected.

  Note the top row needs no clause: `count` only ever increments while
  `away?` is true, so a bottom-parked reader is `{false, false, 0}`.

  The ORDERING invariant that makes "shallow" a non-empty band lives with the
  constants in `assets/js/hooks/scroll_to_bottom.js`, which throws at module
  load if the deep threshold is not strictly greater than the near one.
  """
  @spec jump_chip_visible?(boolean() | nil, boolean() | nil, integer() | nil) :: boolean()
  def jump_chip_visible?(deep?, away?, count),
    do: deep? == true or (away? == true and (count || 0) > 0)
end
