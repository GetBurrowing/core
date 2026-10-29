defmodule PlatformWeb.Components.Canvases.PrototypeFrame do
  @moduledoc """
  The rendered body of a `prototype` canvas node (task 01a1316b-4e46 stage 2;
  `Platform.Chat.Canvas.Kinds.Prototype` renders this and nothing else), and
  of a `scripts: true` `embed` node with a well-formed `prototype_ref` (task
  01a18834 stage 1; `Platform.Chat.Canvas.Kinds.Embed` renders this for it).

  ## Sources

  `source/1` is the one place that reads the node: a `prototype` node shows
  `{prototype_id, version}` from its props (nil version = follow latest); a
  scripted embed shows `{ref.prototype_id, ref.version}` from its
  server-stamped `prototype_ref`, so it is "pinned" exactly when its ref is
  older than the canvas-owned prototype's latest version.

  ## Why a LiveComponent

  The bar needs the version number, timestamp, publisher list and the
  removed-by-retention flag. A function component re-runs on every canvas
  patch, so loading that in `render/1` would query per patch per node.
  `update/2` loads it through `Platform.Prototypes.frame_view/3` (three
  queries: the prototype, its versions, the publisher names) and only again
  when the node's `prototype_id` / `version` or the canvas changes.

  ## Layout (Saru's design direction, binding)

  One 40px bar above the frame and nothing at the sides or below: the title
  (`min-w-0 truncate`, gives way first), the pinned chip and the mono version
  stamp (`shrink-0 whitespace-nowrap`, never truncate), an Open icon button
  and a `...` menu. The bar is a CSS size container and the chip responds to
  the bar's width (`@sm:` / `@lg:`), not the viewport's: a canvas is often
  framed in a ~330px preview on a wide screen. The stamp opens the version list. Colour is spent only on
  exceptions: the info chip when an older version is pinned, and the base-200
  panel that replaces the frame for a version retention removed. The version
  list and the menu are a popover from `sm` up and a bottom sheet below it.

  ## Pin this version

  Pinning sets the node's `version` prop through `Platform.Chat.patch_canvas/3`
  with the `viewer` actor the host page threads in, so space membership is
  re-checked on the write. A host that passes no viewer (read-only surfaces)
  shows the list without the Pin buttons.

  A scripted embed has no `version` prop, and `ScriptedEmbeds.stamp/2`
  replaces any client-sent `prototype_ref` from the srcdoc's sha256. So its
  pin patches the node's `srcdoc` with the target version's HTML
  (`Prototypes.embed_html/2`); `Prototypes.publish_embed/1` finds the live
  version with that sha and re-stamps the ref to it, publishing nothing.

  ## Org scoping

  The canvas's space org is resolved here and handed to `frame_view/3`, which
  answers `:unavailable` for another org's prototype exactly as for an unknown
  id. No iframe is emitted in that case.
  """

  use PlatformWeb, :live_component

  alias Platform.Chat
  alias Platform.Chat.Canvas.Kinds.Prototype, as: Kind
  alias Platform.Chat.CanvasRoom
  alias Platform.Prototypes
  alias Platform.Prototypes.Settings

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: nil,
       fullscreen: false,
       load_key: nil,
       view: nil,
       pin_error: nil,
       retention_days: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    node = assigns.node
    props = node["props"] || %{}
    canvas_id = assigns[:canvas_id]
    {prototype_id, version} = source(node)
    key = {prototype_id, version, canvas_id}

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:node, node)
      |> assign(:props, props)
      |> assign(:canvas_id, canvas_id)
      |> assign(:viewer, assigns[:viewer])

    socket = if socket.assigns.load_key == key, do: socket, else: load(socket, key)
    {:ok, socket}
  end

  defp load(socket, {prototype_id, version, canvas_id} = key) do
    view =
      case Prototypes.frame_view(prototype_id, version, canvas_org_id(canvas_id)) do
        {:ok, view} -> view
        {:error, :unavailable} -> nil
      end

    retention_days =
      case view do
        %{state: :removed} -> Settings.get().retention_days
        _ -> nil
      end

    assign(socket,
      load_key: key,
      view: view,
      open: nil,
      pin_error: nil,
      retention_days: retention_days
    )
  end

  # The one reader of WHICH prototype version a node shows (see "Sources").
  defp source(%{"type" => "embed", "props" => %{"scripts" => true} = props}) do
    case props["prototype_ref"] do
      %{} = ref -> {ref["prototype_id"], ref["version"]}
      _ -> {nil, nil}
    end
  end

  defp source(node) do
    props = node["props"] || %{}
    {props["prototype_id"], props["version"]}
  end

  defp scripted_embed?(node),
    do: match?(%{"type" => "embed", "props" => %{"scripts" => true}}, node)

  defp canvas_org_id(canvas_id) do
    with %{space_id: space_id} <- Chat.get_canvas(canvas_id),
         %{org_id: org_id} <- Chat.get_space(space_id) do
      org_id
    else
      _ -> nil
    end
  end

  @impl true
  def handle_event("toggle", %{"panel" => panel}, socket) when panel in ~w(versions menu) do
    panel = String.to_existing_atom(panel)
    open = if socket.assigns.open == panel, do: nil, else: panel
    {:noreply, assign(socket, open: open, pin_error: nil)}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: nil)}

  # In-app fullscreen (iOS standalone PWA has no Fullscreen API for non-video
  # elements, and `target="_blank"` escapes to Safari with an address bar).
  # A class toggle on the existing tree, and the PrototypeFullscreen hook
  # promotes the root to the browser TOP LAYER (popover="manual") where no
  # native fullscreen is in effect. Promotion is a rendering change, not a
  # DOM move: an ancestor's transform/scale (the chat row's
  # `active:scale-[0.99]`, chat_message.ex) can no longer become the
  # overlay's containing block, and the iframe and its CanvasRoomBridge
  # element keep their browsing context. The render keeps every conditional
  # sibling after the keyed room element so morphdom never re-appends it.
  def handle_event("fullscreen", %{"on" => on}, socket) when on in ~w(true false),
    do: {:noreply, assign(socket, fullscreen: on == "true", open: nil)}

  def handle_event("pin", %{"version" => raw}, socket) do
    with {:user, _} = actor <- socket.assigns.viewer,
         {version, ""} <- Integer.parse(to_string(raw)),
         true <- live_version?(socket.assigns.view, version),
         {:ok, props} <- pin_props(socket.assigns.node, socket.assigns.view, version),
         %{} = canvas <- Chat.get_canvas(socket.assigns.canvas_id),
         {:ok, _canvas} <-
           Chat.patch_canvas(actor, canvas, [{:set_props, socket.assigns.node["id"], props}]) do
      # The patch re-renders the host, which hands this component the new node;
      # update/2 then reloads for the pinned version.
      {:noreply, assign(socket, open: nil)}
    else
      _ -> {:noreply, assign(socket, pin_error: "Could not pin that version.")}
    end
  end

  # A scripted embed is pinned by its HTML, never a `version` prop (see
  # "Pin this version").
  defp pin_props(node, view, version) do
    if scripted_embed?(node) do
      case Prototypes.embed_html(view.prototype.id, version) do
        {:ok, html} -> {:ok, %{"srcdoc" => html}}
        {:error, _} -> :error
      end
    else
      {:ok, %{"version" => version}}
    end
  end

  defp live_version?(%{versions: versions}, version),
    do: Enum.any?(versions, &(&1.version == version and not &1.removed?))

  defp live_version?(_, _), do: false

  @doc "The bar's version stamp: `v4 · 12 Oct 14:03Z`."
  @spec stamp(integer(), DateTime.t()) :: String.t()
  def stamp(version, %DateTime{} = at), do: "v#{version} · #{short_time(at)}"

  defp short_time(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %H:%MZ")

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <div
      id={@id}
      data-role="prototype-unavailable"
      class="rounded-xl border border-edge bg-base-200 px-4 py-6 text-center text-sm text-subtle"
    >
      This prototype is not available.
    </div>
    """
  end

  def render(assigns) do
    view = assigns.view
    props = assigns.props

    assigns =
      assigns
      |> assign(:url, Prototypes.url(view.prototype.id, view.shown))
      |> assign(:stamp, stamp(view.shown, view.shown_at))
      |> assign(:height, Kind.height(props))
      |> assign(:width, Kind.width(props))
      |> assign(:min_scale, Kind.min_scale(props))
      |> assign(:can_pin?, match?({:user, _}, assigns.viewer) and is_binary(assigns.canvas_id))
      |> assign(:title, title(assigns.node, view))

    ~H"""
    <div
      id={@id}
      phx-hook="PrototypeFullscreen"
      class={
        if @fullscreen,
          do: [
            "fixed inset-0 z-50 flex h-dvh flex-col bg-base-100 text-base-content",
            # UA popover resets: PrototypeFullscreen promotes this element to
            # the browser top layer with popover="manual", whose UA sheet
            # centres a fit-content box with a border, padding, overflow:auto
            # and CanvasText colour. Author classes beat the UA sheet, so
            # these keep the top-layer box identical to the overlay. The
            # safe-area longhands below still win over p-0 (Tailwind orders
            # the shorthand first; checked in the served app.css, stage 2).
            "m-0 w-dvw max-h-none max-w-none border-0 p-0 overflow-hidden",
            "pt-[env(safe-area-inset-top)] pr-[env(safe-area-inset-right)]",
            "pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)]"
          ],
          else: "relative rounded-xl border border-edge"
      }
      data-role="prototype-canvas"
      data-fullscreen={to_string(@fullscreen)}
      data-fullscreen-viewer={@fullscreen && "true"}
    >
      <%!-- The bar is its own size container (`@container`): every width
           rule below is keyed to the BAR, not the viewport. The inline
           preview (~330px) and the Live Canvas side panel (~350px) are that
           narrow on a 1280px screen, where viewport `sm:` rules had already
           expanded the chip to 426px of content and pushed Open and the menu
           off the card (member 2's review). --%>
      <div
        class={[
          "@container flex h-10 shrink-0 items-center gap-1.5 border-b border-edge bg-base-100 pl-3 pr-1 @sm:gap-2",
          !@fullscreen && "rounded-t-xl"
        ]}
        data-role="prototype-bar"
      >
        <p
          class="min-w-0 flex-1 truncate text-sm font-semibold text-base-content"
          data-role="prototype-title"
          title={@title}
        >
          {@title}
        </p>
        <%!-- By BAR width: from 32rem the full "v1 pinned · latest v4"; from
             24rem only "latest v4" (the stamp beside it already names the
             pinned version); below 24rem no chip at all, because the stamp
             plus Open and the menu are all a ~330px bar holds with any room
             left for the title. The stamp then carries the info colour, so
             the exception stays visible. --%>
        <.chip
          :if={@view.pinned?}
          tone="info"
          class="hidden shrink-0 whitespace-nowrap font-mono text-xs @sm:inline-flex"
          data-role="prototype-pinned-chip"
        >
          <span class="hidden @lg:inline">v{@view.shown} pinned · </span>latest v{@view.latest}
        </.chip>
        <button
          type="button"
          phx-click="toggle"
          phx-value-panel="versions"
          phx-target={@myself}
          aria-haspopup="dialog"
          aria-expanded={to_string(@open == :versions)}
          aria-label={stamp_label(@view)}
          class={[
            "inline-flex shrink-0 items-center gap-1 whitespace-nowrap rounded-field px-2 py-1 font-mono text-xs hover:bg-base-200",
            if(@view.pinned?, do: "text-info @sm:text-neutral", else: "text-neutral")
          ]}
          data-role="prototype-version-stamp"
        >
          {@stamp}<span class="hero-chevron-down size-3" aria-hidden="true"></span>
        </button>
        <button
          :if={@view.state != :removed}
          type="button"
          phx-click="fullscreen"
          phx-value-on={to_string(not @fullscreen)}
          phx-target={@myself}
          class="btn btn-ghost btn-sm btn-square shrink-0 rounded-field max-sm:min-h-[44px] max-sm:min-w-[44px]"
          aria-label={if @fullscreen, do: "Exit full screen", else: "Full screen"}
          title={if @fullscreen, do: "Close", else: "Full screen"}
          data-role={if @fullscreen, do: "prototype-fullscreen-close", else: "prototype-fullscreen"}
        >
          <span
            class={[if(@fullscreen, do: "hero-x-mark", else: "hero-arrows-pointing-out"), "size-4"]}
            aria-hidden="true"
          >
          </span>
        </button>
        <a
          href={Platform.Chat.LinkTargets.open_href(@url)}
          {Platform.Chat.LinkTargets.open_attrs(@url)}
          class="btn btn-ghost btn-sm btn-square shrink-0 rounded-field max-sm:hidden"
          aria-label="Open this version in a new tab"
          title="Open"
          data-role="prototype-open"
        >
          <span class="hero-arrow-top-right-on-square size-4" aria-hidden="true"></span>
        </a>
        <button
          type="button"
          phx-click="toggle"
          phx-value-panel="menu"
          phx-target={@myself}
          aria-haspopup="dialog"
          aria-expanded={to_string(@open == :menu)}
          aria-label="More"
          class="btn btn-ghost btn-sm btn-square shrink-0 rounded-field"
          data-role="prototype-menu-button"
        >
          <span class="hero-ellipsis-horizontal size-4" aria-hidden="true"></span>
        </button>
      </div>

      <%= if @view.state == :removed do %>
        <div
          class="flex flex-wrap items-center justify-center gap-3 rounded-b-xl bg-base-200 px-4 py-8 text-center text-sm text-base-content"
          data-role="prototype-removed"
        >
          <span>
            {removed_text(@retention_days)} Latest is v{@view.latest}.
          </span>
          <button
            :if={@can_pin?}
            type="button"
            phx-click="pin"
            phx-value-version={@view.latest}
            phx-target={@myself}
            class="btn btn-sm rounded-field"
          >
            View v{@view.latest}
          </button>
          <a
            :if={not @can_pin?}
            href={
              Platform.Chat.LinkTargets.open_href(Prototypes.url(@view.prototype.id, @view.latest))
            }
            {Platform.Chat.LinkTargets.open_attrs(Prototypes.url(@view.prototype.id, @view.latest))}
            class="btn btn-sm rounded-field"
          >
            View v{@view.latest}
          </a>
        </div>
      <% else %>
        <%!-- The room bridge (task 01a1316b-84fa stage 2) wraps the scale
             wrapper because an element carries one phx-hook. Its id carries
             the version too, so a pinned version mounts a fresh bridge on
             the fresh iframe. --%>
        <div
          id={"#{@id}-room-v#{@view.shown}"}
          class={
            @fullscreen &&
              [
                "min-h-0 flex-1",
                # The scale hook owns inline height/width/transform on its
                # (phx-update="ignore") wrapper and iframe; fill the screen
                # over them instead of fighting the hook.
                "[&>[data-role=prototype-frame]]:!h-full [&>[data-role=prototype-frame]]:!rounded-none",
                "[&_iframe]:!h-full [&_iframe]:!w-full [&_iframe]:![transform:none]"
              ]
          }
          {CanvasRoom.frame_attrs(@canvas_id, @node["id"])}
        >
          <%!-- The id carries the version: the wrapper is phx-update="ignore"
             (EmbedCanvasScale owns its inline styles), so a pinned version
             must replace the element rather than patch the iframe src. --%>
          <div
            id={"#{@id}-frame-v#{@view.shown}"}
            phx-hook="EmbedCanvasScale"
            phx-update="ignore"
            data-declared-width={@width}
            data-declared-height={@height}
            data-min-scale={@min_scale}
            class="relative overflow-hidden rounded-b-xl"
            style={"height: #{@height}px;"}
            data-role="prototype-frame"
          >
            <iframe
              src={@url}
              sandbox="allow-scripts"
              referrerpolicy="no-referrer"
              title={@title}
              style={"width: #{@width}px; height: #{@height}px; border: 0; display: block;"}
            >
            </iframe>
          </div>
        </div>
      <% end %>

      <%!-- Everything conditional sits AFTER the room element, never before
           it. The room element is keyed (it has an id) and its iframe is
           phx-update="ignore"; an unkeyed node inserted ahead of it makes
           morphdom detach and re-append it, which reloads the iframe and
           re-joins the canvas room. That is what happened on every enter
           and exit while the Escape listener below was the root's first
           child (#1236; measured in task 01a1389f stage 1: iframe loads
           1, 2, 3). The versions/menu panel and its backdrop were inserted
           there too; prototype_frame_test.exs pins the order. --%>
      <div
        :if={@fullscreen}
        phx-window-keydown="fullscreen"
        phx-value-on="false"
        phx-key="Escape"
        phx-target={@myself}
        data-role="prototype-fullscreen-escape"
      >
      </div>

      <button
        :if={@open}
        type="button"
        class="fixed inset-0 z-40 cursor-default bg-base-content/20 sm:bg-transparent"
        phx-click="close"
        phx-target={@myself}
        aria-label="Close"
      >
      </button>

      <div
        :if={@open}
        role="dialog"
        phx-target={@myself}
        phx-window-keydown="close"
        phx-key="Escape"
        data-role={"prototype-#{@open}-panel"}
        class={[
          "fixed inset-x-0 bottom-0 z-50 rounded-t-2xl border-t border-edge bg-base-100 p-3 shadow-lg",
          "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+0.75rem)]",
          "sm:absolute sm:inset-x-auto sm:bottom-auto sm:right-1 sm:top-11 sm:w-80 sm:rounded-xl sm:border sm:pb-3"
        ]}
      >
        <%= if @open == :versions do %>
          <p class="px-1 pb-2 text-xs font-semibold text-base-content">Versions</p>
          <ul class="max-h-72 space-y-0.5 overflow-y-auto">
            <li
              :for={v <- @view.versions}
              class={[
                "flex min-h-11 items-center gap-2 rounded-field px-2 py-1 font-mono text-xs sm:min-h-9",
                v.version == @view.shown && "bg-base-200"
              ]}
              data-role="prototype-version-row"
              data-version={v.version}
            >
              <span class="w-8 shrink-0 text-base-content">v{v.version}</span>
              <span class="shrink-0 whitespace-nowrap text-neutral">{short_time(v.inserted_at)}</span>
              <span class="min-w-0 flex-1 truncate font-sans text-neutral">{v.publisher}</span>
              <span :if={v.removed?} class="shrink-0 font-sans text-subtle">removed</span>
              <span
                :if={not v.removed? and v.version == @view.latest}
                class="shrink-0 font-sans text-subtle"
              >
                latest
              </span>
              <button
                :if={@can_pin? and not v.removed? and v.version != @view.shown}
                type="button"
                phx-click="pin"
                phx-value-version={v.version}
                phx-target={@myself}
                class="btn btn-ghost btn-xs shrink-0 rounded-field font-sans"
                data-role="prototype-pin"
              >
                Pin this version
              </button>
            </li>
          </ul>
          <p :if={@pin_error} class="px-1 pt-2 text-xs text-error" role="alert">{@pin_error}</p>
        <% else %>
          <p class="flex items-center gap-2 px-1 py-1 text-sm text-base-content">
            <span class="hero-lock-closed size-4 shrink-0 text-neutral" aria-hidden="true"></span>
            Sealed: no network, no Burrow access
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # A canvas-owned prototype's stored name is `Canvas embed <node_id>`.
  defp title(node, view),
    do: if(scripted_embed?(node), do: "Scripted embed", else: view.prototype.name)

  defp stamp_label(%{pinned?: true, shown: shown, latest: latest}),
    do: "Version #{shown}, pinned (latest is v#{latest}), show versions"

  defp stamp_label(%{shown: shown}), do: "Version #{shown}, show versions"

  defp removed_text(days) when is_integer(days),
    do: "This version was removed after #{days} days."

  defp removed_text(_), do: "This version was removed."
end
