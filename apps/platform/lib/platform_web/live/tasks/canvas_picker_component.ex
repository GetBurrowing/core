defmodule PlatformWeb.Tasks.CanvasPickerComponent do
  @moduledoc """
  The canvas picker behind the '+ Attach canvas' row (task 01a1559a stage 3,
  design direction canvas `01a1559b-416c-7000-87a5-b03fe5985128`, inventory
  rows 1-7).

  The hard part of attaching is PICKING: canvases are a flat list and many
  share near-identical titles. So every picker row carries a meta line that is
  always shown, `#<space> · edited <Mon D>`, and an execution space (whose
  name is the same opaque `task-exec-<hex>` for all of them) shows the title
  of the task it belongs to instead.

  ## Modes

    * `:task` (stage 3) — the task detail panel. `attached` holds the canvas
      ids already on the task, each with count 1, and `member_count` is 1.
    * `:stack` (stage 4) — the stack view. `attached` maps a canvas id to the
      number of members carrying it and `member_count` is the stack's size: a
      canvas on every member is checked and disabled, a partially covered one
      stays selectable and its meta adds `on K of M tasks`.

  The component never writes an attachment. Picking pushes `pick_event`
  (with `canvas-id`) to `pick_target`, the parent component that owns the
  write and its gate, and closes the picker.

  ## Where the candidate list comes from

  Candidates are the canvases in the spaces the viewer participates in
  (`Chat.list_user_conversations/2`, scoped by the viewer's `access_scope`),
  which is how the chat canvas explorer derives its space ids
  (`PlatformWeb.ChatLive.CanvasHooks.explorer_space_ids/1`). A participant
  reads every canvas in its space (`Platform.Chat.CanvasAccess`'s `:member`
  path), so nothing listed here is a canvas the viewer cannot open. Every
  space id is DB-derived: neither `Chat.search_canvases/3` nor
  `Chat.list_recent_canvases/2` is cast-safe on its space ids, and no event
  handler here reads a space id from params. The query is the only
  client-supplied input, and it is bound as text.

  An already-attached canvas is NOT hidden: it renders checked and
  `aria-disabled`, with no click handler, because hiding it makes people
  think the search is broken.
  """
  use PlatformWeb, :live_component

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias PlatformWeb.Tasks.Selection

  @limit 25

  @doc false
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open?, false)
     |> assign(:query, "")
     |> assign(:candidates, [])}
  end

  @doc false
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:mode, fn -> :task end)
     |> assign_new(:label, fn -> "Attach canvas" end)
     |> assign_new(:attached, fn -> %{} end)
     |> assign_new(:member_count, fn -> 1 end)}
  end

  @doc false
  def handle_event("picker_open", _params, socket) do
    {:noreply,
     socket
     |> assign(:open?, true)
     |> assign(:query, "")
     |> load_candidates("")}
  end

  def handle_event("picker_close", _params, socket) do
    {:noreply, socket |> assign(:open?, false) |> assign(:query, "") |> assign(:candidates, [])}
  end

  def handle_event("picker_search", %{"query" => query}, socket) when is_binary(query) do
    {:noreply, socket |> assign(:query, query) |> load_candidates(query)}
  end

  def handle_event("picker_search", _params, socket), do: {:noreply, socket}

  # ── Candidates ───────────────────────────────────────────────────────────

  defp load_candidates(socket, query) do
    spaces = viewer_spaces(socket)
    space_ids = Enum.map(spaces, & &1.id)
    opts = [limit: @limit] ++ access_scope_opts(socket)

    canvases =
      if String.trim(query) == "" do
        Chat.list_recent_canvases(space_ids, opts)
      else
        space_ids |> Chat.search_canvases(query, opts) |> Enum.map(& &1.canvas)
      end

    assign(socket, :candidates, build_rows(socket, canvases, spaces))
  end

  # DB-derived only: the spaces the viewer is a user participant of. Never a
  # space id from params (see the moduledoc).
  defp viewer_spaces(socket) do
    case socket.assigns[:current_user_id] do
      user_id when is_binary(user_id) ->
        Chat.list_user_conversations(user_id, scope: socket.assigns[:access_scope])

      _ ->
        []
    end
  end

  defp build_rows(socket, canvases, spaces) do
    spaces_by_id = Map.new(spaces, &{&1.id, &1})
    task_titles = readable_task_titles(socket, spaces)

    Enum.map(canvases, fn canvas ->
      space = Map.get(spaces_by_id, canvas.space_id)

      %{
        id: canvas.id,
        title: canvas.title,
        place: Map.get(task_titles, canvas.space_id) || space_name(space),
        edited_on: edited_on(canvas.updated_at || canvas.inserted_at)
      }
    end)
  end

  # Execution spaces show their task's title, but only for a task the viewer
  # may `tasks.read`; otherwise the row keeps the space's own name.
  defp readable_task_titles(socket, spaces) do
    exec_spaces = Enum.filter(spaces, &ExecutionSpace.task_id/1)
    titles = ExecutionSpace.task_titles(exec_spaces)
    scope = socket.assigns[:access_scope]

    for space <- exec_spaces,
        title = Map.get(titles, space.id),
        Selection.readable_task?(scope, ExecutionSpace.task_id(space)),
        into: %{},
        do: {space.id, title}
  end

  defp space_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp space_name(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp space_name(_space), do: "conversation"

  defp edited_on(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d")
  defp edited_on(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%b %-d")
  defp edited_on(_at), do: ""

  defp access_scope_opts(socket) do
    case socket.assigns[:access_scope] do
      %Platform.Access.Scope{} = scope -> [access_scope: scope]
      _ -> []
    end
  end

  # ── Row state ────────────────────────────────────────────────────────────

  defp attached_count(attached, canvas_id), do: Map.get(attached, canvas_id, 0)

  # Fully attached: on the task (task mode), or on every member (stack mode).
  defp fully_attached?(attached, member_count, canvas_id),
    do: member_count > 0 and attached_count(attached, canvas_id) >= member_count

  defp coverage_suffix(:stack, attached, member_count, canvas_id) do
    case attached_count(attached, canvas_id) do
      k when k > 0 and k < member_count -> " · on #{k} of #{member_count} tasks"
      _ -> ""
    end
  end

  defp coverage_suffix(_mode, _attached, _member_count, _canvas_id), do: ""

  defp trigger_role(:stack), do: "canvas-picker-trigger-stack"
  defp trigger_role(_mode), do: "canvas-picker-trigger"

  # ── Render ───────────────────────────────────────────────────────────────

  @doc false
  def render(assigns) do
    ~H"""
    <div id={@id} class="relative w-full" data-role="canvas-picker-anchor">
      <button
        type="button"
        phx-click="picker_open"
        phx-target={@myself}
        class="flex w-full min-h-9 items-center gap-2 rounded px-2 py-1.5 text-left text-sm font-medium text-base-content hover:bg-base-200"
        data-role={trigger_role(@mode)}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open?)}
      >
        <span class="hero-plus size-4 shrink-0"></span>
        <span class="min-w-0 truncate">{@label}</span>
      </button>

      <div :if={@open?} phx-window-keydown="picker_close" phx-key="Escape" phx-target={@myself}>
        <%!-- Phones only: the sheet's backdrop. From sm up the panel is a
             popover anchored to the row and there is no backdrop. --%>
        <div
          class="fixed inset-0 z-40 bg-black/40 sm:hidden"
          phx-click="picker_close"
          phx-target={@myself}
          data-role="canvas-picker-backdrop"
        >
        </div>

        <%!-- ONE panel, two placements: a bottom sheet below sm (fixed, the
             full row of sheet classes) and a popover anchored under the row
             from sm up. One list in the DOM, so a row is never rendered twice.
             The sheet's bottom padding adds `--bottom-nav-height` to the safe
             area: the phone bottom nav sits above z-50, and without it the
             last rows render underneath the nav (seen at 375px). --%>
        <div
          role="dialog"
          aria-label="Attach a canvas"
          phx-click-away="picker_close"
          phx-target={@myself}
          data-role="canvas-picker"
          class={[
            "z-50 flex flex-col overflow-hidden border border-edge bg-base-100 shadow-2xl",
            "fixed inset-x-0 bottom-0 mx-auto w-full max-w-lg rounded-t-2xl max-h-[75vh] pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]",
            "sm:absolute sm:inset-x-auto sm:bottom-auto sm:left-0 sm:top-full sm:mt-1 sm:w-96 sm:max-w-[calc(100vw-2rem)] sm:rounded-box sm:max-h-96 sm:pb-0 sm:shadow-lg"
          ]}
        >
          <div class="mx-auto mt-2 h-1 w-10 rounded-full bg-base-300 sm:hidden" aria-hidden="true">
          </div>
          <form
            phx-change="picker_search"
            phx-submit="picker_search"
            phx-target={@myself}
            class="border-b border-edge p-2"
          >
            <label class="input input-sm flex w-full items-center gap-2">
              <span class="hero-magnifying-glass size-4 shrink-0 text-base-content/60"></span>
              <input
                type="search"
                name="query"
                value={@query}
                placeholder="Search canvases…"
                autocomplete="off"
                phx-debounce="200"
                aria-label="Search canvases"
                class="grow"
                data-role="canvas-picker-search"
                phx-mounted={JS.focus()}
              />
            </label>
          </form>

          <ul class="min-h-0 flex-1 divide-y divide-edge overflow-y-auto" role="listbox">
            <li
              :if={@candidates == []}
              class="px-3 py-4 text-sm text-base-content/70"
              data-role="canvas-picker-empty"
            >
              {if String.trim(@query) == "",
                do: "No canvases in your spaces yet.",
                else: "No canvases match."}
            </li>
            <li :for={row <- @candidates} role="presentation">
              <%= if fully_attached?(@attached, @member_count, row.id) do %>
                <div
                  role="option"
                  aria-disabled="true"
                  aria-selected="true"
                  class="flex min-w-0 items-center gap-2 px-3 py-2"
                  data-role="canvas-picker-row-attached"
                  data-canvas-id={row.id}
                >
                  <.picker_row_text row={row} suffix="" />
                  <span class="hero-check size-4 shrink-0 text-primary" aria-label="Already attached">
                  </span>
                </div>
              <% else %>
                <button
                  type="button"
                  role="option"
                  aria-selected="false"
                  phx-click={
                    JS.push(@pick_event, target: @pick_target, value: %{"canvas-id" => row.id})
                    |> JS.push("picker_close", target: @myself)
                  }
                  class="flex w-full min-w-0 items-center gap-2 px-3 py-2 text-left hover:bg-base-200 focus-visible:bg-base-200"
                  data-role="canvas-picker-row"
                  data-canvas-id={row.id}
                >
                  <.picker_row_text
                    row={row}
                    suffix={coverage_suffix(@mode, @attached, @member_count, row.id)}
                  />
                </button>
              <% end %>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :suffix, :string, required: true

  defp picker_row_text(assigns) do
    ~H"""
    <span class="flex min-w-0 flex-1 flex-col">
      <span
        class="min-w-0 truncate text-sm font-medium text-base-content"
        data-role="canvas-picker-row-title"
        title={@row.title || "(untitled)"}
      >
        {@row.title || "(untitled)"}
      </span>
      <span
        class="canvas-picker-meta text-xs font-normal tabular-nums"
        data-role="canvas-picker-row-meta"
      >
        {"#" <> @row.place} · edited {@row.edited_on}{@suffix}
      </span>
    </span>
    """
  end
end
