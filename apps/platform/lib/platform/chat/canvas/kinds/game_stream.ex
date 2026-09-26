defmodule Platform.Chat.Canvas.Kinds.GameStream do
  @moduledoc """
  A live, playable stream of a task's review build (task 01a0db5f).

  ## Registered only while `GAME_STREAM_ENABLED` is set

  This kind is NOT in `Platform.Chat.Canvas.Kinds`' compile-time `@modules`
  list. `Kinds.all/0` appends it at call time when
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

  Token slots: the video well is `bg-black` in both themes; the capture ring
  (`ring-2 ring-primary`) is the only use of `primary` in the node; the live
  dot is `bg-success`; the stats readout turns `text-warning` above
  `latency_warn_ms`; a failure line is `text-error`; labels and stats are
  neutral `base-content` opacity steps. The review sha is `shrink-0` and
  never truncated by CSS: a narrow frame shows its first 7 hex, a wide one
  (container `@xl`) all 40, and the full sha is always in the `title`.
  """

  use Platform.Chat.Canvas.Kind

  @default_latency_warn_ms 50
  @sha_regex ~r/\A[0-9a-f]{40}\z/

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

  @panels ~w(unavailable building connecting live ended failed takeover)

  @doc "The panel names the render emits, one per frame state."
  @spec panels() :: [String.t()]
  def panels, do: @panels

  attr(:node, :map, required: true)
  attr(:dom_id_scope, :string, default: nil)
  attr(:canvas_id, :string, default: nil)
  # Tests pass the session's status (or `{:error, _}`) directly; a real
  # render asks `Platform.GameStream` for it.
  attr(:status, :any, default: :lookup)

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
      |> assign(:running?, panel in ~w(building connecting live))

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
          data-gs-end
          hidden={!@running?}
          class={[
            "shrink-0 rounded-md border border-edge px-2 py-0.5 text-xs font-medium",
            "text-base-content/80 hover:bg-base-200",
            !@review_sha && "ml-auto"
          ]}
        >
          End
        </button>
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
          <p class="text-sm text-white">Connecting…</p>
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
      </div>

      <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2">
        <span
          data-gs-controller
          hidden
          class="min-w-0 basis-full text-xs text-base-content/60 @sm:basis-auto @sm:truncate"
        >
        </span>
        <span data-gs-hint class="hidden shrink-0 text-xs text-base-content/60 @sm:inline"></span>
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

  defp lookup_status(session_id) when is_binary(session_id) and session_id != "" do
    Platform.GameStream.status(session_id)
  end

  defp lookup_status(_), do: :no_session

  defp format_elapsed(ms) when is_integer(ms) and ms >= 0 do
    total = div(ms, 1000)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_elapsed(_), do: "0:00"

  defp panel_class,
    do: "absolute inset-0 flex flex-col items-center justify-center gap-3 p-4 text-center"

  defp restart_class,
    do:
      "inline-flex items-center gap-1.5 rounded-lg bg-white/10 px-3 py-1.5 text-sm font-medium " <>
        "text-white hover:bg-white/20"
end
