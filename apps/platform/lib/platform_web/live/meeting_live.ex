defmodule PlatformWeb.MeetingLive do
  @moduledoc """
  Meetings module — staged collaboration surface (ADR 0042).

  This LiveView ships the layout shell for the meeting surface plus
  this stack member's deliverable: the **embedded chat panel** that
  acts as a placeholder for the future intent panel.

  ## Embedding choice (stage 1 contract: "Pick embedding strategy")

  Stage 1 enumerated:
    (a) reuse a `<.chat_panel space_id={...} />` style component if one
        exists; or
    (b) nest `PlatformWeb.ChatLive` via `live_render` with the meeting's
        chat space slug.

  Choice: **(b), with a meeting-owned nested LiveView**.

  No `<.chat_panel>` carve-out exists in `chat_live.html.heex` (1243
  lines, monolithic) and ChatLive itself (874 lines) reads `space_slug`
  from URL params + does push_navigate-on-empty-slug. Teaching it to
  bootstrap from session would leak meeting concerns into the chat
  surface and complicate its already-busy lifecycle.

  Instead we ship `PlatformWeb.MeetingChatPanelLive` — a small
  meeting-owned LiveView nested via:

      <%= live_render(@socket, PlatformWeb.MeetingChatPanelLive,
            id: "meeting-chat-panel-\#{@meeting.id}",
            session: %{"chat_space_slug" => @meeting.chat_space.slug}) %>

  This satisfies the "live_render + chat space slug" rationale of
  option (b) without contaminating ChatLive. When the real intent
  panel ships, `MeetingChatPanelLive` is replaced wholesale; the
  greppable `data-intent-panel-host="true"` attribute on the panel
  root marks the surface for that migration.

  ## Layout

    * Top bar: meeting name + 4-button stage-mode segmented control
      STUB (sibling task 019e2474-bc7c wires the switching).
    * Left rail (~240px): PLACEHOLDER slot for sibling 019e2475-4395's
      sectioned participant list.
    * Center stage (flex-1): PLACEHOLDER slot for sibling 019e2474-bc7c's
      stage renderers.
    * Bottom strip (~120px): PLACEHOLDER slot for sibling 019e2475-0037's
      video tiles.
    * Right pane (this stack member): the embedded chat panel via
      `MeetingChatPanelLive`. Stage 2 of THIS task adds the right-pane
      framing (~320px on desktop, header label "Discussion · placeholder
      for intent panel (ADR 0042)") and stage 3 adds the mobile drawer
      toggle.

  Stage 1 ships the embed itself (chat panel reachable + interactive
  on desktop) — the polished framing/drawer come in 2/3.

  ## Mobile drawer (stage 3)

  The right pane has two presentations:

    * `>=lg` (desktop): always-visible right column. The desktop column
      is rendered with `hidden lg:flex` and **does not consult the
      `:chat_panel_open` assign**, so the panel is never collapsed on
      desktop regardless of assign state.
    * `<lg` (mobile/tablet): a slide-in drawer from the right with a
      backdrop. The drawer reads `:chat_panel_open` and is hidden by
      default (assign defaults to `false`).

  The toggle button (`hero-chat-bubble-left-right` in the top bar) is
  `lg:hidden` so it only shows where it does anything — on mobile.
  Backdrop click also dispatches `toggle_chat_panel` to close.

  Note on the assign default: the stack-member spec says "assign
  defaults to true on mount but the layout uses a media-query class so
  the desktop-side never collapses" — but it ALSO says "default CLOSED
  on mobile". With one assign driving both, those are mutually
  exclusive. We resolve in favour of the user-visible behaviour
  ("default CLOSED on mobile") by defaulting `:chat_panel_open` to
  `false` and making the desktop column ignore the assign entirely. The
  semantic ("desktop is open by default") is preserved by CSS.

  ## Routes

    * `/meetings`         — `:index` action. Lightweight placeholder
      index so the sidebar nav link resolves.
    * `/meetings/:slug`   — `:show` action. The meeting shell.

  ## Mount + assigns (`:show`)

    * `:meeting` — the `%Platform.Meetings.Meeting{}` loaded by slug,
      with `:chat_space` preloaded (the panel needs the chat space's
      `slug` to drive `live_render`).
    * `:current_stage_mode` — one of `:canvas`, `:screen`, `:gallery`,
      `:whiteboard` (see `stage_modes/0`), default `:canvas`. Sibling
      019e2474-bc7c owns the switching event.
  """
  use PlatformWeb, :live_view

  alias Platform.Meetings

  # Stage modes per ADR 0042's "Stage modes" table. Canvas is the default
  # (meetings are often artifact-driven). Sibling 019e2474-bc7c owns
  # switching.
  @stage_modes [:canvas, :screen, :gallery, :whiteboard]

  @doc "Stage modes the segmented control exposes (ADR 0042)."
  def stage_modes, do: @stage_modes

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:stage_modes, @stage_modes)
     # Mobile drawer state — defaults CLOSED. Desktop ignores this
     # assign (column is `hidden lg:flex`). See @moduledoc for the
     # reconciliation against the stack-spec's "defaults to true" line.
     |> assign(:chat_panel_open, false)}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _url, socket) do
    case Meetings.get_meeting_by_slug(slug) do
      nil ->
        # Clean not-found path — no MatchError / Ecto.NoResultsError
        # bubbles.
        {:noreply,
         socket
         |> put_flash(:error, "Meeting not found.")
         |> push_navigate(to: ~p"/meetings")}

      meeting ->
        {:noreply,
         socket
         |> assign(:page_title, "Meeting · #{meeting.name}")
         |> assign(:meeting, meeting)
         |> assign(:current_stage_mode, :canvas)}
    end
  end

  def handle_params(_params, _url, socket) do
    # `:index` action — lightweight placeholder. The real meetings index
    # (list / create) is out of scope for this task; the sidebar nav
    # link points here so it resolves cleanly.
    {:noreply,
     socket
     |> assign(:page_title, "Meetings")
     |> assign(:meeting, nil)}
  end

  # ── Events ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_chat_panel", _params, socket) do
    {:noreply, update(socket, :chat_panel_open, &(!&1))}
  end

  # ── Stage-mode presentation helpers (used by the heex shell) ─────────────

  @doc "Hero-icon class for a stage-mode segmented-control button."
  def stage_mode_icon(:canvas), do: "hero-rectangle-stack"
  def stage_mode_icon(:screen), do: "hero-computer-desktop"
  def stage_mode_icon(:gallery), do: "hero-squares-2x2"
  def stage_mode_icon(:whiteboard), do: "hero-pencil-square"

  @doc "Human label for a stage-mode segmented-control button."
  def stage_mode_label(:canvas), do: "Canvas"
  def stage_mode_label(:screen), do: "Screen"
  def stage_mode_label(:gallery), do: "Gallery"
  def stage_mode_label(:whiteboard), do: "Whiteboard"
end
