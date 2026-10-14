defmodule PlatformWeb.ChatLive.CanvasHooks do
  @moduledoc """
  Lifecycle hook module for canvases in `PlatformWeb.ChatLive` (ADR 0036).

  Owns:

    * Assigns: `:canvases`, `:canvases_by_id`, `:active_canvas`,
      `:show_canvases`, `:new_canvas_form`, `:canvas_search_query`,
      `:canvas_search_results`, `:canvas_unindexed_count`, and the explorer's
      `:canvas_groups`, `:canvas_pinned_groups`, `:canvas_parent_titles`,
      `:canvas_expanded_keys`, `:canvas_explorer_collapsed`,
      `:canvas_explorer_offsets`, `:canvas_archive_count`,
      `:canvas_search_focus`
    * Events:  `"canvas_panel_toggle"`, `"canvas_close"`,
      `"canvas_open_mobile"`, `"canvas_patch"`, `"canvas_action_click"`,
      `"canvas_form_submit"`, `"canvas_search"`,
      `"canvas_explorer_toggle_group"`, `"canvas_explorer_page"`,
      `"canvas_explorer_expand"`, `"canvas_explorer_collapse"`, and the
      canvas-room relay `"canvas_room_join"`, `"canvas_room_op"`,
      `"canvas_room_ephemeral"`, `"canvas_room_leave"` (task 01a1316b-84fa
      stage 2; see the comment above those clauses), and `"canvas_room_call"`
      (task 01a1316b-aab0 stage 2)
    * Info:    `{:canvas_created, canvas}`, `{:canvas_updated, canvas}`, and
      the room's `{:canvas_room_diff | :canvas_room_presence |
      :canvas_room_ephemeral, ...}` plus the room pid's `:DOWN`, and
      `{:canvas_room_call_result, req, result}`

  ## The explorer's data (task `01a0740d` stage 3)

  The canvases drawer's list is `PlatformWeb.Components.Canvases.CanvasExplorer`,
  which renders exactly what it is handed and resolves nothing. Everything it
  needs is derived HERE, by `refresh_explorer/1`, which names its own refresh
  points — see the long comment above it. Two rules that comment expands on:

    * `:canvases` and `:canvas_groups` are NOT the same list and neither is
      derived from the other. `:canvases` is the whole space's canvases as full
      `%Canvas{}` structs (`document` node trees and all) and still backs the
      drawer-toggle badge, `:canvases_by_id`, and every message that names a
      canvas. `:canvas_groups` is bounded, multi-space and document-free. A
      "simplification" that fed the explorer from `:canvases` would put 400 node
      trees back in the socket and cap the explorer at one space.
    * the explorer is MULTI-space. The space set is the viewer's own
      participation (`Chat.list_user_conversations/2`, which is the
      participant-row read and applies the external scope) plus the space they
      are standing in. It is not `Chat.list_spaces/1`, which is workspace-wide
      for internal users and would show a viewer canvas titles out of spaces
      they are not in.

  Per-type LiveView event handlers (canvas_save_form, canvas_save_code,
  canvas_save_diagram, canvas_refresh_dashboard, canvas_sort) are removed.
  UI mutations flow through the generic `canvas_patch` event which applies a
  list of `CanvasPatch` operations.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, push_event: 3]

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Versions, as: CanvasVersions
  alias Platform.Chat.CanvasAccess
  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.CanvasRoom
  alias Platform.Chat.CanvasSearchIndex
  alias Platform.Chat.Presence
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings
  alias Platform.Tasks.CanvasAttachments
  alias PlatformWeb.ChatLive.MessagesHooks

  # Most-recently-edited first. `Chat.list_canvases/2` still defaults to
  # `:inserted_asc` for its other callers — the panel asks for what it wants
  # rather than changing the sequence the MCP tools already see.
  @default_sort :updated_desc

  # Rows per GROUP per page. Matches `CanvasExplorer`'s own `page_size` default,
  # and the two are a pair on purpose: the component takes at most `page_size`
  # of whatever list it is handed, so a query limit LARGER than the component's
  # page would load rows nothing renders, and a smaller one would make the
  # pager offer a next page that repeats rows already shown. If either moves,
  # both move.
  @canvas_explorer_page_size 20

  # Canvas rooms: only the op set's own argument keys reach the room and its
  # event log (task 01a1316b-84fa stage 2).
  @room_op_keys ~w(type key value by name item id patch)

  # The allow-list IS the parse. `String.to_existing_atom/1` on a client-supplied
  # string would still admit any atom the VM happens to have loaded, which is
  # most of them; this admits exactly four and falls back to the default.
  @sorts %{
    "updated_desc" => :updated_desc,
    "inserted_desc" => :inserted_desc,
    "inserted_asc" => :inserted_asc,
    "title_asc" => :title_asc
  }

  @doc """
  Is the drawer in RESULTS mode rather than LIST mode?

  The single predicate both the handler and the template ask, so the branch
  that decides whether to RUN a search and the branch that decides whether to
  RENDER results can never disagree. Split in two, a blank query could clear
  the results assign while the template still showed a results pane, or run a
  search whose output nothing displayed.

  Blank (or non-binary) means list mode: the drawer shows its existing sorted
  list, untouched.
  """
  @spec search_active?(term()) :: boolean()
  def search_active?(query) when is_binary(query), do: String.trim(query) != ""
  def search_active?(_query), do: false

  @doc "The sort options offered in the canvases drawer, in display order."
  @spec sort_options() :: [{String.t(), String.t()}]
  def sort_options do
    [
      {"updated_desc", "Last updated"},
      {"inserted_desc", "Newest"},
      {"inserted_asc", "Oldest"},
      {"title_asc", "Title"}
    ]
  end

  @doc "Attach canvas handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:canvases, [])
    |> assign(:canvases_by_id, %{})
    |> assign(:active_canvas, nil)
    |> assign(:show_canvases, false)
    |> assign(:canvas_sort, @default_sort)
    |> assign(:canvas_search_query, "")
    |> assign(:canvas_search_results, [])
    |> assign(:canvas_unindexed_count, 0)
    |> reset_explorer()
    |> assign(:recent_canvas_events, [])
    |> assign(:show_versions_panel, false)
    |> assign(:canvas_versions, [])
    |> assign(:restore_confirm_revision, nil)
    |> assign(:canvas_rooms, %{})
    |> assign_new_form()
    |> attach_hook(:canvas_events, :handle_event, &handle_event/3)
    |> attach_hook(:canvas_info, :handle_info, &handle_info/2)
  end

  @doc "Load canvases for a space."
  @spec load_for_space(Phoenix.LiveView.Socket.t(), binary()) :: Phoenix.LiveView.Socket.t()
  def load_for_space(socket, space_id) do
    sort = Map.get(socket.assigns, :canvas_sort, @default_sort)
    canvases = Chat.list_canvases(space_id, order: sort)

    unsubscribe_all_canvases(socket)
    Enum.each(canvases, fn c -> ChatPubSub.subscribe_canvas(c.id) end)

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_id, build_map(canvases))
    |> assign(:active_canvas, nil)
    |> assign(:show_canvases, false)
    |> assign(:canvas_sort, sort)
    # A search is scoped to the space it was typed in, so switching spaces
    # clears it rather than carrying a query — and its results, which are rows
    # from the space you just left — into the new one.
    |> assign(:canvas_search_query, "")
    |> assign(:canvas_search_results, [])
    |> assign(:canvas_unindexed_count, CanvasSearchIndex.unindexed_count([space_id]))
    # The explorer's groups are NOT loaded here, on purpose. This function
    # leaves `:show_canvases` false, so nothing the explorer would render is on
    # screen — and the three queries behind it would run on every space nav for
    # a drawer most navigations never open. They are loaded at the moment the
    # drawer opens instead (`refresh_explorer/1`'s refresh-point list).
    #
    # The one thing set here is which groups start OPEN: the two pinned groups
    # and the space being entered. Every OTHER space starts collapsed, which is
    # the explorer's default and what makes it survive 400 canvases.
    #
    # Why these three and not none. Collapsing the space you are standing in
    # would mean opening the drawer in a channel and seeing no canvases at all,
    # where the flat list this replaced showed them immediately — a regression
    # dressed as a feature. And a PINNED group that arrives collapsed is a
    # contradiction: pinning is a claim that these two or three canvases are the
    # ones in play right now, and a claim you have to click to read is not being
    # made. Both keys are listed unconditionally; a key naming a group that does
    # not exist (no live meeting, not an execution space) matches nothing and
    # costs nothing.
    |> reset_explorer()
    |> assign(:canvas_expanded_keys, ["meeting", "task", "space:" <> space_id])
    |> assign_new_form()
  end

  defp unsubscribe_all_canvases(socket) do
    Enum.each(Map.get(socket.assigns, :canvases, []), fn c ->
      ChatPubSub.unsubscribe_canvas(c.id)
    end)
  end

  @doc "Merge a canvas into hook state."
  @spec put(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def put(socket, canvas) do
    canvases =
      socket.assigns.canvases
      |> Enum.reject(&(&1.id == canvas.id))
      |> Kernel.++([canvas])
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    # Subscribe only when this canvas is first-sight for this LiveView.
    # `put/2` runs on every `{:canvas_patched, _}` delivery, and
    # `Phoenix.PubSub` does NOT dedup within a single pid: its registry is
    # `keys: :duplicate` (deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex)
    # and `subscribe/3` is a bare `Registry.register/3`
    # (deps/phoenix_pubsub/lib/phoenix/pubsub.ex), so an unconditional
    # re-subscribe would add ANOTHER registration per patch and multiply
    # delivery for the rest of the space visit.
    #
    # Safe assigns access: a canvas broadcast can arrive before mount finishes
    # initializing `:canvases_by_id`, which is why `remove/2` reads safely too.
    known = Map.get(socket.assigns, :canvases_by_id, %{})
    unless Map.has_key?(known, canvas.id), do: ChatPubSub.subscribe_canvas(canvas.id)

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_id, build_map(canvases))
    |> maybe_update_active(canvas)
    # Keep the explorer's bounded groups in step with a canvas that appeared or
    # changed under an OPEN drawer, the way the flat list this replaced was kept
    # in step by the `:canvases` assign above. Gated on `:show_canvases` inside
    # `maybe_refresh_explorer/1`, so a busy space's canvas broadcasts do not run
    # three queries each into a socket nobody is looking at.
    |> maybe_refresh_explorer()
  end

  @doc "Remove a canvas from the socket's local list (paired with `{:canvas_deleted, canvas}` broadcasts)."
  @spec remove(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def remove(socket, canvas) do
    # Use safe assigns access — a {:canvas_deleted, _} broadcast can race with
    # mount and arrive before :canvases / :canvases_by_id are initialized.
    canvases =
      socket.assigns
      |> Map.get(:canvases, [])
      |> Enum.reject(&(&1.id == canvas.id))

    active =
      case socket.assigns[:active_canvas] do
        %{id: id} when id == canvas.id -> nil
        other -> other
      end

    # Release the topic, but only when we actually held this canvas:
    # `{:canvas_deleted, _}` fires for foreign ids too, and an unconditional
    # unsubscribe — while a harmless no-op — would misstate intent here.
    #
    # NOTE the asymmetry, because the obvious inference from the comment in
    # `put/2` ("a repeat subscribe adds a second registration, so pair every
    # subscribe with an unsubscribe") is WRONG. `Phoenix.PubSub.unsubscribe/2`
    # is `Registry.unregister/2`, which removes ALL of this pid's entries for
    # the key: two registrations go to zero, not one. Unsubscribing therefore
    # CLEARS the topic for this process rather than decrementing it.
    #
    # That is correct here only because this module is the sole subscriber to
    # `chat:canvas:<id>` in the LiveView process — checked with
    # `git grep -n 'subscribe_canvas'`: the only other call site is
    # `Platform.Chat.Canvas.ToolHandlers.maybe_subscribe/1`, which runs in an
    # agent tool process, not this pid. If another path in this process ever
    # subscribes the same topic, this line silently kills its subscription too,
    # with no error and no symptom until something stops updating.
    if Enum.any?(Map.get(socket.assigns, :canvases, []), &(&1.id == canvas.id)) do
      ChatPubSub.unsubscribe_canvas(canvas.id)
    end

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_id, build_map(canvases))
    |> assign(:active_canvas, active)
    |> maybe_refresh_explorer()
  end

  @doc "Set the active canvas."
  @spec set_active(Phoenix.LiveView.Socket.t(), map() | nil) :: Phoenix.LiveView.Socket.t()
  def set_active(socket, canvas), do: assign(socket, :active_canvas, canvas)

  @doc "Show the canvases panel."
  @spec show_panel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def show_panel(socket) do
    # `refresh_unindexed_count/1` and `refresh_explorer/1` here as well as in
    # `"canvas_panel_toggle"`: a canvas message can open this panel without the
    # toggle ever being clicked (`"canvas_create"` in `chat_live.ex`, while the
    # drawer is closed), and a panel opened that way would otherwise render
    # whatever the count and the explorer's groups were last loaded as — in the
    # worst case the previous space's, because `load_for_space/2` deliberately
    # leaves the explorer empty. See the refresh-point lists above
    # `refresh_unindexed_count/1` and `refresh_explorer/1`.
    socket
    |> assign(:show_canvases, true)
    |> refresh_unindexed_count()
    |> refresh_explorer()
  end

  @doc "Reset the new-canvas form."
  @spec reset_new_form(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def reset_new_form(socket, attrs \\ %{}), do: assign_new_form(socket, attrs)

  @doc """
  Find a canvas by id — DB first, then cached list.

  ## KNOWN GAP: this resolves canvases the viewer has no claim on

  Not fixed here. Deliberately left for the stage that owns canvas READ
  surfaces (task 019e2c4b stage 3/4), because closing it means deciding
  whether root-org admins keep their current de-facto global canvas read — a
  policy question, not a refactor. Recorded so the next person does not have
  to rediscover it.

  Both halves are unauthorized:

    * `Chat.get_canvas/1` is the documented UNAUTHORIZED primitive — it
      resolves any live canvas by id, in any space, in any org.
    * `socket.assigns.canvases` is not the space-scoped list it looks like.
      `handle_info({:canvas_created, canvas}, …)` appends to it, and this
      socket receives that broadcast for every space topic it is subscribed
      to — wider than the mounted space.

  `canvas_id` arrives as an event param, so a client can push `canvas_open` /
  `canvas_open_mobile` with any UUID regardless of what was rendered, and pin
  a foreign canvas as `active_canvas`.

  **Every WRITE reached from an `active_canvas` must therefore authorize for
  itself** rather than trusting that `find/2` vetted it. See
  `canvas_versions_restore_confirm`, which gates on
  `Platform.Chat.CanvasAccess.fetch_for_writer/2` (task 019e2c4b stage 2) —
  that is what stops this from being a cross-space document overwrite.
  """
  @spec find(Phoenix.LiveView.Socket.t(), binary()) :: map() | nil
  def find(socket, canvas_id) do
    Chat.get_canvas(canvas_id) || Enum.find(socket.assigns.canvases, &(&1.id == canvas_id))
  end

  defp viewer(socket) do
    case current_user_id(socket) do
      id when is_binary(id) -> {:user, id}
      _ -> nil
    end
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("canvas_sort", %{"order" => order}, socket) do
    sort = Map.get(@sorts, order, @default_sort)

    case socket.assigns[:active_space] do
      %{id: space_id} when is_binary(space_id) ->
        # Re-query rather than sorting the loaded list in memory. An in-memory
        # sort would be a SECOND implementation of an ordering the query already
        # defines, and the two would drift — the exact failure this codebase
        # keeps producing. The canvas SET is unchanged here, only its sequence,
        # so this deliberately does not re-subscribe or touch `:show_canvases`;
        # going through `load_for_space/2` would close the drawer the user is
        # looking at.
        canvases = Chat.list_canvases(space_id, order: sort)

        {:halt,
         socket
         |> assign(:canvas_sort, sort)
         |> assign(:canvases, canvases)
         |> assign(:canvases_by_id, build_map(canvases))
         # The explorer holds ONE bounded page of each group, so its order is a
         # query option and not a list to re-sort. See `refresh_explorer/1`'s
         # refresh points.
         |> maybe_refresh_explorer()}

      _ ->
        {:halt, assign(socket, :canvas_sort, sort)}
    end
  end

  defp handle_event("canvas_search", %{"query" => query}, socket) when is_binary(query) do
    # WHERE THE SPACE ID COMES FROM, because it decides whether this query can
    # be handed a malformed id. `Chat.search_canvases/3` is NOT cast-safe —
    # `where: c.space_id in ^space_ids` raises `Ecto.Query.CastError` on a
    # value that is not a UUID, and stage 4 deliberately left it that way on
    # the assumption that stage 5 would pass a DB-derived id. This is that
    # assumption, discharged: the id is read from `:active_space`, which
    # `ChatLive.handle_params/3` assigns only from a `Chat.get_space/1` row
    # (a nil lookup redirects before any assign happens). It is never read
    # from `params` here. The QUERY is client-supplied and that is fine — it
    # is bound as text, and a non-binary is refused by this clause's guard.
    #
    # Do not "simplify" this to take a space id off the event payload. That is
    # the shape of open ticket `01a06e20-78df` (`toggle_pinned` passing a
    # client `space_id` straight into a query with no check), and it would
    # turn a malformed value into a crashed LiveView rather than a miss.
    case socket.assigns[:active_space] do
      %{id: space_id} when is_binary(space_id) ->
        # MULTI-SPACE from task 01a0740d stage 3. `search_canvases/3` always
        # took a LIST; this used to hand it `[space_id]` and so could only ever
        # find a canvas in the space you happened to be standing in — which is
        # the wrong shape for the question "where is that approval canvas".
        #
        # The cast-safety argument above is unchanged and still discharged:
        # every id in this list is DB-derived. `explorer_space_ids/1` reads
        # `:active_space` (a `Chat.get_space/1` row) and the ids of
        # `Chat.list_user_conversations/2` rows. None of it comes from `params`.
        # Widening the list did not widen the trust boundary.
        space_ids = explorer_space_ids(socket)

        results =
          if search_active?(query) do
            Chat.search_canvases(space_ids, query)
          else
            []
          end

        {:halt,
         socket
         |> assign(:canvas_search_query, query)
         |> assign(:canvas_search_results, results)
         # AFTER the results assign: the search groups are derived from it.
         |> maybe_refresh_explorer()
         # Re-read per keystroke rather than only on space entry: the backfill
         # runs while the drawer is open, so a line that was true at mount
         # would otherwise stay up for the whole session after the count hit
         # zero. `phx-debounce` bounds how often this runs.
         #
         # STILL SCOPED TO THE ACTIVE SPACE, while the search above is not.
         # Stated rather than left to be discovered: the search now spans every
         # space the viewer participates in, so an unindexed canvas in a
         # DIFFERENT space can make a phrase unfindable without lighting this
         # line. The error is one-directional — the line under-warns, it never
         # claims an index is incomplete when it is not — and widening it means
         # widening it at all three recompute points, one of which
         # (`load_for_space/2`) runs before `:active_space` exists and has only
         # the entered space id to hand. Left alone deliberately; it belongs
         # with the push-based refresh the block below already names as the real
         # fix.
         |> assign(:canvas_unindexed_count, CanvasSearchIndex.unindexed_count([space_id]))}

      _ ->
        {:halt,
         socket
         |> assign(:canvas_search_query, query)
         |> assign(:canvas_search_results, [])}
    end
  end

  defp handle_event("canvas_panel_toggle", _params, socket) do
    show? = !socket.assigns.show_canvases
    socket = assign(socket, :show_canvases, show?)

    # Refresh the partial-index count as the drawer OPENS (task 01a07402
    # stage 6). Before this it was read on space entry and then only by
    # `"canvas_search"`, which was survivable while the line rendered in
    # results mode alone — you could not see it without typing, and typing
    # refreshed it. The line now renders in list mode too, where nobody types,
    # so a backfill that finished mid-visit left the line lit for the rest of
    # the space visit.
    #
    # Only on the OPEN half: closing the drawer unrenders the line, so a count
    # taken there is a query whose answer is thrown away. Same argument for the
    # explorer's own three queries.
    {:halt,
     if(show?, do: socket |> refresh_unindexed_count() |> refresh_explorer(), else: socket)}
  end

  # ── The explorer's four events (task 01a0740d stage 3) ────────────────────

  # Group collapse is USER INTENT, held here and nowhere else, and it survives
  # every data refresh — see the note above `reset_explorer/1`. In search mode
  # the component ignores these keys entirely and opens on matches instead, so
  # a group the reader collapsed before searching does not hide a hit from them.
  defp handle_event("canvas_explorer_toggle_group", %{"key" => key}, socket)
       when is_binary(key) do
    keys = Map.get(socket.assigns, :canvas_expanded_keys, [])

    keys = if key in keys, do: List.delete(keys, key), else: [key | keys]

    {:halt, assign(socket, :canvas_expanded_keys, keys)}
  end

  # `phx-value-offset` arrives as a STRING off the wire and is parsed, not
  # trusted: `Integer.parse/1` on anything else leaves the offsets map alone.
  # A negative offset is refused rather than clamped — the component never emits
  # one, so a negative here means something other than the component sent it.
  defp handle_event("canvas_explorer_page", %{"key" => key, "offset" => offset}, socket)
       when is_binary(key) do
    case Integer.parse(to_string(offset)) do
      {parsed, ""} when parsed >= 0 ->
        offsets =
          socket.assigns
          |> Map.get(:canvas_explorer_offsets, %{})
          |> Map.put(key, parsed)

        {:halt, socket |> assign(:canvas_explorer_offsets, offsets) |> refresh_explorer()}

      _ ->
        {:halt, socket}
    end
  end

  # The strip's search icon asks for the field to be focused, and the field is
  # the DRAWER's — the explorer owns no search input. `:canvas_search_focus`
  # drives a mount-time `JS.focus` trigger in `Conversation.canvases_drawer/1`;
  # see the note there for why it is a mount and not a `push_event`.
  defp handle_event("canvas_explorer_expand", params, socket) do
    {:halt,
     socket
     |> assign(:canvas_explorer_collapsed, false)
     |> assign(:canvas_search_focus, params["focus"] == "search")}
  end

  defp handle_event("canvas_explorer_collapse", _params, socket) do
    {:halt,
     socket
     |> assign(:canvas_explorer_collapsed, true)
     # Cleared on the way out so the next search-icon expand re-mounts the
     # focus trigger. Left true, the trigger element stays in the DOM and
     # `phx-mounted` never fires a second time.
     |> assign(:canvas_search_focus, false)}
  end

  defp handle_event("canvas_close", _params, socket) do
    if canvas = socket.assigns.active_canvas do
      clear_canvas_engagement(socket, canvas)
    end

    {:halt, assign(socket, :active_canvas, nil)}
  end

  defp handle_event("canvas_open_mobile", params, socket) do
    canvas_id =
      Map.get(params, "canvas-id") ||
        case Map.get(params, "message-id") do
          nil ->
            nil

          mid ->
            case Chat.get_message(mid) do
              %{canvas_id: cid} when is_binary(cid) -> cid
              _ -> nil
            end
        end

    case canvas_id && find(socket, canvas_id) do
      nil ->
        {:halt, socket}

      %{} = canvas ->
        register_canvas_engagement(socket, canvas, :viewing)
        {:halt, assign(socket, :active_canvas, canvas)}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event(
         "canvas_action_click",
         %{"node-id" => node_id} = params,
         socket
       ) do
    canvas_id =
      params["canvas-id"] || (socket.assigns.active_canvas && socket.assigns.active_canvas.id)

    # Read the action value from `params["action"]` (post-Bug-B rename in
    # action_row.ex). Fall back to `params["value"]` for backward
    # compatibility with any external caller that still emits the old
    # phx-value-value key.
    value = Map.get(params, "action") || Map.get(params, "value") || ""

    if value == "" do
      # Empty value here means either (a) the source action's "value" is
      # missing/blank in the canvas document (data-shape problem — schema
      # requires it, so should not happen for validated docs), or (b) the
      # rendered attribute was clobbered before reaching the server (see
      # task 019f70ff Bug B — pre-fix, HTMLButtonElement.value clash in
      # LV's extractMeta stripped `phx-value-value` in every context). Log
      # in dev so any future regression surfaces instead of silently
      # flashing → "".
      Logger.warning(
        "[canvas_action_click] empty action value received — canvas=#{inspect(canvas_id)} node_id=#{inspect(node_id)}"
      )
    end

    with %{} = canvas <- find(socket, canvas_id) do
      # Broadcast the signal so agent-side subscribers (or the recent-events
      # panel) see every action click — even ones we handle inline below.
      CanvasServer.emit_event(canvas.id, %{
        "name" => "action",
        "node_id" => node_id,
        "value" => value
      })

      # Route recognized action values inline. Currently: meeting-triage
      # `junk_batch:<canvas_id>` — see `Platform.Meetings.Triage.junk_batch/2`.
      # Additional inline routes should land here as new triage-officer
      # affordances ship; unrecognized values fall through to the generic
      # emit-only behavior above.
      handle_canvas_action_value(value, canvas, socket)
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event(
         "canvas_form_submit",
         %{"node-id" => node_id, "form" => values} = params,
         socket
       ) do
    canvas_id =
      params["canvas-id"] || (socket.assigns.active_canvas && socket.assigns.active_canvas.id)

    with %{} = canvas <- find(socket, canvas_id) do
      CanvasServer.emit_event(canvas.id, %{
        "name" => "submitted",
        "node_id" => node_id,
        "values" => values
      })
    end

    {:halt, socket}
  end

  defp handle_event("canvas_node_focus", %{"node-id" => node_id} = params, socket) do
    canvas_id =
      params["canvas-id"] || (socket.assigns.active_canvas && socket.assigns.active_canvas.id)

    with %{} = canvas <- find(socket, canvas_id),
         %{current_participant: %{id: participant_id}} <- socket.assigns do
      Presence.set_canvas_engagement(self(), canvas.space_id, participant_id, %{
        canvas_id: canvas.id,
        engagement: :editing,
        focus_node_id: node_id
      })
    end

    {:halt, socket}
  end

  defp handle_event("canvas_versions_toggle", _params, socket) do
    if socket.assigns.show_versions_panel do
      {:halt,
       socket
       |> assign(:show_versions_panel, false)
       |> assign(:restore_confirm_revision, nil)}
    else
      versions = load_versions(socket.assigns.active_canvas)

      {:halt,
       socket
       |> assign(:show_versions_panel, true)
       |> assign(:canvas_versions, versions)
       |> assign(:restore_confirm_revision, nil)}
    end
  end

  defp handle_event("canvas_versions_close", _params, socket) do
    {:halt,
     socket
     |> assign(:show_versions_panel, false)
     |> assign(:restore_confirm_revision, nil)}
  end

  defp handle_event("canvas_versions_restore_prompt", %{"revision" => rev_str}, socket) do
    case Integer.parse(to_string(rev_str)) do
      {rev, ""} -> {:halt, assign(socket, :restore_confirm_revision, rev)}
      _ -> {:halt, socket}
    end
  end

  defp handle_event("canvas_versions_restore_cancel", _params, socket) do
    {:halt, assign(socket, :restore_confirm_revision, nil)}
  end

  defp handle_event("canvas_versions_restore_confirm", %{"revision" => rev_str}, socket) do
    canvas = socket.assigns.active_canvas

    # Restore is a full-document overwrite — the most destructive canvas write
    # there is — so it gates on WRITE, not on whatever let the viewer open the
    # panel. `find/2` admits `:task_reader` and `:org_reader`; neither may edit.
    with {rev, ""} <- Integer.parse(to_string(rev_str)),
         %{} <- canvas,
         {:ok, _writable} <- CanvasAccess.fetch_for_writer(canvas.id, viewer(socket)),
         %{} = version <- CanvasVersions.get(canvas.id, rev) do
      attribution = caller_attribution(socket, canvas.space_id)

      case CanvasServer.describe(canvas.id) do
        {:ok, %{revision: current_rev}} ->
          ops = [{:replace_document, version.document}]

          case CanvasServer.apply_patches(canvas.id, ops, current_rev, attribution) do
            {:ok, new_rev} ->
              # Re-tag the just-written ops to mark this as a restore (best
              # effort — async write may race; ignore failure).
              tag_restore_ops(canvas.id, new_rev, rev)

              versions = load_versions(canvas)

              {:halt,
               socket
               |> assign(:canvas_versions, versions)
               |> assign(:restore_confirm_revision, nil)
               |> put_flash(:info, "Restored revision #{rev} as v#{new_rev}.")}

            {:conflict, _} ->
              {:halt, put_flash(socket, :error, "Restore failed: canvas state changed.")}

            {:error, reason} ->
              {:halt, put_flash(socket, :error, "Restore failed: #{inspect(reason)}")}
          end

        _ ->
          {:halt, put_flash(socket, :error, "Could not load current canvas state.")}
      end
    else
      {:error, :forbidden} ->
        {:halt,
         put_flash(
           socket,
           :error,
           "You can view this canvas but not edit it. Restoring a revision needs edit access."
         )}

      _ ->
        {:halt, put_flash(socket, :error, "Restore failed: revision not found.")}
    end
  end

  # ── Canvas rooms (task 01a1316b-84fa stage 2) ─────────────────────────
  #
  # The `CanvasRoomBridge` hook relays a sealed frame's `window.suite` here.
  # canvas_id / node_id come from the hook element's data attributes (never
  # from the frame), and the ACTOR comes from this socket's session assigns:
  # any `actor` key in params is ignored. `:canvas_rooms` is keyed by
  # `{canvas_id, node_id}` and holds the room pid and its monitor, whether the
  # viewer may write, and the set of hook ids rendering it (one node can be
  # rendered twice in one LiveView: chat panel plus mobile overlay). Nothing
  # in a template reads it, so changing it does not re-render.
  defp handle_event(
         "canvas_room_join",
         %{"canvas_id" => canvas_id, "node_id" => node_id} = params,
         socket
       )
       when is_binary(canvas_id) and is_binary(node_id) do
    with {:ok, actor} <- room_actor(socket),
         {:ok, canvas, level} <- room_canvas(socket, canvas_id),
         :ok <- room_node(canvas, node_id),
         {:ok, snap} <- CanvasRoom.join(canvas.id, node_id, self(), actor) do
      socket =
        track_room(socket, {canvas.id, node_id}, hook_id(params), snap.room_pid, level == :member)

      {:halt,
       %{
         ok: true,
         seq: snap.seq,
         state: snap.state,
         presence: snap.presence,
         me: %{id: actor.id, display_name: actor.display_name},
         writable: level == :member
       }, socket}
    else
      {:error, code} -> {:halt, %{ok: false, error: to_string(code)}, socket}
    end
  end

  defp handle_event(
         "canvas_room_op",
         %{"canvas_id" => canvas_id, "node_id" => node_id, "op" => op},
         socket
       )
       when is_binary(canvas_id) and is_binary(node_id) and is_map(op) do
    reply =
      with %{writable: true} <- Map.get(socket.assigns.canvas_rooms, {canvas_id, node_id}),
           {:ok, actor} <- room_actor(socket),
           {:ok, %{seq: seq, result: result}} <-
             CanvasRoom.apply_op(canvas_id, node_id, actor, Map.take(op, @room_op_keys)) do
        %{ok: true, seq: seq, result: result}
      else
        %{writable: false} -> %{ok: false, error: "forbidden"}
        nil -> %{ok: false, error: "not_joined"}
        {:error, code} -> %{ok: false, error: to_string(code)}
      end

    {:halt, reply, socket}
  end

  defp handle_event(
         "canvas_room_ephemeral",
         %{"canvas_id" => canvas_id, "node_id" => node_id, "channel" => channel} = params,
         socket
       )
       when is_binary(canvas_id) and is_binary(node_id) and is_binary(channel) do
    with %{} <- Map.get(socket.assigns.canvas_rooms, {canvas_id, node_id}),
         {:ok, actor} <- room_actor(socket) do
      CanvasRoom.ephemeral(canvas_id, node_id, actor, channel, Map.get(params, "payload"))
    end

    {:halt, socket}
  end

  # A handler call (task 01a1316b-aab0 stage 2). The room runs the handler
  # off its own process and sends `{:canvas_room_call_result, req, result}`
  # back here, so this replies nothing: a handler can run for seconds. The
  # actor is this socket's session user, never a params value. A call is
  # held to EXACTLY the `canvas_room_op` rule, `writable: true` on the joined
  # entry (task 01a1316b-aab0 stage 4, finding F1): a handler's room ops land
  # under the caller's name, so a read-only viewer calling one would write
  # room state its own plain op is refused. The refusal is kind `forbidden`,
  # code `not_writable`, and is audited as a script_run by the room module.
  defp handle_event(
         "canvas_room_call",
         %{"canvas_id" => canvas_id, "node_id" => node_id, "name" => name} = params,
         socket
       )
       when is_binary(canvas_id) and is_binary(node_id) and is_binary(name) do
    req = %{
      canvas_id: canvas_id,
      node_id: node_id,
      hook_id: hook_id(params),
      req: call_req(params)
    }

    with %{writable: true} <- Map.get(socket.assigns.canvas_rooms, {canvas_id, node_id}),
         {:ok, actor} <- room_actor(socket) do
      CanvasRoom.call_handler(
        canvas_id,
        node_id,
        actor,
        name,
        Map.get(params, "args") || %{},
        {self(), req}
      )

      {:halt, socket}
    else
      %{writable: false} ->
        refuse_reader_call(socket, canvas_id, node_id, name, req)

      nil ->
        {:halt, push_call_result(socket, req, call_error("not_joined"))}

      {:error, code} ->
        {:halt, push_call_result(socket, req, call_error(to_string(code)))}
    end
  end

  defp handle_event(
         "canvas_room_leave",
         %{"canvas_id" => canvas_id, "node_id" => node_id} = params,
         socket
       )
       when is_binary(canvas_id) and is_binary(node_id) do
    {:halt, untrack_room(socket, {canvas_id, node_id}, hook_id(params))}
  end

  # A malformed room event is refused here rather than falling through to a
  # LiveView with no clause for it.
  defp handle_event("canvas_room_" <> _event, _params, socket),
    do: {:halt, %{ok: false, error: "invalid"}, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp hook_id(%{"hook_id" => id}) when is_binary(id) and byte_size(id) <= 256, do: id
  defp hook_id(_params), do: "default"

  # The writer is the signed-in user of THIS socket. The participant's
  # display name is preferred, as everywhere else in the space.
  defp room_actor(socket) do
    case current_user_id(socket) do
      id when is_binary(id) ->
        name =
          case socket.assigns do
            %{current_participant: %{display_name: n}} when is_binary(n) and n != "" -> n
            %{current_user_record: %{name: n}} when is_binary(n) -> n
            %{current_user: %{name: n}} when is_binary(n) -> n
            _ -> nil
          end

        {:ok, %{type: "user", id: id, display_name: name}}

      _ ->
        {:error, :forbidden}
    end
  end

  # `find/2` resolves canvases the viewer has no claim on (its KNOWN GAP), so
  # the room resolves through `CanvasAccess` instead: a read grant joins, and
  # only space participation (`:member`) writes.
  defp room_canvas(socket, canvas_id) do
    with true <- Platform.UUID.valid?(canvas_id),
         {:ok, %{deleted_at: nil} = canvas, level} <-
           CanvasAccess.fetch_for_viewer(canvas_id, viewer(socket), audit: false) do
      {:ok, canvas, level}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :not_found}
    end
  end

  # The live document first: `Canvas.Server` is ahead of the row during its
  # async persist, so a node added a moment ago is already joinable.
  defp room_node(canvas, node_id) do
    document =
      case CanvasServer.describe(canvas.id) do
        {:ok, %{document: document}} -> document
        _ -> canvas.document
      end

    if CanvasRoom.room_node?(CanvasDocument.get_node(document, node_id)),
      do: :ok,
      else: {:error, :not_a_room_node}
  end

  defp track_room(socket, key, hook_id, pid, writable) do
    rooms = socket.assigns.canvas_rooms

    entry =
      case Map.get(rooms, key) do
        nil ->
          {canvas_id, node_id} = key
          ChatPubSub.subscribe_canvas_room(canvas_id, node_id)
          %{pid: pid, ref: Process.monitor(pid), hooks: MapSet.new()}

        %{pid: ^pid} = entry ->
          entry

        %{ref: ref} = entry ->
          Process.demonitor(ref, [:flush])
          %{entry | pid: pid, ref: Process.monitor(pid)}
      end

    entry = entry |> Map.put(:writable, writable) |> Map.update!(:hooks, &MapSet.put(&1, hook_id))
    assign(socket, :canvas_rooms, Map.put(rooms, key, entry))
  end

  defp untrack_room(socket, {canvas_id, node_id} = key, hook_id) do
    rooms = socket.assigns.canvas_rooms

    case Map.get(rooms, key) do
      nil ->
        socket

      entry ->
        hooks = MapSet.delete(entry.hooks, hook_id)

        if MapSet.size(hooks) == 0 do
          Process.demonitor(entry.ref, [:flush])
          ChatPubSub.unsubscribe_canvas_room(canvas_id, node_id)
          CanvasRoom.leave(canvas_id, node_id, self())
          assign(socket, :canvas_rooms, Map.delete(rooms, key))
        else
          assign(socket, :canvas_rooms, Map.put(rooms, key, %{entry | hooks: hooks}))
        end
    end
  end

  defp room_event(canvas_id, node_id, kind), do: "canvas_room:#{canvas_id}:#{node_id}:#{kind}"

  defp call_req(%{"req" => req}) when is_binary(req) and byte_size(req) <= 128, do: req
  defp call_req(_params), do: nil

  defp call_error(code), do: {:error, %{kind: code, code: code, message: code}}

  defp refuse_reader_call(socket, canvas_id, node_id, name, req) do
    message = "a read-only viewer may not call this canvas's handlers"

    case room_actor(socket) do
      {:ok, actor} ->
        CanvasRoom.refuse_call(
          canvas_id,
          node_id,
          actor,
          name,
          "forbidden",
          "not_writable",
          message,
          {self(), req}
        )

        {:halt, socket}

      {:error, _} ->
        {:halt,
         push_call_result(
           socket,
           req,
           {:error, %{kind: "forbidden", code: "not_writable", message: message}}
         )}
    end
  end

  defp push_call_result(socket, req, result) do
    payload =
      case result do
        {:ok, %{seq: seq, applied: applied}} ->
          %{ok: true, result: %{seq: seq, applied: applied}, seq: seq}

        {:error, %{kind: kind, code: code, message: message}} ->
          %{ok: false, kind: kind, code: code, message: message}
      end

    push_event(
      socket,
      room_event(req.canvas_id, req.node_id, "call_result"),
      Map.merge(payload, %{req: req.req, hook_id: req.hook_id})
    )
  end

  defp tracked_room?(socket, canvas_id, node_id),
    do: Map.has_key?(Map.get(socket.assigns, :canvas_rooms, %{}), {canvas_id, node_id})

  # The room went down (stop/2, a crash, a kill). Rejoin, which starts a
  # fresh room from its last flush, and push the snapshot so every frame on
  # this page re-syncs without a reload.
  defp rejoin_room(socket, {canvas_id, node_id} = key, entry) do
    rooms = socket.assigns.canvas_rooms

    with {:ok, actor} <- room_actor(socket),
         {:ok, snap} <- CanvasRoom.join(canvas_id, node_id, self(), actor) do
      entry = %{entry | pid: snap.room_pid, ref: Process.monitor(snap.room_pid)}

      socket
      |> assign(:canvas_rooms, Map.put(rooms, key, entry))
      |> push_event(room_event(canvas_id, node_id, "snapshot"), %{
        seq: snap.seq,
        state: snap.state,
        presence: snap.presence,
        me: %{id: actor.id, display_name: actor.display_name},
        writable: entry.writable
      })
    else
      _ ->
        ChatPubSub.unsubscribe_canvas_room(canvas_id, node_id)
        assign(socket, :canvas_rooms, Map.delete(rooms, key))
    end
  end

  # `junk_batch:<canvas_id>` — opens the confirmation modal owned by
  # `PlatformWeb.ChatLive` (M5b/019f6e2c stage 4). M5a's Stage 5 shipped
  # a direct-fire path; the modal step now sits IN FRONT so we get a
  # human-facing preview count + an empty-batch guard before writing.
  # `Platform.Meetings.Triage.junk_batch/2` still runs — it fires when
  # the user clicks confirm in `ChatLive`'s `confirm_junk_batch` handler.
  #
  # Authorization runs HERE, at the intercept, so an unauthorized user
  # never sees the modal and can't craft a `confirm_junk_batch` bypass —
  # M5a's auth guard still lives in `authorize_junk_batch/2`.
  #
  # The `canvas_id` in the value is authoritative (the source-of-truth
  # canvas the tasks were filed FROM), which may differ from the canvas
  # currently rendered if the action_row is pinned into a sidebar view.
  defp handle_canvas_action_value("junk_batch:" <> value_canvas_id, canvas, socket) do
    target_canvas_id = if value_canvas_id == "", do: canvas.id, else: value_canvas_id

    case authorize_junk_batch(socket, canvas) do
      :ok ->
        case Platform.Meetings.Triage.preview_batch(target_canvas_id) do
          {:ok, %{surviving_task_count: count}} ->
            {:halt,
             socket
             |> assign(:show_junk_batch_modal, true)
             |> assign(:junk_batch_target, %{
               canvas_id: target_canvas_id,
               preview_count: count
             })}

          {:error, reason} ->
            Logger.warning(
              "junk_batch preview failed for canvas=#{target_canvas_id}: #{inspect(reason)}"
            )

            {:halt, put_flash(socket, :error, "Could not load batch preview.")}
        end

      :unauthorized ->
        {:halt,
         put_flash(
           socket,
           :error,
           "Only the meeting author or an admin can junk this batch."
         )}
    end
  end

  # Unrecognized action values: keep the generic emit-only contract.
  # Agent-side subscribers still see the click via the CanvasServer.emit_event
  # broadcast above.
  defp handle_canvas_action_value(_value, _canvas, socket), do: {:halt, socket}

  # Authorization for junk_batch: allow the source canvas's creator (by
  # participant id) OR any root-org admin. `current_user` may be
  # absent in test/system paths — in that case, admin check falls
  # through to false and only the participant path can succeed.
  defp authorize_junk_batch(socket, canvas) do
    cond do
      canvas_owner?(socket, canvas) -> :ok
      admin_user?(socket) -> :ok
      true -> :unauthorized
    end
  end

  defp canvas_owner?(socket, %{created_by: created_by}) when is_binary(created_by) do
    case socket.assigns do
      %{current_participant: %{id: participant_id}} when participant_id == created_by -> true
      _ -> false
    end
  end

  defp canvas_owner?(_socket, _canvas), do: false

  # Prefer the `:root_admin?` assign that `PlatformWeb.LiveAuth`'s
  # `:default` on_mount populates — it's a pure derivation on the
  # preloaded `:current_user_record` and avoids a per-click DB hit. Fall
  # back to a live `Tenancy.root_admin?/1` lookup for sockets that
  # didn't ride that on_mount chain (embedded mounts, tests that stub
  # in a bare user).
  defp admin_user?(socket) do
    case socket.assigns do
      %{root_admin?: true} ->
        true

      %{current_user_record: %{} = user} ->
        Platform.Tenancy.root_admin?(user)

      %{current_user: %{} = user} ->
        Platform.Tenancy.root_admin?(user)

      _ ->
        false
    end
  end

  defp current_user_id(socket) do
    case socket.assigns do
      %{current_user_record: %{id: id}} when is_binary(id) -> id
      %{current_user: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  # Both clauses gate on `MessagesHooks.same_active_space?/2` — the same guard,
  # from the same definition, that the message-broadcast handlers use. The
  # LiveView is subscribed to every channel in the workspace (intended: internal
  # staff can see channels across client orgs), so these clauses receive canvas
  # lifecycle events for spaces the viewer is not looking at. `put/2` merges the
  # canvas into `@canvases_by_id`, and `chat_message.ex` renders the whole
  # document inline for any `content_type == "canvas"` row whose canvas is in
  # that map. Guarding only `messages_hooks.ex` would leave the foreign canvas
  # sitting in that map and the bug half fixed.
  #
  # Strict on `space_id`, with the one consequence stated rather than
  # special-cased: a canvas the viewer has opened whose `space_id` differs from
  # the active space stops live-refreshing. The only route to that state is the
  # `find/2` gap (any viewer resolves any canvas by id, and `put/2` subscribes
  # the LiveView to foreign canvas topics on first sight), which has its own
  # ticket. An `active_canvas.id` exemption would harden a path we intend to
  # close, and it would only half work: `MessagesHooks` would still refuse to
  # reinsert the message row, so the canvas pane would update while the inline
  # card in the stream stayed frozen. Half-live is worse than not-live.
  defp handle_info({:canvas_created, canvas}, socket) do
    if MessagesHooks.same_active_space?(socket, canvas) do
      {:halt, put(socket, canvas)}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:canvas_updated, canvas}, socket) do
    if MessagesHooks.same_active_space?(socket, canvas) do
      socket = put(socket, canvas)

      socket =
        if socket.assigns[:show_versions_panel] && active_canvas_id(socket) == canvas.id do
          assign(socket, :canvas_versions, load_versions(canvas))
        else
          socket
        end

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:canvas_deleted, canvas}, socket), do: {:halt, remove(socket, canvas)}

  # Guarded on `MessagesHooks.same_active_space?/2`, the same check the two
  # clauses above carry, so all three canvas lifecycle handlers now admit only
  # the active space's canvases. `Chat.restore_canvas/1` broadcasts on the space
  # topic, and this session holds a space-topic subscription for every space on
  # its rail, so an unguarded clause hands `put/2` a foreign canvas. `put/2`
  # merges it into both `@canvases_by_id` and `@canvases`, and the Live Canvases
  # panel renders that second list with no message row involved.
  defp handle_info({:canvas_restored, canvas}, socket) do
    if MessagesHooks.same_active_space?(socket, canvas) do
      {:halt, put(socket, canvas)}
    else
      {:halt, socket}
    end
  end

  # Patch broadcast from `Canvas.Server.apply_patches/3,4` — fired on every
  # successful patch (checklist toggle, form save, embed update, etc.). Without
  # this clause the pane silently kept stale state until manual reload (the
  # eventual post-persist `:canvas_updated` broadcast is async + best-effort,
  # so the user can sit on stale content for an arbitrary delay).
  #
  # The in-memory `CanvasServer` state is always ahead of the DB during the
  # async persist window, so we merge the fresh document+revision from
  # `describe/1` onto the canvas row already in the socket — that way we never
  # race the persist tx, and we don't have to apply `operations` ourselves.
  #
  # No-op if the patched canvas isn't in this socket's list (e.g. cross-space
  # noise from a stale subscription, or the canvas was removed mid-flight).
  #
  # NOTE: viewer presence (`set_canvas_engagement(.., :viewing, ..)`) is
  # currently only registered by `canvas_open_mobile`; the desktop
  # `canvas_open` event in `ChatLive` calls `CanvasHooks.set_active/2` without
  # touching Presence, which is why `presence: viewing: []` is observed. That
  # is unrelated to patch live-update and belongs with the `canvas_open`
  # handler, not in this PubSub clause — not fixed here.
  defp handle_info({:canvas_patched, canvas_id, _new_revision, _operations}, socket) do
    canvases_by_id = Map.get(socket.assigns, :canvases_by_id, %{})

    socket =
      case Map.get(canvases_by_id, canvas_id) do
        nil ->
          socket

        %{} = existing ->
          case CanvasServer.describe(canvas_id) do
            {:ok, %{document: document}} ->
              put(socket, %{existing | document: document, updated_at: DateTime.utc_now()})

            _ ->
              # GenServer gone — fall back to a DB read, accepting that this
              # may briefly show the pre-patch document until persist lands.
              case Chat.get_canvas(canvas_id) do
                %{} = canvas -> put(socket, canvas)
                _ -> socket
              end
          end
      end

    {:halt, socket}
  end

  # Canvas kind emissions (action-row click, form submit, checklist toggle, …)
  # arrive here via `ChatPubSub.broadcast_canvas/2`. Events are signals — they
  # don't mutate the document. For user-visible feedback we flash a short
  # description + log; agent-runtime forwarding is a separate subscriber.
  defp handle_info({:canvas_event, canvas_id, event}, socket) when is_map(event) do
    Logger.debug("[canvas_event] canvas=#{canvas_id} #{inspect(event)}")

    {:halt,
     socket
     |> assign(:recent_canvas_events, prepend_event(socket, canvas_id, event))
     |> put_flash(:info, flash_for(event))}
  end

  # Room traffic is push_event ONLY: no assign changes, so a cursor stream
  # never re-renders the LiveView.
  defp handle_info({:canvas_room_diff, canvas_id, node_id, seq, diff, actor_id}, socket) do
    if tracked_room?(socket, canvas_id, node_id) do
      {:halt,
       push_event(socket, room_event(canvas_id, node_id, "diff"), %{
         seq: seq,
         diff: diff,
         actor: actor_id
       })}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:canvas_room_presence, canvas_id, node_id, list}, socket) do
    if tracked_room?(socket, canvas_id, node_id) do
      {:halt, push_event(socket, room_event(canvas_id, node_id, "presence"), %{presence: list})}
    else
      {:halt, socket}
    end
  end

  defp handle_info(
         {:canvas_room_ephemeral, canvas_id, node_id, channel, payload, actor_id},
         socket
       ) do
    own? = current_user_id(socket) == actor_id

    if tracked_room?(socket, canvas_id, node_id) and not own? do
      {:halt,
       push_event(socket, room_event(canvas_id, node_id, "ephemeral"), %{
         channel: channel,
         payload: payload,
         actor: actor_id
       })}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:canvas_room_timer, _canvas_id, _node_id, _name, _msg}, socket),
    do: {:halt, socket}

  # push_event only, like the rest of the room traffic.
  defp handle_info({:canvas_room_call_result, %{canvas_id: _} = req, result}, socket),
    do: {:halt, push_call_result(socket, req, result)}

  defp handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case Enum.find(Map.get(socket.assigns, :canvas_rooms, %{}), fn {_k, e} -> e.ref == ref end) do
      {key, entry} -> {:halt, rejoin_room(socket, key, entry)}
      nil -> {:cont, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  @recent_events_cap 20

  defp prepend_event(socket, canvas_id, event) do
    prior = Map.get(socket.assigns, :recent_canvas_events, [])

    entry = %{
      canvas_id: canvas_id,
      event: event,
      at: DateTime.utc_now()
    }

    [entry | prior] |> Enum.take(@recent_events_cap)
  end

  defp flash_for(%{"name" => "action", "node_id" => id, "value" => v}),
    do: "Canvas action: #{id} → #{inspect(v)}"

  defp flash_for(%{"name" => "submitted", "node_id" => id}),
    do: "Canvas form submitted: #{id}"

  defp flash_for(%{"name" => name}), do: "Canvas event: #{name}"
  defp flash_for(_), do: "Canvas event received"

  @doc "Human-readable summary of the canvas's root document kind."
  def humanize_kind(%{document: %{"root" => %{"type" => t}}}) when is_binary(t) do
    humanize_string(t)
  end

  def humanize_kind(_), do: "Canvas"

  @doc "Title for a canvas attached to a message (fallbacks through structured_content)."
  def message_canvas_title(message, canvases_by_id) do
    case Map.get(canvases_by_id, message.canvas_id) do
      %{title: title} when is_binary(title) and title != "" ->
        title

      _ ->
        get_in(message.structured_content || %{}, ["title"]) ||
          "Untitled Canvas"
    end
  end

  defp humanize_string(type) when is_binary(type) do
    type
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc "Summarize a canvas creation changeset for a flash message."
  def changeset_error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      replacements = Map.new(opts, fn {key, value} -> {to_string(key), value} end)

      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        replacements |> Map.get(key, key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  rescue
    _ -> "Please check the canvas fields and try again."
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp assign_new_form(socket, attrs \\ %{}) do
    # `kind` is the New canvas form's Blank/Prototype choice (task 01a1316b
    # stage 2); anything but "prototype" renders as Blank.
    params = %{
      "title" => Map.get(attrs, "title", ""),
      "kind" => Map.get(attrs, "kind", "blank")
    }

    assign(socket, :new_canvas_form, to_form(params, as: :canvas))
  end

  # Keyed by canvas.id so templates can look up via `msg.canvas_id`.
  # Replaces the old `canvases_by_message_id` (pre-ADR-0036) that used the
  # now-removed `chat_canvases.message_id` column.
  defp build_map(canvases) do
    Map.new(canvases, fn canvas -> {canvas.id, canvas} end)
  end

  # ── The partial-index count's refresh path (task 01a07402 stage 6,
  #    extended by task 01a078a1) ─────────────────────────────────────────
  #
  # `:canvas_unindexed_count` drives the "older canvases are still being
  # indexed" line in `Conversation.canvases_drawer/1`. It is recomputed at
  # exactly FOUR moments, and this is the list:
  #
  #   1. Space entry — `load_for_space/2`, inline, because `:active_space` is
  #      not assigned yet at that point and the id arrives as an argument.
  #   2. Drawer open via the toggle — the `"canvas_panel_toggle"` handler, via
  #      this function.
  #   3. Drawer open via `show_panel/1` — the OTHER open path, reached today
  #      only by `"canvas_create"` in `chat_live.ex`. Without this, creating a
  #      canvas while the drawer is closed opens it showing a count computed at
  #      the last space entry or toggle, stale in either direction.
  #   4. Each (300ms-debounced) search — the `"canvas_search"` handler.
  #
  # NOT in the render path, deliberately. `CanvasSearchIndex.unindexed_count/1`
  # is a `COUNT` over `chat_canvases` LEFT JOINed against `chat_canvas_search`;
  # `ChatLive` is the busiest LiveView in the app, so computing it while
  # rendering would run that query on every keystroke, every message stream
  # insert and every unrelated assign change, to keep one advisory line honest.
  #
  # WHAT IS THEREFORE STALE, stated rather than implied: a drawer left OPEN
  # while the backfill finishes underneath it keeps showing the line until the
  # reader types, closes and reopens the drawer, or re-enters the space. That
  # is accepted, for one reason — the single action a stale line could mislead
  # anyone about is searching and finding nothing, and searching is itself a
  # recompute point, so the line is corrected by the act it exists to qualify.
  # Nothing else in the drawer reads the count.
  #
  # The reverse staleness barely exists: a canvas created while the drawer is
  # open does not raise the count, because `Chat.create_canvas/1` writes the
  # index row in the SAME `Ecto.Multi` as the canvas row (`chat.ex`, and the
  # same for the update and restore writers). A count taken here goes out of
  # date by falling, not by rising, short of a direct database insert.
  #
  # A push-based refresh — the backfill broadcasting completion into the
  # space — is the real fix and belongs with the backfill, not here.
  defp refresh_unindexed_count(socket) do
    # `:active_space` only ever holds a `Chat.get_space/1` row (see the longer
    # note in the `"canvas_search"` handler); an id is never taken from event
    # params here. `unindexed_count/1` additionally filters through
    # `Platform.UUID.valid?/1`, so a malformed id folds into 0 rather than
    # raising `Ecto.Query.CastError` and taking the drawer down.
    case socket.assigns[:active_space] do
      %{id: space_id} when is_binary(space_id) ->
        assign(socket, :canvas_unindexed_count, CanvasSearchIndex.unindexed_count([space_id]))

      _ ->
        socket
    end
  end

  # ── The explorer's data (task 01a0740d stage 3) ───────────────────────────
  #
  # `refresh_explorer/1` is recomputed at exactly these points, and this is the
  # list:
  #
  #   1. Drawer open — `"canvas_panel_toggle"` and `show_panel/1`. Both, because
  #      a canvas message can open the panel without the toggle being clicked,
  #      and an explorer opened that way with stale groups would render the
  #      previous space's canvases.
  #   2. Each (300ms-debounced) search — the `"canvas_search"` handler, which
  #      must run it AFTER assigning `:canvas_search_results`, because the
  #      search groups are derived from those hits.
  #   3. Sort change — `"canvas_sort"`. The order is a QUERY option
  #      (`Chat.list_canvas_groups/2`'s `:order`), so a sort that did not
  #      re-query would reorder nothing.
  #   4. Paging — `"canvas_explorer_page"`.
  #   5. A canvas created, deleted or restored while the drawer is OPEN, via
  #      `maybe_refresh_explorer/1` from `put/2` and `remove/2`. Gated on
  #      `:show_canvases` so a busy space's canvas broadcasts do not run three
  #      queries each into a socket nobody is looking at.
  #
  # NOT in the render path, for the same reason `:canvas_unindexed_count` is
  # not: `ChatLive` is the busiest LiveView in the app and these are three
  # round trips.
  #
  # NOT in `load_for_space/2` either — see the note there.
  #
  # Group EXPANSION and page OFFSETS are deliberately not recomputed here; they
  # are user intent, held in `:canvas_expanded_keys` and
  # `:canvas_explorer_offsets`, and refreshing the data must not close a group
  # the reader opened. `reset_explorer/1` is the only thing that clears them,
  # and it runs on space entry, where they refer to spaces that may no longer
  # be listed.
  defp reset_explorer(socket) do
    socket
    |> assign(:canvas_groups, [])
    |> assign(:canvas_pinned_groups, [])
    |> assign(:canvas_parent_titles, %{})
    |> assign(:canvas_expanded_keys, [])
    |> assign(:canvas_explorer_offsets, %{})
    |> assign(:canvas_explorer_collapsed, false)
    |> assign(:canvas_archive_count, 0)
    |> assign(:canvas_search_focus, false)
  end

  defp maybe_refresh_explorer(socket) do
    if Map.get(socket.assigns, :show_canvases, false),
      do: refresh_explorer(socket),
      else: socket
  end

  defp refresh_explorer(socket) do
    space_ids = explorer_space_ids(socket)
    order = Map.get(socket.assigns, :canvas_sort, @default_sort)
    offsets = Map.get(socket.assigns, :canvas_explorer_offsets, %{})
    query = Map.get(socket.assigns, :canvas_search_query, "")

    # Browse groups are built in BOTH modes, and not wastefully: search mode
    # reads its space names and its `total_count` off them, and the header has
    # to read "3 of 41" against the space's real size rather than against the
    # number of matches. That is the whole reason stage 1 made `total_count` a
    # COUNT instead of `length(rows)`.
    browse_groups = explorer_browse_groups(space_ids, order, offsets)
    pinned = explorer_pinned_groups(socket, order)

    {groups, pinned} =
      if search_active?(query) do
        hits = Map.get(socket.assigns, :canvas_search_results, [])
        {explorer_search_groups(browse_groups, hits), explorer_pinned_matches(pinned, hits)}
      else
        {browse_groups, pinned}
      end

    socket
    |> assign(:canvas_groups, groups)
    |> assign(:canvas_pinned_groups, pinned)
    |> assign(:canvas_parent_titles, explorer_parent_titles(groups, pinned))
    # The strip's number is the ARCHIVE's size, so it comes off the browse
    # groups in both modes — a count that fell to 3 while a filter was set
    # would be describing the filter, and the strip is exactly where the
    # reader can no longer see that a filter exists.
    |> assign(:canvas_archive_count, Enum.reduce(browse_groups, 0, &(&2 + &1.total_count)))
  end

  # WHICH SPACES THE EXPLORER READS.
  #
  # `Chat.list_user_conversations/2` is the participant-row read: non-archived
  # spaces where this user is an active participant, every kind, with the
  # external scope applied. Deliberately NOT `Chat.list_spaces/1`, which is
  # workspace-wide for an internal user and only narrows for externals — using
  # it here would widen a per-space drawer into a workspace-wide canvas index
  # and put titles from spaces the viewer is not in on their screen.
  #
  # The active space is unioned in because a viewer can be READING a channel
  # without being a participant of it, and the drawer they have open must list
  # the canvases of the space they are standing in.
  #
  # Embedded mode gets the active space alone, matching what
  # `ChatLive.dm_conversations_for/3` already does for the rail: an embedded
  # pane is scoped to one conversation by construction and has no rail to
  # justify a cross-space list.
  defp explorer_space_ids(socket) do
    active =
      case socket.assigns[:active_space] do
        %{id: id} when is_binary(id) -> [id]
        _ -> []
      end

    participating =
      with false <- !!socket.assigns[:embedded],
           user_id when is_binary(user_id) <- socket.assigns[:user_id] do
        user_id
        |> Chat.list_user_conversations(scope: socket.assigns[:external_scope])
        |> Enum.map(& &1.id)
      else
        _ -> []
      end

    Enum.uniq(active ++ participating)
  end

  # One `list_canvas_groups/2` call for every space's first page. A group the
  # reader has PAGED gets one extra query for its own page, because the option
  # is a single `:offset` applied to every space and per-group offsets are the
  # point of a pager. Only paged groups pay for it, and only while they stay
  # paged.
  defp explorer_browse_groups(space_ids, order, offsets) do
    space_ids
    |> Chat.list_canvas_groups(limit: @canvas_explorer_page_size, order: order)
    |> Enum.map(fn group ->
      case Map.get(offsets, "space:" <> group.space_id, 0) do
        offset when offset > 0 -> explorer_paged_group(group, offset, order)
        _ -> Map.put(group, :offset, 0)
      end
    end)
  end

  defp explorer_paged_group(group, offset, order) do
    Chat.list_canvas_groups([group.space_id],
      limit: @canvas_explorer_page_size,
      offset: offset,
      order: order
    )
    |> case do
      # An offset past the end renders an empty group with no pager, which is a
      # dead end the reader cannot get out of — reachable by deleting canvases
      # while paged. Fall back to page one rather than stranding them.
      [%{rows: []}] -> Map.put(group, :offset, 0)
      [paged] -> Map.put(paged, :offset, offset)
      _ -> Map.put(group, :offset, 0)
    end
  end

  # Search mode keeps EVERY browse group and replaces its rows with that
  # space's matches — it does not drop the groups that missed. A group with no
  # match has to render, collapsed, reading "0 of 41": dropping it would make a
  # space that holds nothing matching indistinguishable from a space the viewer
  # is not in, and the explorer's whole claim is that you can see where you are
  # not looking. `:offset` is forced to 0 because a ranked result set is not
  # paged (the component renders no pager in search mode).
  defp explorer_search_groups(browse_groups, hits) do
    rows_by_space = hits |> Enum.map(&explorer_search_row/1) |> Enum.group_by(& &1.space_id)

    Enum.map(browse_groups, fn group ->
      rows = Map.get(rows_by_space, group.space_id, [])

      group
      |> Map.put(:rows, rows)
      |> Map.put(:matched_count, length(rows))
      |> Map.put(:offset, 0)
    end)
  end

  # A hit rebuilt as an explorer row. `hit.canvas` is a full `%Canvas{}` —
  # `document` node tree included — and this drops it: the explorer renders
  # titles, and the socket does not need 25 node trees to do that. `:snippet`
  # rides along because a body match whose title contains none of the query is
  # the one row nothing else on it can explain.
  defp explorer_search_row(hit) do
    canvas = hit.canvas

    %{
      id: canvas.id,
      title: canvas.title,
      space_id: canvas.space_id,
      updated_at: canvas.updated_at,
      inserted_at: canvas.inserted_at,
      created_by_display_name: canvas.created_by_display_name,
      cloned_from: canvas.cloned_from,
      snippet: hit.snippet
    }
  end

  # ── The two pinned groups ─────────────────────────────────────────────────
  #
  # Order is load-bearing and is this function's, not the component's: the
  # component renders `pinned_groups` verbatim in the order it is handed.
  defp explorer_pinned_groups(socket, order) do
    explorer_meeting_group(socket, order) ++ explorer_task_group(socket)
  end

  # "In this meeting". `Meetings.get_live_meeting_for_space/1` matches on
  # `chat_space_id == space_id`, so the meeting it returns is bound to the space
  # in hand and `chat_space_id` is that same id — the round trip through the
  # meeting is not redundant, it is the CONDITION: no live meeting, no group.
  # The group exists to say "these canvases are in play right now", which is
  # only true while a meeting is live.
  defp explorer_meeting_group(socket, order) do
    with %{id: space_id} when is_binary(space_id) <- socket.assigns[:active_space],
         %{chat_space_id: chat_space_id} when is_binary(chat_space_id) <-
           Meetings.get_live_meeting_for_space(space_id),
         [group] <-
           Chat.list_canvas_groups([chat_space_id],
             limit: @canvas_explorer_page_size,
             order: order
           ) do
      [
        %{
          key: "meeting",
          label: "In this meeting",
          rows: group.rows,
          total_count: group.total_count
        }
      ]
    else
      _ -> []
    end
  end

  # "On this task". The reverse of `Orchestration.ExecutionSpace.find_by_task_id/1`,
  # which resolves an execution space by `metadata->>'task_id'` — so going back
  # the other way is a plain string-keyed map read on a jsonb column, with no
  # query at all.
  defp explorer_task_group(socket) do
    with %{metadata: metadata} <- socket.assigns[:active_space],
         task_id when is_binary(task_id) <- Map.get(metadata || %{}, "task_id"),
         [_ | _] = rows <- explorer_task_rows(CanvasAttachments.list_task_canvases(task_id)) do
      [%{key: "task", label: "On this task", rows: rows, total_count: length(rows)}]
    else
      _ -> []
    end
  end

  # THE STALE ATTACHMENT ROW.
  #
  # `task_canvas_attachments.canvas_id` is a SOFT reference with no foreign
  # key, so soft-deleting a canvas leaves its attachment row behind and
  # `list_task_canvases/1` hands it over as `%{attachment: …, canvas: nil}`
  # (its own `canvas_envelope(%Canvas{deleted_at: %DateTime{}}), do: nil`
  # clause). It is not an error and it is not a ghost: it renders NO row and it
  # is not counted, so a task with three attachments and one deleted canvas
  # reads "2". The count comes from `length(rows)` AFTER this rejection, which
  # is what makes the two facts impossible to disagree — a count taken from
  # `length(entries)` would say 3 beside two rows.
  #
  # These rows are deliberately thin: `list_task_canvases/1` returns a
  # four-key envelope (`id`, `title`, `kind`, `deleted_at`) precisely so
  # callers do not drag the document graph around, so there is no
  # `updated_at`, `created_by_display_name` or `cloned_from` to give. The
  # explorer's row falls back to a title-only line for them rather than
  # inventing a recency it cannot know — every one of those readers is a
  # tolerant clause on the row map, not a required key.
  defp explorer_task_rows(entries) do
    entries
    |> Enum.map(&explorer_task_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp explorer_task_row(%{canvas: nil}), do: nil

  defp explorer_task_row(%{canvas: %{id: id} = canvas}) when is_binary(id) do
    %{id: id, title: canvas.title, space_id: nil}
  end

  defp explorer_task_row(_entry), do: nil

  # In search mode a pinned group is filtered to its matches, the same way a
  # space group is, so the component's "expand every group holding a match"
  # rule reaches them too and the header reads "1 of 3". Matching is by hit ID
  # rather than by re-running a query per group: the hits are already the
  # authoritative answer to "does this canvas match", and asking twice is how
  # two answers start to differ.
  defp explorer_pinned_matches(pinned, hits) do
    snippets = Map.new(hits, &{&1.canvas.id, &1.snippet})

    Enum.map(pinned, fn group ->
      rows =
        group.rows
        |> Enum.filter(&Map.has_key?(snippets, &1.id))
        |> Enum.map(&Map.put(&1, :snippet, Map.get(snippets, &1.id)))

      group
      |> Map.put(:rows, rows)
      |> Map.put(:matched_count, length(rows))
    end)
  end

  # ONE batched query for every `cloned_from` on screen, pinned rows included.
  # Resolving them per row is an N+1 that scales with the page, and the page is
  # the thing this ticket exists to bound.
  defp explorer_parent_titles(groups, pinned) do
    (groups ++ pinned)
    |> Enum.flat_map(& &1.rows)
    |> Enum.map(&Map.get(&1, :cloned_from))
    |> Enum.reject(&is_nil/1)
    |> Chat.canvas_parent_titles()
  end

  defp register_canvas_engagement(socket, canvas, engagement) do
    case socket.assigns do
      %{current_participant: %{id: participant_id}} ->
        Presence.set_canvas_engagement(self(), canvas.space_id, participant_id, %{
          canvas_id: canvas.id,
          engagement: engagement
        })

      _ ->
        :ok
    end
  end

  defp clear_canvas_engagement(socket, canvas) do
    case socket.assigns do
      %{current_participant: %{id: participant_id}} ->
        Presence.clear_canvas_engagement(self(), canvas.space_id, participant_id)

      _ ->
        :ok
    end
  end

  defp maybe_update_active(socket, canvas) do
    case socket.assigns.active_canvas do
      %{id: id} when id == canvas.id -> assign(socket, :active_canvas, canvas)
      _ -> socket
    end
  end

  # ── Version history (task 019e0ac0) ──────────────────────────────────────

  @doc false
  @spec load_versions(map() | nil) :: [map()]
  def load_versions(nil), do: []

  def load_versions(canvas) do
    canvas.id
    |> CanvasVersions.list_for_canvas(limit: 50)
    |> Enum.map(&decorate_version/1)
  end

  defp decorate_version(row) do
    written_by = row.written_by || %{}
    type = Map.get(written_by, "type") || "unknown"
    name = Map.get(written_by, "display_name") || "Unknown"

    %{
      revision: row.revision,
      written_at: row.written_at,
      relative_time: relative_time(row.written_at),
      author_name: name,
      author_type_badge: type_badge(type),
      author_badge_class: badge_class(type),
      op_summary: CanvasVersions.op_summary(row)
    }
  end

  defp type_badge("agent"), do: "AGENT"
  defp type_badge("user"), do: "USER"
  defp type_badge("federated"), do: "FED"
  defp type_badge("external"), do: "EXT"
  defp type_badge("system"), do: "SYS"
  defp type_badge(other) when is_binary(other), do: String.upcase(other)
  defp type_badge(_), do: nil

  defp badge_class("agent"), do: "bg-primary/20 text-primary"
  defp badge_class("user"), do: "bg-success/20 text-success"
  defp badge_class("federated"), do: "bg-info/20 text-info"
  defp badge_class("external"), do: "bg-warning/20 text-warning"
  defp badge_class(_), do: "bg-base-300 text-base-content/70"

  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end

  defp relative_time(_), do: ""

  defp active_canvas_id(socket) do
    case socket.assigns[:active_canvas] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp caller_attribution(socket, space_id) do
    case socket.assigns do
      %{current_participant: %{} = p} ->
        CanvasVersions.attribution_for_participant(p)

      %{current_user: %{id: uid} = u} ->
        CanvasVersions.attribution_from_fields(%{
          type: "user",
          id: uid,
          display_name: Map.get(u, :name) || Map.get(u, :email)
        })

      _ ->
        # Fall back to nothing — version row records system attribution.
        _ = space_id
        %{}
    end
  end

  # The version row is written async by Canvas.Server. Briefly poll for it
  # then update the ops field to reflect the restore intent. Best effort.
  #
  # Task 01a089e5 stage 3: was a bare `Task.start`. `canvas_versions_restore_confirm`
  # is exercised for real by LiveView tests under the shared DataCase sandbox
  # (chat_live_test.exs, canvas_versions_panel_test.exs), and the retry loop
  # below can still be polling up to ~520ms (26 * 20ms) after the triggering
  # test itself returns — exactly the outlive-the-checkin shape
  # `Task.Supervisor` + the shared-mode `on_exit` drain
  # (`Platform.SandboxHelpers.await_supervised_writes/1`) exists to catch.
  defp tag_restore_ops(canvas_id, revision, source_revision) do
    # `start_child`, not `async_nolink` — fire-and-forget, nothing awaits
    # this. See `WorkspaceBootstrap.boot_async/1`'s comment for why
    # `async_nolink`'s reply message is a real crash risk for a caller
    # with no catch-all `handle_info/2` (ChatLive itself has one, but this
    # follows the same convention as the other stage-3 conversions).
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      safe_tag_restore_ops(canvas_id, revision, source_revision, 0)
    end)
  end

  defp safe_tag_restore_ops(canvas_id, revision, source_revision, attempt) do
    do_tag_restore_ops(canvas_id, revision, source_revision, attempt)
  rescue
    DBConnection.OwnershipError ->
      Logger.debug(
        "[CanvasHooks] tag_restore_ops sandbox-owned DB call from Task.Supervised child — dropping canvas_id=#{canvas_id} revision=#{revision}"
      )

      :ok
  end

  defp do_tag_restore_ops(_canvas_id, _revision, _source_revision, attempt) when attempt > 25,
    do: :ok

  defp do_tag_restore_ops(canvas_id, revision, source_revision, attempt) do
    case CanvasVersions.get(canvas_id, revision) do
      nil ->
        Process.sleep(20)
        do_tag_restore_ops(canvas_id, revision, source_revision, attempt + 1)

      version ->
        version
        |> Ecto.Changeset.change(%{
          ops: %{"ops" => [["restore_from_revision", source_revision]]}
        })
        |> Platform.Repo.update()

        :ok
    end
  end
end
