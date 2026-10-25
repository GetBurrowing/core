defmodule PlatformWeb.GameViewLive do
  @moduledoc """
  The Game view (task 01a1557a-efdd, Burrow redesign 21, stage 2): a game
  canvas's playable review build on a full-window stage, with the masters'
  top bar, a tab drawer and the way back (masters canvas 01a1382f,
  master-mobile.html #game and master-desktop.html's game view).

  Served at `/m/games?canvas=<id>&from=<path>` by core's generic extension
  page (`Platform.Extension.live_pages/0`, claimed by
  `Platform.GameStream.Extension` only while GAME_STREAM_ENABLED is set).

  ## Nothing is inherited from the parent page

  Core nests this LiveView with `%{"user_id" => id, "query" => %{...}}` and
  runs no live_session hook on it, and a nested LiveView gets no
  `handle_params/3`. `mount/3` re-reads the user and treats every `query`
  value as untrusted:

    * `canvas` must be a UUID;
    * `from`, the page Back returns to, is kept only when it is a local path
      (`safe_from/1`); anything else, and no `from`, is the Games browser.

  The canvas is read through `Platform.Chat.CanvasAccess.fetch_for_viewer/3`,
  the same gate `PlatformWeb.CanvasLive` uses. A forbidden or missing canvas,
  and a canvas with no `game_stream` node, render the unavailable state and
  never render the node.

  ## Hooks: ours observe first, then Play's

  `attach_observers/1` puts this page's own `:handle_event` and
  `:handle_info` hooks on the socket BEFORE `PlatformWeb.GameStreamHooks`,
  because Play's hooks `:halt` the session messages they handle. Ours always
  `{:cont, socket}`: they only record what the page shows (the tracked play
  state for the status line; stage 3 adds stats and the timeline), and only
  for a session already in `:game_stream_grants`.

  Stage 3 records, in the same observers: the last 24 `game_stream_stats`
  samples (two minutes at the hook's 5 s cadence; only a PLAYER's hook
  pushes them) and a session timeline, one row per tracked state change,
  seeded at mount with the node's initial panel at 0:00.

  ## Settings and Insights (stage 3)

  Every row is backed by data Play really has; the masters' Your slot, Seed,
  Difficulty, Speed, Encoder preset and build picker rows are not built (see
  the stage's commit). Latency warning writes the node's `latency_warn_ms`
  through `Platform.Chat.patch_canvas/3` after
  `CanvasAccess.fetch_for_writer/2`; the node's wrapper attribute is patched
  and the GameStream hook re-reads it in `updated()`. Restart dispatches a
  click to the node's own `[data-gs-restart]`, so it is the hook's restart.
  Recent runs come from `Platform.GameStream.recent_runs/2`.

  ## Review (stage 4)

  Thumbs plus a line that lands on the build's task, through
  `Platform.GameStream.ReviewNotes`: a log-only message in the task's
  execution space (recorded without waking its agent). The notes list is a
  stream, newest first, read back at mount so it survives a reload.

  ## Dialog semantics (stage 3)

  `role="dialog"` and `aria-modal` are the phone layout's only: the root
  renders them and the `GameViewDialog` hook drops them at lg and up, where
  the view sits beside the usable rail.

  The catch-all `handle_info/2` and `handle_event/3` keep the page alive
  inside the app shell, whose broadcasts (`{:new_message, _}` and the like)
  reach every LiveView in it (the rung-20 crash).

  ## The node in stage chrome

  The `game_stream` node renders with `chrome={:stage}`: no frame of its own,
  its title, branch and sha hidden. Its wrapper keeps `phx-update="ignore"`,
  so switching tabs re-renders this page and never remounts the stream.
  """
  use PlatformWeb, :live_view

  alias Phoenix.LiveView.JS
  alias Platform.Chat
  alias Platform.Chat.Canvas.Kinds.GameStream, as: GameStreamKind
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasAccess
  alias Platform.GameStream
  alias Platform.GameStream.ReviewNotes
  alias Platform.Tasks

  @default_from "/files?tab=browse&type=game"
  @max_from_bytes 512
  @tabs ~w(settings insights review)
  @tab_labels %{"settings" => "Settings", "insights" => "Insights", "review" => "Review"}
  @max_samples 24
  @warn_choices [30, 50, 80]
  @default_warn_ms 50
  @spark_w 320
  @spark_h 56

  @impl true
  def mount(_params, session, socket) do
    user = Platform.Accounts.get_user(session["user_id"])
    query = if is_map(session["query"]), do: session["query"], else: %{}
    viewer = if user, do: {:user, user.id}

    socket =
      socket
      |> assign(:current_user_id, user && user.id)
      |> assign(:from, safe_from(query["from"]))
      |> assign(:tab, "settings")
      |> assign(:tracked_state, nil)
      |> assign(:viewer, viewer)
      |> assign(:writer?, false)
      |> assign(:samples, [])
      |> assign(:mounted_at, System.monotonic_time(:millisecond))
      |> assign(:timeline_seq, 0)
      |> assign(:runs_count, 0)
      |> assign(:runs_today, 0)
      |> assign(:vote, nil)
      |> assign(:note_form, note_form(""))
      |> assign(:notes_count, 0)
      |> stream_configure(:runs, dom_id: &("game-run-" <> &1.id))
      |> stream_configure(:notes, dom_id: &("game-note-" <> &1.id))
      |> stream(:timeline, [])
      |> stream(:runs, [])
      |> stream(:notes, [])
      |> attach_observers()
      |> PlatformWeb.GameStreamHooks.attach()

    {:ok, load(socket, query["canvas"], viewer)}
  end

  @doc """
  The Back destination for an untrusted `from`: kept only when it is a local
  path (starts with one `/`, not `//` or `/\\`, no `://` anywhere, at most
  #{@max_from_bytes} bytes); otherwise the Games browser.
  """
  @spec safe_from(term()) :: String.t()
  def safe_from(from) when is_binary(from) do
    if byte_size(from) <= @max_from_bytes and String.starts_with?(from, "/") and
         not String.starts_with?(from, "//") and not String.starts_with?(from, "/\\") and
         not String.contains?(from, "://") do
      from
    else
      @default_from
    end
  end

  def safe_from(_from), do: @default_from

  defp load(socket, canvas_id, viewer) do
    with true <- Platform.UUID.valid?(canvas_id),
         {:ok, canvas, _level} <-
           CanvasAccess.fetch_for_viewer(canvas_id, viewer, audit: not connected?(socket)),
         %{} = node <- first_game_node(canvas.document) do
      props = node["props"] || %{}
      space = canvas.space_id && Chat.get_space(canvas.space_id)
      task = task(props["task_id"])
      sha = props["review_sha"]

      socket
      |> assign(:available?, true)
      |> assign(:canvas, canvas)
      |> assign(:node, node)
      |> assign(:title, title(canvas, props))
      |> assign(:sha7, is_binary(sha) && String.slice(sha, 0, 7))
      |> assign(
        :state_word,
        if(task && task.status == "in_review", do: "playable", else: "draft")
      )
      |> assign(:space_name, space && space.name)
      |> assign(:task, task)
      |> assign(:share_url, PlatformWeb.Endpoint.url() <> "/m/games?canvas=" <> canvas.id)
      |> assign(:writer?, match?({:ok, _}, CanvasAccess.fetch_for_writer(canvas.id, viewer)))
      |> seed_timeline(node)
      |> load_runs(props["task_id"])
      |> load_notes(props["task_id"], sha)
    else
      _ -> assign(socket, :available?, false)
    end
  end

  defp first_game_node(%{"root" => root}), do: find_game(root)
  defp first_game_node(_document), do: nil

  defp find_game(%{"type" => "game_stream"} = node), do: node

  defp find_game(%{"children" => children}) when is_list(children),
    do: Enum.find_value(children, &find_game/1)

  defp find_game(_node), do: nil

  defp title(canvas, props) do
    Enum.find([canvas.title, props["title"]], &(is_binary(&1) and &1 != "")) ||
      "Playable review build"
  end

  # The node's task, when its `task_id` names a live one. Untyped data, so it
  # is shape-checked before it reaches the repo.
  defp task(task_id) do
    with true <- Platform.UUID.valid?(task_id),
         %{deleted_at: nil} = task <- Tasks.get_task_record(task_id) do
      task
    else
      _ -> nil
    end
  end

  # The node's first panel (what its render shows before any status message)
  # is the tracked state and the timeline's 0:00 row.
  defp seed_timeline(socket, node) do
    session_id = (node["props"] || %{})["session_id"]

    status =
      if is_binary(session_id) and session_id != "",
        do: GameStream.status(session_id),
        else: :no_session

    {panel, _detail, _elapsed} = GameStreamKind.initial_view(session_id, status)

    socket
    |> assign(:tracked_state, panel)
    |> add_timeline(panel)
  end

  defp add_timeline(socket, state) do
    seq = socket.assigns.timeline_seq + 1
    elapsed = System.monotonic_time(:millisecond) - socket.assigns.mounted_at

    socket
    |> assign(:timeline_seq, seq)
    |> stream_insert(:timeline, %{id: "game-ev-#{seq}", at: m_ss(elapsed), state: state})
  end

  defp load_runs(socket, task_id) do
    runs = GameStream.recent_runs(task_id, 10)
    since = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    socket
    |> assign(:runs_count, length(runs))
    |> assign(:runs_today, GameStream.runs_since(task_id, since))
    |> stream(:runs, runs, reset: true)
  end

  defp load_notes(socket, task_id, sha) do
    notes = ReviewNotes.list(task_id, sha)

    socket
    |> assign(:notes_count, length(notes))
    |> stream(:notes, notes, reset: true)
  end

  defp note_form(text), do: to_form(%{"text" => text}, as: :note)

  # ── Observers (attached before Play's hooks) ─────────────────────────────

  defp attach_observers(socket) do
    socket
    |> attach_hook(:game_view_events, :handle_event, &observe_event/3)
    |> attach_hook(:game_view_info, :handle_info, &observe_info/2)
  end

  @doc false
  # A player's hook pushes its figures every 5 s; the last 24 are kept.
  def observe_event(
        "game_stream_stats",
        %{"session_id" => session_id, "stats" => %{} = stats},
        socket
      ) do
    if granted?(socket, session_id) do
      sample = %{
        fps_avg: number(stats["fps_avg"]),
        rtt_p50_ms: number(stats["rtt_p50_ms"]),
        rtt_p95_ms: number(stats["rtt_p95_ms"]),
        at: System.monotonic_time(:millisecond)
      }

      samples = Enum.take(socket.assigns.samples ++ [sample], -@max_samples)
      {:cont, assign(socket, :samples, samples)}
    else
      {:cont, socket}
    end
  end

  def observe_event(_event, _params, socket), do: {:cont, socket}

  @doc false
  def observe_info({:game_stream, session_id, {:status, %{state: state}}}, socket)
      when is_binary(state) do
    cond do
      not granted?(socket, session_id) -> {:cont, socket}
      state == socket.assigns.tracked_state -> {:cont, socket}
      true -> {:cont, socket |> assign(:tracked_state, state) |> add_timeline(state)}
    end
  end

  def observe_info(_message, socket), do: {:cont, socket}

  defp granted?(socket, session_id),
    do: Map.has_key?(socket.assigns[:game_stream_grants] || %{}, session_id)

  defp number(n) when is_number(n) and n >= 0, do: n / 1
  defp number(_), do: nil

  # ── Events ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("game_tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("game_link_copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, "Build link copied")}

  # Latency warning: written to THIS node, by a space member only.
  def handle_event("game_latency_warn", %{"ms" => ms}, %{assigns: %{available?: true}} = socket) do
    with {n, ""} <- Integer.parse(to_string(ms)),
         true <- n in @warn_choices,
         {:ok, canvas} <-
           CanvasAccess.fetch_for_writer(socket.assigns.canvas.id, socket.assigns.viewer),
         node_id = socket.assigns.node["id"],
         {:ok, _canvas} <-
           Chat.patch_canvas(socket.assigns.viewer, canvas, [
             {:set_props, node_id, %{"latency_warn_ms" => n}}
           ]) do
      {:noreply, assign(socket, :node, live_node(canvas.id, node_id, socket.assigns.node, n))}
    else
      _ -> {:noreply, socket}
    end
  end

  # Review: tapping the pressed vote clears it.
  def handle_event("game_vote", %{"vote" => vote}, socket) when vote in ~w(up down) do
    {:noreply, assign(socket, :vote, if(socket.assigns.vote == vote, do: nil, else: vote))}
  end

  def handle_event("game_note_change", %{"note" => %{"text" => text}}, socket)
      when is_binary(text),
      do: {:noreply, assign(socket, :note_form, note_form(text))}

  def handle_event("game_note_submit", params, %{assigns: %{available?: true}} = socket) do
    text = get_in(params, ["note", "text"]) || ""

    case ReviewNotes.post(socket.assigns.viewer, socket.assigns.canvas.id, %{
           vote: socket.assigns.vote,
           text: text
         }) do
      {:ok, note} ->
        {:noreply,
         socket
         |> stream_insert(:notes, note, at: 0)
         |> assign(:notes_count, socket.assigns.notes_count + 1)
         |> assign(:vote, nil)
         |> assign(:note_form, note_form(""))
         |> put_flash(:info, "Sent to task · " <> task_title(socket.assigns.task))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp task_title(%{title: title}) when is_binary(title), do: title
  defp task_title(_task), do: "this build's task"

  # The node after a write: the live document's copy (the row persists
  # asynchronously), else ours with the new threshold.
  defp live_node(canvas_id, node_id, node, warn_ms) do
    fallback = put_in(node, [Access.key("props", %{}), "latency_warn_ms"], warn_ms)

    case CanvasServer.describe(canvas_id) do
      {:ok, %{document: document}} ->
        case find_node(document, node_id) do
          %{"type" => "game_stream"} = live -> live
          _ -> fallback
        end

      _ ->
        fallback
    end
  end

  defp find_node(%{"root" => root}, id), do: find_in(root, id)
  defp find_node(_document, _id), do: nil
  defp find_in(%{"id" => id} = node, id), do: node

  defp find_in(%{"children" => children}, id) when is_list(children),
    do: Enum.find_value(children, &find_in(&1, id))

  defp find_in(_node, _id), do: nil

  # The app shell's broadcasts reach this nested LiveView too.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(%{available?: false} = assigns) do
    ~H"""
    <div
      id="game-view"
      phx-hook="GameViewDialog"
      data-fullscreen-viewer
      role="dialog"
      aria-modal="true"
      aria-label="Game"
      class="game-view fixed inset-0 z-50 flex flex-col items-center justify-center gap-4 bg-stage text-on-viewer lg:static lg:z-auto lg:h-full"
    >
      <p data-role="game-unavailable" class="text-sm text-on-viewer">This game isn't available.</p>
      <.link navigate={@from} data-role="game-back" class="btn btn-ghost text-on-viewer">
        <.icon name="hero-chevron-left" class="size-4" /> Back
      </.link>
    </div>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:tabs, @tabs)
      |> assign(:tab_labels, @tab_labels)
      |> assign(:streaming?, assigns.tracked_state == "live")
      |> assign(:warn_choices, @warn_choices)
      |> assign(:default_warn_ms, @default_warn_ms)

    ~H"""
    <div
      id="game-view"
      phx-hook="GameViewDialog"
      data-fullscreen-viewer
      role="dialog"
      aria-modal="true"
      aria-label="Game"
      class="game-view fixed inset-0 z-50 flex flex-col bg-stage text-on-viewer lg:static lg:z-auto lg:h-full lg:min-h-0 lg:bg-base-100 lg:text-base-content"
    >
      <.flash kind={:info} flash={@flash} />

      <%!-- Phone top bar: safe-area top, then a 48px row on the stage. --%>
      <header
        data-role="game-topbar"
        data-game-landscape-hide
        class="pt-[env(safe-area-inset-top)] lg:hidden"
      >
        <div class="flex h-12 items-center gap-1 px-2">
          <.link
            navigate={@from}
            data-role="game-back"
            aria-label="Back"
            class="flex size-10 shrink-0 items-center justify-center rounded-full text-on-viewer active:bg-on-viewer/10"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <div class="min-w-0 flex-1 text-center">
            <p class="truncate text-[14px] font-semibold text-on-viewer">
              <span data-role="game-title">{@title}</span><span
                :if={@sha7}
                data-role="game-build"
                class="ml-1.5 rounded-full bg-on-viewer/10 px-[7px] py-0.5 align-middle text-[10px] font-bold tracking-[.05em] text-on-viewer"
              >build {@sha7}</span>
            </p>
            <p data-role="game-sub" class="truncate text-xs text-on-viewer/70">
              {sub_line(@state_word, @space_name)}
            </p>
          </div>
          <button
            id="game-share-phone"
            type="button"
            phx-hook="GameViewShare"
            data-share-url={@share_url}
            data-role="game-share"
            aria-label="Share build link"
            class="flex size-10 shrink-0 items-center justify-center rounded-full text-on-viewer active:bg-on-viewer/10"
          >
            <.icon name="hero-arrow-up-tray" class="size-5" />
          </button>
        </div>
      </header>

      <%!-- Desktop header, in the shell's main pane beside the rail. --%>
      <header
        data-role="game-header"
        class="hidden min-w-0 items-center gap-3 border-b border-edge bg-base-100 px-4 py-2 lg:flex"
      >
        <.link
          navigate={@from}
          data-role="game-back-desktop"
          class="btn btn-ghost btn-sm shrink-0 text-base-content"
        >
          <.icon name="hero-chevron-left" class="size-4" /> {@space_name || "Back"}
        </.link>
        <div class="min-w-0 flex-1">
          <p class="flex min-w-0 items-center gap-2">
            <span class="truncate font-semibold text-base-content">{@title}</span>
            <span
              :if={@sha7}
              data-role="game-build-desktop"
              class="badge badge-sm shrink-0 border-base-300 bg-base-300 text-base-content"
            >
              build {@sha7}
            </span>
          </p>
          <p data-role="game-sub-desktop" class="truncate text-xs text-subtle">
            {@state_word} · review build of the task branch
          </p>
        </div>
        <.link
          :if={@task}
          navigate={"/tasks/" <> @task.id}
          data-role="game-task"
          class="btn btn-ghost btn-sm shrink-0 text-base-content"
        >
          Task: {@task.title}
        </.link>
        <button
          id="game-share-desktop"
          type="button"
          phx-hook="GameViewShare"
          data-share-url={@share_url}
          data-role="game-share-desktop"
          class="btn btn-ghost btn-sm shrink-0 text-base-content"
        >
          Copy build link
        </button>
        <button
          type="button"
          data-role="game-fill-toggle"
          aria-label="Fill the pane"
          aria-pressed="false"
          phx-click={
            JS.toggle_class("game-stage--fill", to: "#game-stage")
            |> JS.toggle_attribute({"aria-pressed", "true", "false"})
          }
          class="btn btn-ghost btn-sm btn-square shrink-0 text-base-content"
        >
          <.icon name="hero-arrows-pointing-out" class="size-4" />
        </button>
      </header>

      <div class="flex min-h-0 flex-1 flex-col lg:grid lg:grid-cols-[1fr_340px]">
        <div
          data-role="game-stage-column"
          class="game-stage-column flex flex-col lg:min-h-0 lg:overflow-y-auto lg:bg-stage lg:p-4 lg:text-on-viewer"
        >
          <div class="game-stage-box flex flex-col lg:min-h-0 lg:flex-1 lg:justify-center">
            <div
              id="game-stage"
              data-role="game-stage"
              class="game-stage relative mx-3 overflow-hidden rounded-box bg-stage lg:mx-0"
            >
              <GameStreamKind.render
                node={@node}
                canvas_id={@canvas.id}
                dom_id_scope="game-view"
                chrome={:stage}
              />
              <span
                data-role="game-caption"
                data-game-landscape-hide
                class="pointer-events-none absolute top-2 right-2 rounded-sm bg-shade px-[7px] py-[3px] text-xs text-on-viewer/70 lg:hidden"
              >
                ⟳ landscape ok
              </span>
              <span
                data-role="game-caption-desktop"
                class="pointer-events-none absolute top-2 right-2 hidden rounded-sm bg-shade px-[7px] py-[3px] text-xs text-on-viewer/70 lg:inline"
              >
                ⟳ 16:9 · resizes with the pane
              </span>
            </div>
          </div>
          <p
            data-role="game-status"
            data-game-landscape-hide
            class="flex items-center gap-2 px-4 pt-2 text-sm text-on-viewer/70 lg:px-1"
          >
            <span class="size-2 shrink-0 rounded-full bg-success" aria-hidden="true"></span>
            {if @streaming?, do: "streaming", else: "stream ready"}
          </p>
        </div>

        <section
          data-role="game-drawer"
          data-game-landscape-hide
          class="mt-2 flex min-h-0 flex-1 flex-col rounded-t-box border-t border-edge bg-base-100 text-base-content lg:mt-0 lg:rounded-none lg:border-t-0 lg:border-l"
        >
          <div
            class="mx-auto mt-2.5 mb-1.5 h-1 w-[38px] shrink-0 rounded-full bg-edge lg:hidden"
            aria-hidden="true"
          >
          </div>
          <div
            role="tablist"
            aria-label="Game"
            class="flex shrink-0 gap-1.5 px-4 pb-2 lg:border-b lg:border-edge lg:p-3"
          >
            <button
              :for={tab <- @tabs}
              id={"game-tab-" <> tab}
              type="button"
              role="tab"
              aria-selected={to_string(@tab == tab)}
              aria-controls={"game-tab-body-" <> tab}
              phx-click="game_tab"
              phx-value-tab={tab}
              class={[
                "h-8 rounded-field border px-3 text-sm",
                if(@tab == tab,
                  do: "border-base-300 bg-base-300 text-base-content",
                  else: "border-edge text-subtle"
                )
              ]}
            >
              {@tab_labels[tab]}
            </button>
          </div>
          <div class="min-h-0 flex-1 overflow-y-auto px-4 pb-[calc(1rem+env(safe-area-inset-bottom))] lg:pt-3">
            <div
              :for={tab <- @tabs}
              id={"game-tab-body-" <> tab}
              role="tabpanel"
              aria-labelledby={"game-tab-" <> tab}
              data-role={"game-tab-body-" <> tab}
              hidden={@tab != tab}
            >
              <.settings_body
                :if={tab == "settings"}
                sha7={@sha7}
                task={@task}
                warn_ms={(@node["props"] || %{})["latency_warn_ms"] || @default_warn_ms}
                warn_choices={@warn_choices}
                writer?={@writer?}
                restart_to={restart_target(@node, @tracked_state)}
              />
              <.insights_body
                :if={tab == "insights"}
                samples={@samples}
                runs_today={@runs_today}
                runs_count={@runs_count}
                streams={@streams}
              />
              <.review_body
                :if={tab == "review"}
                sha7={@sha7}
                task_title={task_title(@task)}
                vote={@vote}
                form={@note_form}
                notes_count={@notes_count}
                streams={@streams}
              />
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  # ── Settings ─────────────────────────────────────────────────────────────

  @seg_base "h-7 rounded-field border px-2.5 text-sm disabled:opacity-40"
  @seg_pressed "border-base-300 bg-base-300 text-base-content"
  @seg_unpressed "border-edge text-subtle"

  defp seg_class(true), do: [@seg_base, @seg_pressed]
  defp seg_class(false), do: [@seg_base, @seg_unpressed]

  # The click Restart dispatches: the node's own "Start again" button in the
  # panel now showing (ended or failed). nil otherwise, and Restart is off.
  defp restart_target(node, state) when state in ~w(ended failed),
    do:
      "#" <>
        GameStreamKind.wrapper_id(node, "game-view") <>
        ~s( [data-gs-panel="#{state}"] [data-gs-restart])

  defp restart_target(_node, _state), do: nil

  attr :sha7, :any, required: true
  attr :task, :any, required: true
  attr :warn_ms, :any, required: true
  attr :warn_choices, :list, required: true
  attr :writer?, :boolean, required: true
  attr :restart_to, :any, required: true

  defp settings_body(assigns) do
    ~H"""
    <div data-role="game-settings">
      <div
        data-role="game-set-build"
        class="flex items-center justify-between gap-3 border-b border-edge py-2.5 text-[14px] text-base-content"
      >
        <span class="min-w-0">
          Review build
          <small data-role="game-set-build-small" class="block text-xs text-subtle">
            {build_small(@sha7, @task)}
          </small>
        </span>
        <span :if={@sha7} class="flex shrink-0 gap-1">
          <button
            type="button"
            data-role="game-build-seg"
            aria-pressed="true"
            aria-disabled="true"
            class={seg_class(true)}
          >
            {@sha7}
          </button>
        </span>
      </div>

      <div
        data-role="game-set-warn"
        class="flex items-center justify-between gap-3 border-b border-edge py-2.5 text-[14px] text-base-content"
      >
        <span class="min-w-0">
          Latency warning
          <small class="block text-xs text-subtle">
            input-to-photon<span class="lg:hidden"> · warns above</span>
          </small>
          <small
            :if={not @writer?}
            data-role="game-set-warn-note"
            class="block text-xs text-subtle"
          >
            Only members of this canvas's space can change this.
          </small>
        </span>
        <span class="flex shrink-0 gap-1">
          <button
            :for={ms <- @warn_choices}
            id={"game-warn-#{ms}"}
            type="button"
            data-role="game-warn-seg"
            phx-click="game_latency_warn"
            phx-value-ms={ms}
            aria-pressed={to_string(@warn_ms == ms)}
            disabled={not @writer?}
            class={seg_class(@warn_ms == ms)}
          >
            {ms} ms
          </button>
        </span>
      </div>

      <div
        data-role="game-set-restart"
        class="flex items-center justify-between gap-3 py-2.5 text-[14px] text-base-content"
      >
        <span class="min-w-0">Restart with these settings</span>
        <button
          id="game-restart"
          type="button"
          data-role="game-restart"
          disabled={not (@writer? and is_binary(@restart_to))}
          phx-click={@writer? && @restart_to && JS.dispatch("click", to: @restart_to)}
          class="h-9 shrink-0 rounded-field border border-edge bg-base-100 px-3.5 text-sm text-base-content disabled:opacity-40"
        >
          Restart
        </button>
      </div>
    </div>
    """
  end

  defp build_small(sha7, _task) when not is_binary(sha7), do: "task branch tip"
  defp build_small(sha7, nil), do: "task branch tip · sha " <> sha7
  defp build_small(sha7, task), do: "task branch tip · sha " <> sha7 <> " · " <> task.status

  # ── Insights ─────────────────────────────────────────────────────────────

  attr :samples, :list, required: true
  attr :runs_today, :integer, required: true
  attr :runs_count, :integer, required: true
  attr :streams, :any, required: true

  defp insights_body(assigns) do
    last = List.last(assigns.samples)

    assigns =
      assigns
      |> assign(:last, last)
      |> assign(:fps_points, spark_points(Enum.map(assigns.samples, & &1.fps_avg)))
      |> assign(:lat_points, spark_points(Enum.map(assigns.samples, & &1.rtt_p50_ms)))

    ~H"""
    <div data-role="game-insights">
      <div class="my-2 grid grid-cols-3 gap-2">
        <div data-role="game-tile-fps" class={tile_class()}>
          <b class={tile_value_class()}>{fmt_n(@last && @last.fps_avg)}</b>
          <span class="text-xs text-subtle">fps now</span>
        </div>
        <div data-role="game-tile-latency" class={tile_class()}>
          <b class={tile_value_class()}>{fmt_ms(@last && @last.rtt_p50_ms)}</b>
          <span class="text-xs text-subtle">{latency_label(@last)}</span>
        </div>
        <div data-role="game-tile-runs" class={tile_class()}>
          <b class={tile_value_class()}>{@runs_today}</b>
          <span class="text-xs text-subtle">runs today</span>
        </div>
      </div>

      <.section_label>FPS · last 2 min</.section_label>
      <.spark role="game-spark-fps" points={@fps_points} stroke="stroke-success" />

      <.section_label>Latency · last 2 min</.section_label>
      <.spark role="game-spark-latency" points={@lat_points} stroke="stroke-warning" />

      <.section_label>Session timeline</.section_label>
      <div id="game-timeline" data-role="game-timeline" phx-update="stream">
        <div
          :for={{id, ev} <- @streams.timeline}
          id={id}
          data-role="game-ev"
          class="border-b border-edge py-1 font-mono text-sm text-subtle"
        >
          <b class="mr-2 font-semibold text-base-content">{ev.at}</b>play host: {ev.state}
        </div>
      </div>

      <.section_label>Recent runs</.section_label>
      <p :if={@runs_count == 0} data-role="game-runs-empty" class="py-2 text-sm text-subtle">
        No finished runs yet.
      </p>
      <div id="game-runs" data-role="game-runs" phx-update="stream">
        <div
          :for={{id, run} <- @streams.runs}
          id={id}
          data-role="game-run"
          class="flex items-center gap-2 border-b border-edge py-2 text-sm text-base-content"
        >
          <span data-role="game-run-main">{run_main(run)}</span>
          <small data-role="game-run-small" class="ml-auto text-xs text-subtle">
            {run_small(run)}
          </small>
        </div>
      </div>
    </div>
    """
  end

  # ── Review ───────────────────────────────────────────────────────────────

  @vote_base "flex size-11 shrink-0 items-center justify-center rounded-field border bg-base-200 text-lg lg:size-[38px]"
  @vote_pressed "border-primary bg-primary/15"
  @vote_unpressed "border-edge"

  defp vote_class(true), do: [@vote_base, @vote_pressed]
  defp vote_class(false), do: [@vote_base, @vote_unpressed]

  attr :sha7, :any, required: true
  attr :task_title, :string, required: true
  attr :vote, :any, required: true
  attr :form, :any, required: true
  attr :notes_count, :integer, required: true
  attr :streams, :any, required: true

  defp review_body(assigns) do
    assigns = assign(assigns, :votes, [{"up", "👍", "Looks good"}, {"down", "👎", "Needs work"}])

    ~H"""
    <div data-role="game-review">
      <.form
        for={@form}
        id="game-note-form"
        phx-change="game_note_change"
        phx-submit="game_note_submit"
        class="mt-1.5 mb-2.5 flex items-center gap-2"
      >
        <button
          :for={{vote, glyph, label} <- @votes}
          id={"game-vote-" <> vote}
          type="button"
          data-role="game-vote"
          phx-click="game_vote"
          phx-value-vote={vote}
          aria-pressed={to_string(@vote == vote)}
          aria-label={label}
          class={vote_class(@vote == vote)}
        >
          {glyph}
        </button>
        <input
          type="text"
          id="game-note-input"
          name={@form[:text].name}
          value={@form[:text].value}
          data-role="game-note-input"
          placeholder="Note for the build (goes to the task)"
          aria-label="Review note"
          maxlength="500"
          autocomplete="off"
          class="h-11 min-w-0 flex-1 rounded-field border border-edge bg-base-200 px-3 text-base-content placeholder:text-subtle lg:h-[38px]"
        />
        <button
          type="submit"
          data-role="game-note-send"
          class="h-11 shrink-0 rounded-field bg-primary px-3.5 font-semibold text-primary-content lg:h-[38px]"
        >
          → task
        </button>
      </.form>

      <.section_label>Review notes on build {@sha7}</.section_label>
      <p
        :if={@notes_count == 0}
        data-role="game-notes-empty"
        class="py-6 text-center text-sm text-subtle"
      >
        No notes yet. Thumbs + a line is enough; it lands on the task "{@task_title}".
      </p>
      <div id="game-notes" data-role="game-notes" phx-update="stream">
        <div
          :for={{id, note} <- @streams.notes}
          id={id}
          data-role="game-note"
          class="flex items-center gap-2 border-b border-edge py-2 text-sm text-base-content"
        >
          <span data-role="game-note-main" class="min-w-0 break-words">
            {ReviewNotes.glyph(note.vote)} {note.text}
          </span>
          <small data-role="game-note-small" class="ml-auto shrink-0 text-xs text-subtle">
            {Calendar.strftime(note.inserted_at, "%H:%M")} · → task
          </small>
        </div>
      </div>
    </div>
    """
  end

  defp tile_class, do: "rounded-sm border border-edge bg-base-200 px-2.5 py-2"
  defp tile_value_class, do: "block text-[17px] font-semibold text-base-content"

  slot :inner_block, required: true

  defp section_label(assigns) do
    ~H"""
    <p
      data-role="game-section-label"
      class="mt-3 text-xs font-semibold uppercase tracking-[.08em] text-subtle"
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr :role, :string, required: true
  attr :points, :any, required: true
  attr :stroke, :string, required: true

  defp spark(assigns) do
    assigns = assign(assigns, w: @spark_w, h: @spark_h)

    ~H"""
    <svg
      :if={@points}
      data-role={@role}
      class="my-2 block h-16 w-full rounded-sm border border-edge bg-base-200 lg:h-[60px]"
      viewBox={"0 0 #{@w} #{@h}"}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <polyline points={@points} fill="none" class={@stroke} stroke-width="2" />
    </svg>
    <p :if={!@points} data-role={@role <> "-empty"} class="my-2 text-sm text-subtle">
      Stats appear while you play.
    </p>
    """
  end

  @doc false
  # The masters' spark(): x spread over the width, y scaled between the
  # series' min and max with a 4px foot. nil below two values.
  def spark_points(values) do
    values = Enum.reject(values, &is_nil/1)
    n = length(values)

    if n < 2 do
      nil
    else
      {min, max} = Enum.min_max(values)
      span = if max - min == 0, do: 1, else: max - min

      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        x = i / (n - 1) * @spark_w
        y = @spark_h - 4 - (v - min) / span * (@spark_h - 10)
        "#{fmt1(x)},#{fmt1(y)}"
      end)
    end
  end

  defp fmt1(f), do: :erlang.float_to_binary(f / 1, decimals: 1)

  defp fmt_n(nil), do: "—"
  defp fmt_n(n), do: Integer.to_string(round(n))

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(n), do: Integer.to_string(round(n)) <> "ms"

  defp latency_label(%{rtt_p50_ms: p50, rtt_p95_ms: p95}) when is_number(p50) and is_number(p95),
    do: "input→photon · p95 " <> Integer.to_string(round(p95))

  defp latency_label(_last), do: "input→photon"

  defp run_main(run) do
    reason = if is_binary(run.ended_reason) and run.ended_reason != "", do: run.ended_reason

    (reason || run.ended_state) <>
      " · " <> m_ss(DateTime.diff(run.ended_at, run.started_at, :millisecond))
  end

  defp run_small(run) do
    case run.fps_avg do
      fps when is_number(fps) -> when_text(run.ended_at) <> " · #{round(fps)}fps avg"
      _ -> when_text(run.ended_at)
    end
  end

  # HH:MM today, "yesterday", else the date (UTC: the session rows carry no
  # viewer time zone).
  defp when_text(%DateTime{} = at) do
    today = Date.utc_today()

    case Date.diff(today, DateTime.to_date(at)) do
      0 -> Calendar.strftime(at, "%H:%M")
      1 -> "yesterday"
      _ -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end

  defp m_ss(ms) when is_integer(ms) and ms >= 0 do
    total = div(ms, 1000)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp m_ss(_ms), do: "0:00"

  defp sub_line(state_word, nil), do: state_word <> " · review build of the task branch"

  defp sub_line(state_word, space_name),
    do: state_word <> " · review build of the task branch · " <> space_name
end
