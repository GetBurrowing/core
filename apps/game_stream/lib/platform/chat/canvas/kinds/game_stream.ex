defmodule Platform.Chat.Canvas.Kinds.GameStream do
  @moduledoc """
  A live, playable stream of a task's review build (task 01a0db5f).

  ## Registered only while `GAME_STREAM_ENABLED` is set

  This kind is NOT in `Platform.Chat.Canvas.Kinds`' compile-time `@modules`
  list. `Kinds.all/0` appends `Platform.Extensions.canvas_kinds/0` at call
  time, which lists it (via `Platform.GameStream.Extension`) while
  `Platform.GameStream.enabled?/0` is true, and every other registry reader
  (`by_name/0`, `names/0`, `summaries/0`, `tool_schemas/0`) goes through
  `all/0`. With the flag unset it is therefore absent from `canvas.list_kinds`,
  `canvas.create` rejects it as an unknown kind, and an EXISTING document that
  holds a `game_stream` node renders that node through
  `Platform.Chat.Canvas.Renderer`'s fallback (`[unknown node type:
  game_stream]`) — the document itself is untouched, and the node renders
  normally again once the flag is set.

  ## Props

    * `session_id` (string) — the `Platform.GameStream` session this node
      shows;
    * `task_id` (string) — the task whose review build is played;
    * `review_sha` (string, 40 lowercase hex) — the exact commit the session
      builds; shown in full, never truncated;
    * `branch` (string) — the task branch the sha was read from;
    * `title` (string) — header text;
    * `latency_warn_ms` (integer 1..1000, default 50) — the p50 round trip
      above which the stats readout warns.

  ## Render (stage 4, built to design canvas 01a0db60)

  The wrapper carries `phx-hook="GameStream"` and `phx-update="ignore"`: the
  server renders the first frame of the right state, and from then on the
  `GameStream` JS hook (`assets/js/hooks/game_stream.js`) owns the DOM,
  switching panels by `data-gs-panel` and talking to
  `PlatformWeb.GameStreamHooks`. Its id is namespaced by `dom_id_scope` (the
  node can render twice, panel and mobile overlay) and carries the session
  id, so a restart that patches a new `session_id` into the node replaces the
  element and remounts the hook instead of being ignored.

  Every frame-state line is written as the design's state table words it,
  and lives only here: the hook shows and hides the panels, it does not hold
  a second copy of their text. The two footer-only lines ("Press any button
  on your controller", "Connect a controller to play on this device")
  depend on what the browser can see, so they are the hook's
  (`controllerLabel/1` in `assets/js/hooks/lib/game_stream_input.js`).

  The connecting panel also carries "Still connecting" (`text-warning`) with
  a Reload button (`btn btn-sm`), rendered hidden (task 01a0dbd6 stage 1).
  The hook reveals it after 10 s on Connecting with no decoded frame on the
  current peer connection (`assets/js/hooks/lib/game_stream_attach_state.js`).

  ## Multiplayer (task 01a0dbd6 stage 4, design canvas 01a0e954-b12f)

  Against a host that declares `game_stream_multi` (the roster's `multi`),
  the node also renders:

    * the roster strip `[data-gs-roster]` under the video: one chip per slot
      ("P1" in JetBrains Mono `font-mono text-xs`, the name in `text-xs`,
      truncating before the label), each with an input-activity dot that
      blinks on that slot's `play_slot_activity`, and the spectator count
      ("2 watching", names on hover). At phone widths (below container `@md`)
      the strip is the single line `[data-gs-roster-line]` ("You are P2 · 2
      others playing · 2 watching"), and tapping it opens the full roster in
      the bottom sheet `[data-gs-sheet]`;
    * the footer's watching row `[data-gs-watch]` for a spectator: "Watching"
      and `[data-gs-join]` "Join as player N", or "All N player slots are
      taken. You are watching." with no Join; and the pad rows
      `[data-gs-pads]` for a player ("Pad 1 → P2", "Pad 2: press any button
      to join as P3");
    * `[data-gs-leave]` Leave, which replaces End for a player, and the
      overflow `[data-gs-overflow]` with "Take over P1 from <name>" per slot
      someone else holds (a one-line confirm) and "End session" with "Ends
      the session for N people".

  Opening the canvas always watches, so the first frame renders as a
  spectator; `peer_id` (tests) renders it from that peer's side. After mount
  the hook re-renders all of it from the roster messages with
  `assets/js/hooks/lib/game_stream_roster.js`, which holds the same words;
  the vitest and ExUnit suites pin both to the same strings. The chip, menu
  item and pad row markup the hook clones lives here, in `<template>`s, and
  the chip state classes are read from the strip's `data-gs-chip-*`
  attributes, so every token is written once, in this file.

  A v1 host (no `multi`) renders none of this and keeps End and "Play here".

  Token slots: the video well is `bg-black` in both themes; the capture ring
  (`ring-2 ring-primary`) and YOUR roster chip (`bg-primary` with
  `text-primary-content`, black in both themes) are the only uses of
  `primary` in the node; other players' chips are `bg-base-300
  text-base-content`, an open slot is `border border-dashed
  border-base-content/40`, the activity dot is `bg-base-content`, and slots
  carry no per-player hue; the live
  dot is `bg-success`; the stats readout turns `text-warning` above
  `latency_warn_ms`; a failure line is `text-error`; labels and stats are
  neutral `base-content` opacity steps. The review sha is `shrink-0` and
  never truncated by CSS: a narrow frame shows its first 7 hex, a wide one
  (container `@xl`) all 40, and the full sha is always in the `title`.
  """

  use Platform.Chat.Canvas.Kind

  @default_latency_warn_ms 50
  @sha_regex ~r/\A[0-9a-f]{40}\z/

  @chip_base "inline-flex min-w-0 max-w-40 items-center gap-1.5 rounded-md px-2 py-0.5"
  @chip_classes %{
    you: "bg-primary text-primary-content",
    other: "bg-base-300 text-base-content",
    open:
      "cursor-pointer border border-dashed border-base-content/40 text-base-content/60 " <>
        "hover:bg-base-200"
  }

  # Read by `Kinds.summaries/0` (ADR 0055): a kind core does not own
  # describes itself.
  @impl Platform.Chat.Canvas.Kind
  def describe,
    do:
      "Live, playable stream of a task's review build from the play host. " <>
        "Props: session_id, task_id, review_sha (40-hex), branch, title, latency_warn_ms; no children."

  @doc """
  A Play card in a chat message never opens the canvas sidebar on click
  (task 01a0ee4f). `PlatformWeb.Chat.CanvasRenderer` reads this convention
  function and drops the inline wrapper's `phx-click="canvas_open"` for any
  document holding this node. Rowan, 2026-09-29: *"we need to ensure that it
  never opens that sidebar, but also, if i were to engage the sidebar myself,
  by going through the canvas selector in the chat shell ... that that is
  where we connect."* The canvas selector's explorer row still sends
  `canvas_open`, so the deliberate path is unchanged.
  """
  @spec inline_opens_canvas?() :: false
  def inline_opens_canvas?, do: false

  @impl Platform.Chat.Canvas.Kind
  def children, do: :none

  @impl Platform.Chat.Canvas.Kind
  def defaults, do: %{"latency_warn_ms" => @default_latency_warn_ms}

  @impl Platform.Chat.Canvas.Kind
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Play session id."},
        "task_id" => %{"type" => "string", "description" => "Task whose review build is played."},
        "review_sha" => %{
          "type" => "string",
          "pattern" => "^[0-9a-f]{40}$",
          "description" => "The full 40-hex commit the session builds."
        },
        "branch" => %{"type" => "string", "description" => "The task branch."},
        "title" => %{"type" => "string", "description" => "Header text."},
        "latency_warn_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 1000,
          "description" => "p50 round trip (ms) above which the readout warns (default 50)."
        }
      }
    }
  end

  @impl true
  def validate_props(props) when is_map(props) do
    errors =
      [
        check_sha(Map.get(props, "review_sha")),
        check_warn(Map.get(props, "latency_warn_ms"))
      ] ++
        for {key, value} <- Map.take(props, ~w(session_id task_id branch title)),
            not is_nil(value) and not is_binary(value) do
          "#{key} must be a string"
        end

    case Enum.reject(errors, &is_nil/1) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check_sha(nil), do: nil

  defp check_sha(sha) when is_binary(sha) do
    if Regex.match?(@sha_regex, sha),
      do: nil,
      else: "review_sha must be a full 40-character lowercase hex sha"
  end

  defp check_sha(_), do: "review_sha must be a full 40-character lowercase hex sha"

  defp check_warn(nil), do: nil
  defp check_warn(n) when is_integer(n) and n >= 1 and n <= 1000, do: nil
  defp check_warn(_), do: "latency_warn_ms must be an integer between 1 and 1000"

  @panels ~w(unavailable building connecting live ended failed takeover elsewhere)

  @doc "The panel names the render emits, one per frame state."
  @spec panels() :: [String.t()]
  def panels, do: @panels

  attr(:node, :map, required: true)
  attr(:dom_id_scope, :string, default: nil)
  attr(:canvas_id, :string, default: nil)
  # Tests pass the session's status (or `{:error, _}`) directly; a real
  # render asks `Platform.GameStream` for it.
  attr(:status, :any, default: :lookup)
  # The session's roster (task 01a0dbd6), looked up like `status`. Tests pass
  # one directly, with the `peer_id` whose side the frame renders from; a
  # real render has no peer yet (opening always watches), so it is nil.
  attr(:roster, :any, default: :lookup)
  attr(:peer_id, :string, default: nil)

  @impl Platform.Chat.Canvas.Kind
  def render(assigns) do
    props = assigns.node["props"] || %{}
    node_id = assigns.node["id"] || "game-stream"
    session_id = props["session_id"]
    sha = props["review_sha"]

    status =
      case assigns.status do
        :lookup -> lookup_status(session_id)
        other -> other
      end

    {panel, detail, elapsed_ms} = initial_view(session_id, status)

    roster =
      case assigns.roster do
        :lookup -> lookup_roster(session_id)
        other -> other
      end
      |> normalize_roster()

    running? = panel in ~w(building connecting live)
    view = roster_view(roster, assigns[:peer_id])

    scope =
      case assigns[:dom_id_scope] do
        scope when is_binary(scope) and scope != "" -> "-" <> scope
        _ -> ""
      end

    assigns =
      assigns
      |> assign(:wrapper_id, "game-stream-#{node_id}#{scope}-#{session_id || "none"}")
      |> assign(:node_id, node_id)
      |> assign(:session_id, session_id)
      |> assign(:title, props["title"] || "Playable review build")
      |> assign(:branch, props["branch"])
      |> assign(:review_sha, sha)
      |> assign(:sha7, sha && String.slice(sha, 0, 7))
      |> assign(:warn_ms, props["latency_warn_ms"] || @default_latency_warn_ms)
      |> assign(:panel, panel)
      |> assign(:detail, detail)
      |> assign(:elapsed_ms, elapsed_ms || 0)
      |> assign(:running?, running?)
      |> assign(:multi?, roster.multi)
      |> assign(:view, view)
      |> assign(:chip_base, @chip_base)
      |> assign(:chip_classes, @chip_classes)
      |> assign(:elsewhere_line, elsewhere_line(assigns[:dom_id_scope]))

    ~H"""
    <div
      id={@wrapper_id}
      phx-hook="GameStream"
      phx-update="ignore"
      data-session-id={@session_id}
      data-canvas-id={@canvas_id}
      data-node-id={@node_id}
      data-review-sha={@review_sha}
      data-latency-warn-ms={@warn_ms}
      data-state={@panel}
      data-elapsed-ms={@elapsed_ms}
      class="game-stream-frame @container overflow-hidden rounded-xl border border-edge bg-base-100"
    >
      <div class="flex min-w-0 items-center gap-2 px-3 py-2">
        <span
          data-gs-live-dot
          class={[
            "size-2 shrink-0 rounded-full",
            if(@panel == "live", do: "bg-success", else: "bg-base-content/20")
          ]}
          aria-hidden="true"
        >
        </span>
        <span class="hidden min-w-0 truncate text-sm font-semibold @sm:inline">{@title}</span>
        <span
          :if={@branch}
          data-gs-branch
          class="hidden min-w-0 truncate font-mono text-xs text-base-content/50 @md:inline"
        >
          {@branch}
        </span>
        <span
          :if={@review_sha}
          data-gs-sha
          title={@review_sha}
          aria-label={"Review build " <> @review_sha}
          class="ml-auto shrink-0 font-mono text-xs text-base-content/70"
        >
          <span class="@xl:hidden">{@sha7}</span><span class="hidden @xl:inline">{@review_sha}</span>
        </span>
        <button
          type="button"
          data-gs-leave
          hidden={!(@running? and @multi? and @view.player?)}
          class={[header_button_class(), !@review_sha && "ml-auto"]}
        >
          Leave
        </button>
        <button
          type="button"
          data-gs-end
          hidden={!@running? or @multi?}
          class={[header_button_class(), !@review_sha && "ml-auto"]}
        >
          End
        </button>
        <div data-gs-overflow hidden={!(@running? and @multi?)} class="relative shrink-0">
          <button
            type="button"
            data-gs-overflow-toggle
            title="More"
            aria-label="More"
            aria-haspopup="menu"
            aria-expanded="false"
            class="rounded-md p-1 text-base-content/60 hover:bg-base-200 hover:text-base-content"
          >
            <span class="hero-ellipsis-horizontal size-4" aria-hidden="true"></span>
          </button>
          <div
            data-gs-overflow-menu
            role="menu"
            hidden
            class="absolute right-0 top-full z-20 mt-1 flex w-64 max-w-[80vw] flex-col rounded-lg border border-edge bg-base-100 p-1 shadow-lg"
          >
            <div data-gs-take-items class="flex flex-col">
              <button
                :for={item <- @view.take_over}
                type="button"
                role="menuitem"
                data-gs-take-over={item.slot}
                class={menu_item_class()}
              >
                {item.label}
              </button>
            </div>
            <div data-gs-confirm hidden class="flex min-w-0 flex-col gap-2 px-2 py-1.5">
              <span data-gs-confirm-line class="text-sm text-base-content"></span>
              <div class="flex justify-end gap-2">
                <button type="button" data-gs-confirm-no class="btn btn-ghost btn-xs">Cancel</button>
                <button type="button" data-gs-confirm-yes class="btn btn-xs">Take over</button>
              </div>
            </div>
            <button type="button" role="menuitem" data-gs-end-session class={menu_item_class()}>
              <span class="block">End session</span>
              <span data-gs-end-line class="block text-xs text-base-content/60">
                {@view.end_line}
              </span>
            </button>
          </div>
          <template data-gs-take-template>
            <button type="button" role="menuitem" data-gs-take-over class={menu_item_class()}>
            </button>
          </template>
        </div>
      </div>

      <div data-gs-well class="relative aspect-video bg-black">
        <video
          data-gs-video
          muted
          autoplay
          playsinline
          disablepictureinpicture
          class="absolute inset-0 size-full object-contain"
        >
        </video>
        <%!-- Audio is separate from muted video so video autoplay cannot suppress it. --%>
        <audio data-gs-audio autoplay playsinline class="hidden"></audio>
        <div
          data-gs-ring
          hidden
          class="pointer-events-none absolute inset-0 ring-2 ring-primary ring-inset"
          aria-hidden="true"
        >
        </div>

        <div data-gs-panel="unavailable" hidden={@panel != "unavailable"} class={panel_class()}>
          <p class="text-sm text-white/80">Stream unavailable. No play host is connected.</p>
        </div>

        <div data-gs-panel="building" hidden={@panel != "building"} class={panel_class()}>
          <p class="text-sm text-white">
            Building <span class="font-mono text-xs">{@sha7}</span> on the play host…
          </p>
          <p data-gs-elapsed class="font-mono text-xs text-white/60">
            {format_elapsed(@elapsed_ms)}
          </p>
        </div>

        <div data-gs-panel="connecting" hidden={@panel != "connecting"} class={panel_class()}>
          <p data-gs-connecting-line class="text-sm text-white">Connecting…</p>
          <div data-gs-stuck hidden class="flex flex-col items-center gap-2">
            <p class="text-sm text-warning">Still connecting</p>
            <button type="button" data-gs-reload class="btn btn-sm">Reload</button>
          </div>
        </div>

        <div data-gs-panel="live" hidden class={panel_class()}>
          <button
            type="button"
            data-gs-capture
            class="rounded-lg bg-white/10 px-4 py-2 text-sm font-semibold text-white hover:bg-white/20"
          >
            Click to play
          </button>
          <p class="text-sm text-white/70">
            Keys and controller go to the game until you press Esc.
          </p>
        </div>

        <div
          data-gs-panel="ended"
          hidden={@panel != "ended"}
          class={[panel_class(), "bg-black/60"]}
        >
          <p data-gs-reason class="text-sm text-white">{@detail || "Session ended"}</p>
          <button type="button" data-gs-restart class={restart_class()}>
            <span class="hero-arrow-path size-4" aria-hidden="true"></span> Start again
          </button>
        </div>

        <div data-gs-panel="failed" hidden={@panel != "failed"} class={panel_class()}>
          <p data-gs-reason class="text-sm text-error">
            {@detail || "The build failed on the play host"}
          </p>
          <button type="button" data-gs-restart class={restart_class()}>
            <span class="hero-arrow-path size-4" aria-hidden="true"></span> Start again
          </button>
        </div>

        <div data-gs-panel="takeover" hidden class={[panel_class(), "bg-black/60"]}>
          <p class="text-sm text-white">Continued in another window</p>
          <button type="button" data-gs-play-here class={restart_class()}>Play here</button>
        </div>

        <%!-- A twin copy in THIS page holds the stream (task 01a0ee4f stage 2).
        Its Play here takes the stream back in the page and never takes a
        slot from anyone. --%>
        <div data-gs-panel="elsewhere" hidden class={[panel_class(), "bg-black/60"]}>
          <p data-gs-elsewhere-line class="text-sm text-white">{@elsewhere_line}</p>
          <button type="button" data-gs-play-here-twin class={restart_class()}>Play here</button>
        </div>
      </div>

      <div
        data-gs-roster
        hidden={!@multi?}
        data-gs-chip-you={@chip_classes.you}
        data-gs-chip-other={@chip_classes.other}
        data-gs-chip-open={@chip_classes.open}
        class="px-3 pt-2"
      >
        <div data-gs-roster-strip class="hidden min-w-0 items-center gap-1.5 @md:flex">
          <div data-gs-chips class="flex min-w-0 items-center gap-1.5">
            <.chip :for={chip <- @view.chips} chip={chip} base={@chip_base} classes={@chip_classes} />
          </div>
          <span
            data-gs-watching
            title={@view.watching_title}
            class="ml-auto shrink-0 text-xs text-base-content/60"
          >
            {@view.watching}
          </span>
        </div>
        <button
          type="button"
          data-gs-roster-line
          aria-haspopup="dialog"
          class="flex w-full min-w-0 items-center gap-1 text-left text-xs text-base-content/70 @md:hidden"
        >
          <span data-gs-roster-line-text class="min-w-0 truncate">{@view.phone_line}</span>
          <span class="hero-chevron-up size-3 shrink-0" aria-hidden="true"></span>
        </button>
        <template data-gs-chip-template>
          <.chip chip={nil} base={@chip_base} classes={@chip_classes} />
        </template>
        <dialog data-gs-sheet aria-label="Players" class="modal modal-bottom">
          <div class="modal-box flex flex-col gap-3">
            <p class="text-sm font-semibold">Players</p>
            <div data-gs-sheet-chips class="flex flex-col items-stretch gap-1.5 *:max-w-none">
              <.chip :for={chip <- @view.chips} chip={chip} base={@chip_base} classes={@chip_classes} />
            </div>
            <p data-gs-sheet-watching class="text-xs text-base-content/60">
              {@view.sheet_watching}
            </p>
          </div>
          <form method="dialog" class="modal-backdrop">
            <button type="submit" aria-label="Close">Close</button>
          </form>
        </dialog>
      </div>

      <div
        data-gs-watch
        hidden={!(@running? and @multi? and not @view.player?)}
        class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 px-3 pt-2"
      >
        <span data-gs-watch-line class="min-w-0 text-xs text-base-content/70">
          {@view.watch && @view.watch.line}
        </span>
        <button
          type="button"
          data-gs-join
          data-gs-join-slot={@view.watch && @view.watch.join && @view.watch.join.slot}
          hidden={!(@view.watch && @view.watch.join)}
          class="btn btn-xs"
        >
          {@view.watch && @view.watch.join && @view.watch.join.label}
        </button>
      </div>

      <div
        data-gs-pads
        hidden
        class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 px-3 pt-2"
      >
      </div>
      <template data-gs-pad-template>
        <span data-gs-pad class="min-w-0 truncate text-xs text-base-content/60"></span>
      </template>

      <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2">
        <span
          data-gs-controller
          hidden
          class="min-w-0 basis-full text-xs text-base-content/60 @sm:basis-auto @sm:truncate"
        >
        </span>
        <span data-gs-hint class="hidden shrink-0 text-xs text-base-content/60 @sm:inline"></span>
        <span
          data-gs-audio-state="waiting"
          class="shrink-0 text-xs text-base-content/60"
          aria-live="polite"
        >
          Waiting for audio
        </span>
        <button
          type="button"
          data-gs-mute
          disabled
          aria-pressed="false"
          aria-label="Mute game audio"
          title="Mute game audio (M)"
          class="btn btn-ghost btn-xs shrink-0"
        >
          Mute
        </button>
        <span
          data-gs-stats
          class="ml-auto shrink-0 font-mono text-xs text-base-content/60"
          aria-label="Round trip, frame rate, connection path and frame size"
        >
          -- ms · -- fps · --
        </span>
        <button
          type="button"
          data-gs-fullscreen
          title="Full screen"
          aria-label="Full screen"
          class="shrink-0 rounded-md p-1 text-base-content/60 hover:bg-base-200 hover:text-base-content"
        >
          <span class="hero-arrows-pointing-out size-4" aria-hidden="true"></span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The panel a node first renders, with its detail line and elapsed time,
  from the session status (`{:ok, map}` or `{:error, reason}`).

  `live` is shown as `connecting`: the server cannot know whether this window
  has frames yet, and the hook switches to `live` on the first decoded one.
  A session that no longer exists is `ended` while a host is connected (so
  Start again is offered) and `unavailable` when none is.
  """
  @spec initial_view(String.t() | nil, term()) ::
          {String.t(), String.t() | nil, non_neg_integer() | nil}
  def initial_view(_session_id, {:ok, %{state: state} = status}) do
    panel = if state == "live", do: "connecting", else: state
    detail = if state in ~w(ended failed), do: status[:ended_reason] || status[:detail]
    {panel, detail, status[:elapsed_ms]}
  end

  def initial_view(_session_id, {:error, _}) do
    if Platform.GameStream.host_available?(),
      do: {"ended", "This session has ended", nil},
      else: {"unavailable", nil, nil}
  end

  # A node that names no session (`:no_session`) has nothing to show yet.
  def initial_view(_session_id, _), do: {"unavailable", nil, nil}

  # ── Roster (task 01a0dbd6 stage 4) ─────────────────────────────────────

  @doc "The chip state classes: `you`, `other` and `open`."
  @spec chip_classes() :: %{you: String.t(), other: String.t(), open: String.t()}
  def chip_classes, do: @chip_classes

  attr(:chip, :any, default: nil)
  attr(:base, :string, required: true)
  attr(:classes, :map, required: true)

  # One roster chip. With `chip: nil` it is the empty markup the hook clones.
  defp chip(assigns) do
    ~H"""
    <button
      type="button"
      data-gs-chip={@chip && @chip.slot}
      data-gs-chip-state={@chip && @chip.state}
      title={@chip && @chip.title}
      aria-disabled={if(@chip && @chip.state != "open", do: "true")}
      class={[@base, @chip && Map.fetch!(@classes, String.to_existing_atom(@chip.state))]}
    >
      <span data-gs-chip-label class="shrink-0 font-mono text-xs">{@chip && @chip.label}</span>
      <span data-gs-chip-name class="min-w-0 truncate text-xs">{@chip && @chip.name}</span>
      <span
        data-gs-chip-dot
        hidden={!!@chip and @chip.state == "open"}
        class="size-1.5 shrink-0 rounded-full bg-base-content opacity-20"
        aria-hidden="true"
      >
      </span>
    </button>
    """
  end

  defp lookup_roster(session_id) when is_binary(session_id) and session_id != "" do
    case Platform.GameStream.roster(session_id) do
      {:ok, roster} -> roster
      _ -> nil
    end
  catch
    # A session that exits between lookup and call renders without a roster.
    :exit, _ -> nil
  end

  defp lookup_roster(_), do: nil

  defp normalize_roster(roster) when is_map(roster) do
    slots =
      for {slot, holder} <- Map.get(roster, :slots) || %{},
          slot = to_slot(slot),
          is_integer(slot),
          into: %{},
          do: {slot, %{peer_id: holder[:peer_id], name: holder[:name]}}

    highest = if slots == %{}, do: 1, else: Enum.max(Map.keys(slots)) + 1

    max =
      case Map.get(roster, :max_players) do
        n when is_integer(n) and n > 0 -> max(n, highest)
        _ -> highest
      end

    %{
      multi: Map.get(roster, :multi) == true,
      max_players: max,
      slots: slots,
      spectators: Map.get(roster, :spectators) || 0,
      names: Enum.filter(Map.get(roster, :names) || [], &(is_binary(&1) and &1 != ""))
    }
  end

  defp normalize_roster(_),
    do: %{multi: false, max_players: 1, slots: %{}, spectators: 0, names: []}

  defp to_slot(n) when is_integer(n) and n >= 0, do: n

  defp to_slot(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_slot(_), do: nil

  @doc """
  What the roster renders from `peer_id`'s side (nil: a viewer with no peer
  yet, i.e. a spectator). Mirrors `assets/js/hooks/lib/game_stream_roster.js`
  word for word; both are pinned to the same strings by their tests.
  """
  @spec roster_view(map(), String.t() | nil) :: map()
  def roster_view(roster, peer_id) do
    mine =
      for {slot, %{peer_id: holder}} <- roster.slots,
          not is_nil(peer_id) and holder == peer_id,
          do: slot

    mine = Enum.sort(mine)
    player_peers = roster.slots |> Map.values() |> Enum.map(& &1.peer_id) |> Enum.uniq()
    people = length(player_peers) + roster.spectators
    free = Enum.find(0..(roster.max_players - 1), &(not Map.has_key?(roster.slots, &1)))
    watching = "#{roster.spectators} watching"

    take_over =
      for {slot, holder} <- Enum.sort(roster.slots),
          is_nil(peer_id) or holder.peer_id != peer_id,
          do: %{slot: slot, label: take_over_label(slot, holder.name)}

    %{
      player?: mine != [],
      chips: Enum.map(0..(roster.max_players - 1), &chip_view(roster, peer_id, &1)),
      watching: watching,
      watching_title: Enum.join(roster.names, ", "),
      sheet_watching:
        if(roster.names == [],
          do: watching,
          else: watching <> ": " <> Enum.join(roster.names, ", ")
        ),
      take_over: take_over,
      end_line:
        if(people == 1,
          do: "Ends the session for 1 person",
          else: "Ends the session for #{people} people"
        ),
      watch: if(mine == [], do: watch_view(roster, free)),
      phone_line: phone_line(roster, mine, player_peers, peer_id, watching)
    }
  end

  defp chip_view(roster, peer_id, slot) do
    label = slot_label(slot)

    case Map.get(roster.slots, slot) do
      nil ->
        %{
          slot: slot,
          label: label,
          state: "open",
          name: "open",
          title: "Join as player #{slot + 1}"
        }

      %{peer_id: ^peer_id} when not is_nil(peer_id) ->
        %{slot: slot, label: label, state: "you", name: "You", title: "#{label} (you)"}

      %{name: name} ->
        name = name || "Player"
        %{slot: slot, label: label, state: "other", name: name, title: "#{label} #{name}"}
    end
  end

  defp take_over_label(slot, name) when is_binary(name) and name != "",
    do: "Take over #{slot_label(slot)} from #{name}"

  defp take_over_label(slot, _name), do: "Take over #{slot_label(slot)}"

  defp watch_view(_roster, free) when is_integer(free),
    do: %{line: "Watching", join: %{slot: free, label: "Join as player #{free + 1}"}}

  defp watch_view(roster, nil),
    do: %{
      line: "All #{roster.max_players} player slots are taken. You are watching.",
      join: nil
    }

  defp phone_line(_roster, [], player_peers, _peer_id, watching),
    do: "You are watching · #{length(player_peers)} playing · #{watching}"

  defp phone_line(_roster, mine, player_peers, peer_id, watching) do
    others = Enum.count(player_peers, &(&1 != peer_id))
    noun = if others == 1, do: "other", else: "others"
    "You are #{list_labels(mine)} · #{others} #{noun} playing · #{watching}"
  end

  defp list_labels([slot]), do: slot_label(slot)

  defp list_labels(slots) do
    {init, [last]} = Enum.split(slots, -1)
    Enum.map_join(init, ", ", &slot_label/1) <> " and " <> slot_label(last)
  end

  defp slot_label(slot), do: "P#{slot + 1}"

  defp header_button_class,
    do:
      "shrink-0 rounded-md border border-edge px-2 py-0.5 text-xs font-medium " <>
        "text-base-content/80 hover:bg-base-200"

  defp menu_item_class,
    do: "w-full rounded-md px-2 py-1.5 text-left text-sm text-base-content hover:bg-base-200"

  defp lookup_status(session_id) when is_binary(session_id) and session_id != "" do
    Platform.GameStream.status(session_id)
  end

  defp lookup_status(_), do: :no_session

  defp format_elapsed(ms) when is_integer(ms) and ms >= 0 do
    total = div(ms, 1000)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_elapsed(_), do: "0:00"

  # Where the stream went, said from where this copy is (task 01a0ee4f
  # stage 2). The inline chat copy (CanvasRenderer's scope ends "-inline")
  # gave it to the canvas panel the person opened. The panel or mobile
  # overlay copy ("-expanded") gave it back to the chat copy through that
  # copy's Play here; telling the panel it is "Playing in the canvas panel"
  # would name the very place the person is looking at.
  @doc false
  @spec elsewhere_line(String.t() | nil) :: String.t()
  def elsewhere_line(scope) when is_binary(scope) do
    if String.ends_with?(scope, "-expanded"),
      do: "Playing in the chat",
      else: "Playing in the canvas panel"
  end

  def elsewhere_line(_), do: "Playing in the canvas panel"

  defp panel_class,
    do: "absolute inset-0 flex flex-col items-center justify-center gap-3 p-4 text-center"

  defp restart_class,
    do:
      "inline-flex items-center gap-1.5 rounded-lg bg-white/10 px-3 py-1.5 text-sm font-medium " <>
        "text-white hover:bg-white/20"
end
