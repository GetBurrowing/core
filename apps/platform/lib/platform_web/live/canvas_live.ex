defmodule PlatformWeb.CanvasLive do
  @moduledoc """
  The standalone canvas page — `/canvases/:id` (task 019e2c4b, stage 3).

  A full-page, read-only view of a single canvas for someone who arrived by
  clicking a link rather than by being in the space: a human in another
  channel, a reviewer following an agent's citation, the first human reader of
  an agent-authored deliverable. Its one job is to show the document
  immediately and say where it came from.

  ## Citation parity is the whole point

  The body delegates to `PlatformWeb.Chat.CanvasRenderer.canvas_document/1`,
  which is the same component the chat pane and the task sheet already call.
  `Platform.Chat.Canvas.Renderer.render_node/1` is not touched and gets no
  `read_only` attr. An agent that writes "the table has five rows and two open
  actions" and a human who follows the link must be looking at the same
  document, so this page adds chrome around the renderer and never forks it.

  ## Chrome: one band of tint, then nothing between the viewer and the document

  A sticky provenance bar on `--color-base-200` with a single
  `--color-base-300` hairline is the only tinted band on the page, so the bar
  reads as chrome and everything below it reads as document. The content
  column sits directly on `--color-base-100` at `max-w-[880px]` — no card and
  no grey backdrop, because card-on-grey reads as an embedded preview of
  something that lives elsewhere, which is the wrong message for a page whose
  job is to make a shared canvas feel first-class.

  The in-chat `"Live Canvas"` label deliberately does not come along. Inside
  chat it distinguishes the pane from the message list; standalone it is noise
  above the only thing on the page.

  ## Every state has a way out

  The bar's rightmost control is a close `(x)`, and both denial states carry a
  ghost link back to Suite. A pasted link opened in a fresh tab has no back
  history, so a page with no exit is a dead end. Where the `(x)` goes depends
  on the grant the viewer resolved: see `assign_close_path/3`.

  ## Authorization

  `Platform.Chat.CanvasAccess.fetch_for_viewer/3` (stage 1) is the only gate.
  It is the ONLY read path: no branch here ever renders a document that
  `fetch_for_viewer/3` did not hand over.

  Both denial outcomes are carried through to the template as `@load_error`
  (`:forbidden` / `:not_found`), which stage 4 renders as two structurally
  different surfaces.

  ## The one deliberate disclosure: 403 denial context (stage 4)

  A 403 says "ask <owner> for access", so it has to know who the owner is —
  and `fetch_for_viewer/3` returns a bare `{:error, :forbidden}` by design.
  `assign_denial_context/4` therefore re-reads the row through
  `Platform.Chat.get_canvas/2`, the deliberately unauthorized primitive, AFTER
  the gate has already denied.

  Exactly two facts leave that struct, and no document node ever does:

    * the creator's display name, from the ADR-0038 snapshot on the canvas row.
      Naming the owner is the whole point of the state: a door, not a wall.
    * the parent space, and only to a viewer who is a member of that space's
      org. Everyone else is told "a space in Fabrikam", so the denial page cannot
      be walked as a space directory.

  The existence oracle this creates is the tradeoff the plan already accepted
  for AC #3, and canvas ids are UUIDv7, so it yields little.

  ## Auditing exactly once per page load

  `fetch_for_viewer/3` emits `[:platform, :chat, :canvas_read]` for
  `:task_reader` / `:org_reader` resolutions, and takes `audit: false` so a
  LiveView does not mint a row per socket.

  We audit on the DISCONNECTED mount only (`connected?(socket) == false`). A
  full page load runs the static HTTP render exactly once and then connects;
  a websocket reconnect re-runs only the connected mount. So this yields one
  audit row per human arrival and none per reconnect, with no session
  bookkeeping to keep in sync.

  This is also why the route needs its own `live_session`: crossing that
  boundary forces a full HTTP round-trip, so every arrival here is a
  disconnected mount followed by a connected one. See the router comment for
  the security half of that reasoning (`:enforce_external_scope` is an HTTP
  plug and a `live_redirect` inside one `live_session` never re-enters the
  plug pipeline).

  ## Read-only, including the events

  `action_row` renders `phx-click="canvas_action_click"` and `form` renders
  `phx-submit="canvas_form_submit"`. There are no write `handle_event/3`
  clauses here and there will not be any — but "no clause at all" means a
  stray click crashes the LiveView process and bounces the reader through a
  reconnect. The two clauses below are explicit, named no-ops, not writes.

  The matching visual half is the `.canvas-inert` wrapper class in
  `assets/css/app.css` (stage 4). Look is CSS, behaviour is the missing
  clauses; neither half forks `render_node/1`.

  The one exception is a `game_stream` node (task 01a0db5f), whose events
  are handled by the live hooks its extension registers, attached in
  `mount/3` through `PlatformWeb.Extensions.attach_live_hooks/1`: a
  playable build has to be playable from its link. Those events drive a play
  session, and the only document write among them, "Start again" setting the
  node's new `session_id`, goes through `Platform.Chat.patch_canvas/3` and so
  needs space membership. A read grant can play and end a session. It cannot
  write the canvas.
  """
  use PlatformWeb, :live_view

  alias Platform.Chat
  alias Platform.Chat.CanvasAccess
  alias Platform.Chat.CanvasDocument
  alias Platform.Tenancy
  alias PlatformWeb.ChatLive
  alias PlatformWeb.Components.ChatHelpers
  alias PlatformWeb.Extensions

  @impl true
  def mount(%{"id" => canvas_id}, _session, socket) do
    viewer = viewer_actor(socket)
    # Extension kinds' events (e.g. a `game_stream` node's, task 01a0db5f
    # stage 4; ADR 0055). See the moduledoc's read-only section.
    socket = Extensions.attach_live_hooks(socket)

    # `audit: false` on the connected mount — see the moduledoc. The
    # disconnected render already recorded this arrival.
    opts = [audit: not connected?(socket)]

    case CanvasAccess.fetch_for_viewer(canvas_id, viewer, opts) do
      {:ok, canvas, level} ->
        # One read of the parent space feeds both the crumb and the close
        # destination. It was already loaded for the crumb; the exit reuses it
        # rather than issuing a second query for the same row.
        space = canvas.space_id && Chat.get_space(canvas.space_id)

        {:ok,
         socket
         |> assign(:canvas, canvas)
         |> assign(:access_level, level)
         |> assign(:load_error, nil)
         |> assign(:page_title, canvas.title || "Canvas")
         |> assign(:canvas_url, canvas_url(canvas.id))
         |> assign(:revision, CanvasDocument.revision(canvas.document))
         |> assign_provenance(canvas, space)
         |> assign_close_path(space, level)}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:ok,
         socket
         |> assign(:canvas, nil)
         |> assign(:access_level, nil)
         |> assign(:load_error, reason)
         |> assign(:page_title, "Canvas")
         |> assign(:canvas_url, nil)
         |> assign(:revision, nil)
         |> assign(:org_name, nil)
         |> assign(:space_name, nil)
         |> assign(:author_name, nil)
         |> assign_denial_context(reason, canvas_id, viewer)}
    end
  end

  # A route without an `:id` cannot match, so this clause exists only to keep
  # `mount/3` total against a hand-built socket in tests.
  def mount(_params, _session, socket), do: mount(%{"id" => ""}, %{}, socket)

  @impl true
  def handle_event(event, _params, socket)
      when event in ["canvas_action_click", "canvas_form_submit"] do
    # Read-only surface. Interactive canvas nodes stay rendered for citation
    # parity, so their events still reach us; they resolve to nothing here.
    {:noreply, socket}
  end

  # ── Denial context (stage 4) ──────────────────────────────────────────────

  # What a viewer outside the space's org is told instead of its name. The
  # denial page names a real place only to someone who already has standing in
  # that org; to everyone else it stays a generic statement so the page cannot
  # be walked as a directory of spaces.
  @generic_place "a space in Fabrikam"

  # The 403 still offers one action when the creator snapshot is empty, which
  # is the case for canvases written before ADR-0038 landed.
  @unknown_owner "the owner"

  # 404 carries no context by construction. There is nothing to be the owner
  # OF, and inventing a place name would be the existence oracle the 404 state
  # exists to avoid.
  defp assign_denial_context(socket, :not_found, _canvas_id, _viewer) do
    socket
    |> assign(:denial_owner, nil)
    |> assign(:denial_place, nil)
  end

  defp assign_denial_context(socket, :forbidden, canvas_id, viewer) do
    # `get_canvas/2` filters soft-deleted rows, and `fetch_for_viewer/3` only
    # returns `:forbidden` for a live canvas, so this resolves. A `nil` here
    # would mean the row was deleted between the two reads; the fallbacks below
    # then degrade to the generic copy rather than raising on a race.
    canvas = Chat.get_canvas(canvas_id)
    space = canvas && canvas.space_id && Chat.get_space(canvas.space_id)

    socket
    |> assign(:denial_owner, owner_label(canvas))
    |> assign(:denial_place, place_label(space, viewer))
  end

  defp owner_label(%{created_by_display_name: name}) when is_binary(name) do
    if blank?(name), do: @unknown_owner, else: name
  end

  defp owner_label(_canvas), do: @unknown_owner

  # Strict `member_of?/2`, not `fabrikam_admin?/1`: the question this answers is
  # "does the viewer already have standing where this canvas lives", and a
  # root-org admin badge is not standing in a sibling org.
  defp place_label(%{org_id: org_id, name: name}, {:user, user_id})
       when is_binary(org_id) and is_binary(user_id) do
    if Tenancy.member_of?(%{id: user_id}, org_id) do
      org = Tenancy.get_org(org_id)

      [org && org.name, name]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" › ")
      |> case do
        "" -> @generic_place
        crumb -> crumb
      end
    else
      @generic_place
    end
  end

  defp place_label(_space, _viewer), do: @generic_place

  # ── Provenance ────────────────────────────────────────────────────────────

  # `org > space - author - updated`. The org and space come from the parent
  # space row; the author comes from the ADR-0038 creator snapshot already on
  # the canvas, so rendering the crumb costs no join against `participants`
  # and survives a participant row being removed.
  defp assign_provenance(socket, canvas, space) do
    org = space && space.org_id && Tenancy.get_org(space.org_id)

    socket
    |> assign(:org_name, org && org.name)
    |> assign(:space_name, space && space.name)
    |> assign(:author_name, canvas.created_by_display_name)
  end

  @doc """
  The crumb string, assembled from whichever parts resolved.

  Segments that could not be resolved are dropped rather than rendered as a
  placeholder: a crumb reading `"— > — · —"` tells a cold arrival less than a
  shorter crumb does.
  """
  def provenance_crumb(assigns) do
    place =
      [assigns[:org_name], assigns[:space_name]]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" › ")

    [place, assigns[:author_name], updated_label(assigns[:canvas])]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  # ── The way out ───────────────────────────────────────────────────────────
  #
  # Stage 3's provenance bar had no exit. Someone opening a pasted link in a
  # fresh tab has no back history and no route anywhere, which turns the page
  # into a dead end. The `(x)` is the fix, and where it goes depends on the
  # grant the viewer already resolved:
  #
  #   * `:member` lands in the conversation the canvas lives in. For a member,
  #     "out of the document" and "into its space" are the same place, so the
  #     exit turns a dead-end read into an entry point.
  #
  #   * `:task_reader` and `:org_reader` land at `/chat`. Routing them at the
  #     parent space would be a second denial: a task_reader on an
  #     execution-space canvas cannot enter that space at all.
  #
  # `ChatLive.space_nav_target/1` rather than a hand-built slug — org-scoped
  # spaces address by id there, and a second rule for building the same URL is
  # a second rule to keep in sync.
  defp assign_close_path(socket, %{} = space, :member),
    do: assign(socket, :close_path, ~p"/chat/#{ChatLive.space_nav_target(space)}")

  defp assign_close_path(socket, _space, _level), do: assign(socket, :close_path, ~p"/chat")

  defp updated_label(%{updated_at: %DateTime{} = at}), do: "updated #{relative(at)}"
  defp updated_label(_), do: nil

  defp relative(at), do: ChatHelpers.relative_time(at)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  # ── Viewer + URL ──────────────────────────────────────────────────────────

  # `ShellLive` assigns the raw id. `CanvasAccess` takes the repo's standard
  # actor triple; an unauthenticated socket normalises to `nil` there and
  # holds no grant.
  defp viewer_actor(socket) do
    case socket.assigns[:current_user_id] do
      id when is_binary(id) -> {:user, id}
      _ -> nil
    end
  end

  @doc """
  Absolute URL for a canvas — the string the copy-link control puts on the
  clipboard.

  Delegates to `Platform.Chat.Canvas.Links.view_url/1`, which stage 5 made the
  single builder: the canvas MCP tools return that exact string as `view_url`,
  so the page and the tool surface cannot disagree about the route. It is
  deliberately the canonical form and never a token form, so a copied link can
  never silently be a bearer credential.
  """
  defdelegate canvas_url(canvas_id), to: Platform.Chat.Canvas.Links, as: :view_url
end
