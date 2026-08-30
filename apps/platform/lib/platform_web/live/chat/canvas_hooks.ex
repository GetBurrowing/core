defmodule PlatformWeb.ChatLive.CanvasHooks do
  @moduledoc """
  Lifecycle hook module for canvases in `PlatformWeb.ChatLive` (ADR 0036).

  Owns:

    * Assigns: `:canvases`, `:canvases_by_id`, `:active_canvas`,
      `:show_canvases`, `:new_canvas_form`
    * Events:  `"canvas_panel_toggle"`, `"canvas_close"`,
      `"canvas_open_mobile"`, `"canvas_patch"`, `"canvas_action_click"`,
      `"canvas_form_submit"`
    * Info:    `{:canvas_created, canvas}`, `{:canvas_updated, canvas}`

  Per-type LiveView event handlers (canvas_save_form, canvas_save_code,
  canvas_save_diagram, canvas_refresh_dashboard, canvas_sort) are removed.
  UI mutations flow through the generic `canvas_patch` event which applies a
  list of `CanvasPatch` operations.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Versions, as: CanvasVersions
  alias Platform.Chat.CanvasAccess
  alias Platform.Chat.Presence
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias PlatformWeb.ChatLive.MessagesHooks

  # Most-recently-edited first. `Chat.list_canvases/2` still defaults to
  # `:inserted_asc` for its other callers — the panel asks for what it wants
  # rather than changing the sequence the MCP tools already see.
  @default_sort :updated_desc

  # The allow-list IS the parse. `String.to_existing_atom/1` on a client-supplied
  # string would still admit any atom the VM happens to have loaded, which is
  # most of them; this admits exactly four and falls back to the default.
  @sorts %{
    "updated_desc" => :updated_desc,
    "inserted_desc" => :inserted_desc,
    "inserted_asc" => :inserted_asc,
    "title_asc" => :title_asc
  }

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
    |> assign(:recent_canvas_events, [])
    |> assign(:show_versions_panel, false)
    |> assign(:canvas_versions, [])
    |> assign(:restore_confirm_revision, nil)
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
  end

  @doc "Set the active canvas."
  @spec set_active(Phoenix.LiveView.Socket.t(), map() | nil) :: Phoenix.LiveView.Socket.t()
  def set_active(socket, canvas), do: assign(socket, :active_canvas, canvas)

  @doc "Show the canvases panel."
  @spec show_panel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def show_panel(socket), do: assign(socket, :show_canvases, true)

  @doc "Reset the new-canvas form."
  @spec reset_new_form(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def reset_new_form(socket, attrs \\ %{}), do: assign_new_form(socket, attrs)

  @doc """
  Find a canvas by id — DB first, then cached list.

  ## KNOWN GAP: this resolves canvases the viewer has no claim on

  Not fixed here. Deliberately left for the stage that owns canvas READ
  surfaces (task 019e2c4b stage 3/4), because closing it means deciding
  whether Fabrikam admins keep their current de-facto global canvas read — a
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
         |> assign(:canvases_by_id, build_map(canvases))}

      _ ->
        {:halt, assign(socket, :canvas_sort, sort)}
    end
  end

  defp handle_event("canvas_panel_toggle", _params, socket) do
    {:halt, assign(socket, :show_canvases, !socket.assigns.show_canvases)}
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

  defp handle_event(_event, _params, socket), do: {:cont, socket}

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
  # participant id) OR any Fabrikam root admin. `current_user` may be
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

  # Prefer the `:fabrikam_admin?` assign that `PlatformWeb.LiveAuth`'s
  # `:default` on_mount populates — it's a pure derivation on the
  # preloaded `:current_user_record` and avoids a per-click DB hit. Fall
  # back to a live `Tenancy.fabrikam_admin?/1` lookup for sockets that
  # didn't ride that on_mount chain (embedded mounts, tests that stub
  # in a bare user).
  defp admin_user?(socket) do
    case socket.assigns do
      %{fabrikam_admin?: true} ->
        true

      %{current_user_record: %{} = user} ->
        Platform.Tenancy.fabrikam_admin?(user)

      %{current_user: %{} = user} ->
        Platform.Tenancy.fabrikam_admin?(user)

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

  defp humanize_string(_), do: "Canvas"

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
    params = %{
      "title" => Map.get(attrs, "title", "")
    }

    assign(socket, :new_canvas_form, to_form(params, as: :canvas))
  end

  # Keyed by canvas.id so templates can look up via `msg.canvas_id`.
  # Replaces the old `canvases_by_message_id` (pre-ADR-0036) that used the
  # now-removed `chat_canvases.message_id` column.
  defp build_map(canvases) do
    Map.new(canvases, fn canvas -> {canvas.id, canvas} end)
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
  defp tag_restore_ops(canvas_id, revision, source_revision) do
    Task.start(fn -> do_tag_restore_ops(canvas_id, revision, source_revision, 0) end)
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
