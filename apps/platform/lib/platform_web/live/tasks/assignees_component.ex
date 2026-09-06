defmodule PlatformWeb.Tasks.AssigneesComponent do
  @moduledoc """
  The per-phase Assignees concern of the Tasks surface, extracted from
  `PlatformWeb.TasksLive` by task 01a008f6 stage 5.

  Owns the per-phase assignee modal (simple/advanced mode toggle, the
  agent pickers, save) — one render region and four events.

  ## Ownership

    * Assigns owned here: `:show_assignee_modal`, `:assignee_modal_mode`.
    * `selected_task` and `agents` arrive as **read-only attrs**. The
      component never writes them: a successful save is reported up with
      `send(self(), {:assignees_saved, task_id})` and the shell reloads
      the task, refreshes the board and flashes.
    * The modal is opened by a button in `TaskDetailComponent`, which
      therefore carries `phx-target="#tasks-assignees"` — LiveComponent
      events are only delivered to the component when explicitly
      targeted.

  `stack_clear_member_override` is NOT here: stage 3 placed it in
  `PlatformWeb.Tasks.StacksComponent`, which is where it belongs (it is
  only reachable from stack detail).
  """
  use PlatformWeb, :live_component

  alias Platform.Tasks

  import PlatformWeb.Tasks.PhaseAssigneeParams, only: [phase_entry: 1, all_phases_same_agent?: 1]
  import PlatformWeb.Tasks.StatusLabels, only: [phase_label: 1]
  import PlatformWeb.Tasks.TaskDisplay, only: [phase_assignee_id: 2, current_phase_label: 1]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:show_assignee_modal, false)
     |> assign(:assignee_modal_mode, :simple)}
  end

  @impl true
  def update(%{open: true}, socket) do
    {:ok,
     socket
     |> assign(:show_assignee_modal, true)
     |> assign(:assignee_modal_mode, initial_mode(socket.assigns[:selected_task]))}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <%!-- Per-phase assignee modal (mobile-first; full-screen sheet on small,
             centered dialog on >=sm) --%>
      <div
        :if={@show_assignee_modal && @selected_task}
        class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
        id="assignee-modal"
      >
        <%!-- Backdrop --%>
        <div
          class="absolute inset-0 bg-black/40"
          phx-click="close_assignee_modal"
          phx-target={@myself}
        />

        <%!-- Sheet / dialog --%>
        <div class="relative w-full max-w-lg rounded-t-2xl sm:rounded-2xl bg-base-100 shadow-2xl pb-[env(safe-area-inset-bottom)] max-h-[90vh] overflow-y-auto">
          <%!-- Header --%>
          <div class="flex items-center justify-between border-b border-edge px-4 py-3">
            <div>
              <h2 class="text-base font-semibold">Assign Agents</h2>
              <p class="mt-0.5 text-xs text-base-content/60">
                {@selected_task.title}
              </p>
            </div>
            <button
              type="button"
              phx-click="close_assignee_modal"
              phx-target={@myself}
              class="btn btn-sm btn-ghost btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <%!-- Mode toggle (segmented) --%>
          <div class="flex items-center justify-between px-4 py-3 border-b border-edge gap-3">
            <p class="text-xs text-base-content/60 leading-snug">
              {if @assignee_modal_mode == :advanced,
                do: "One agent per phase. Build the DAG.",
                else: "One agent for the whole task."}
            </p>
            <div class="join shrink-0">
              <button
                type="button"
                phx-click="set_assignee_modal_mode"
                phx-target={@myself}
                phx-value-mode="simple"
                class={[
                  "btn btn-sm join-item",
                  @assignee_modal_mode == :simple && "btn-primary",
                  @assignee_modal_mode != :simple && "btn-ghost"
                ]}
                aria-pressed={if @assignee_modal_mode == :simple, do: "true", else: "false"}
              >
                Simple
              </button>
              <button
                type="button"
                phx-click="set_assignee_modal_mode"
                phx-target={@myself}
                phx-value-mode="advanced"
                class={[
                  "btn btn-sm join-item",
                  @assignee_modal_mode == :advanced && "btn-primary",
                  @assignee_modal_mode != :advanced && "btn-ghost"
                ]}
                aria-pressed={if @assignee_modal_mode == :advanced, do: "true", else: "false"}
              >
                Advanced
              </button>
            </div>
          </div>

          <%!-- Form body --%>
          <form
            id="task-assignees-form"
            phx-hook="ButtonLoading"
            phx-target={@myself}
            phx-submit="save_assignees"
            class="flex flex-col gap-3 px-4 py-4"
          >
            <%!-- Simple mode --%>
            <div :if={@assignee_modal_mode == :simple} class="flex flex-col gap-1">
              <label class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                Agent (all phases)
              </label>
              <select
                name="assignees[all]"
                class="select select-bordered select-sm w-full"
              >
                <option value="">Unassigned</option>
                <option
                  :for={agent <- @agents}
                  value={agent.id}
                  selected={
                    phase_assignee_id(@selected_task, "execution") == agent.id ||
                      (is_nil(phase_assignee_id(@selected_task, "execution")) &&
                         @selected_task.assignee_id == agent.id)
                  }
                >
                  {agent.name}
                </option>
              </select>
            </div>

            <%!-- Advanced mode: per-phase pickers --%>
            <div :if={@assignee_modal_mode == :advanced} class="flex flex-col gap-3">
              <div :for={phase <- ~w(planning execution review)} class="flex flex-col gap-1">
                <label class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-base-content/60">
                  <span>{phase_label(phase)}</span>
                  <span
                    :if={phase == current_phase_label(@selected_task)}
                    class="badge badge-primary badge-xs"
                  >
                    Current
                  </span>
                </label>
                <select
                  name={"assignees[" <> phase <> "]"}
                  class="select select-bordered select-sm w-full"
                >
                  <option value="">Unassigned</option>
                  <option
                    :for={agent <- @agents}
                    value={agent.id}
                    selected={phase_assignee_id(@selected_task, phase) == agent.id}
                  >
                    {agent.name}
                  </option>
                </select>
              </div>

              <p class="mt-1 text-[11px] text-base-content/50">
                The current-phase agent is the one the task router dispatches to right now.
                When the task transitions across phases, the assignee is updated automatically.
              </p>
            </div>

            <%!-- Actions --%>
            <div class="mt-2 flex justify-end gap-2 border-t border-edge pt-3">
              <button
                type="button"
                phx-click="close_assignee_modal"
                phx-target={@myself}
                class="btn btn-sm btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-sm btn-primary">Save</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("open_assignee_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_assignee_modal, true)
     |> assign(:assignee_modal_mode, initial_mode(socket.assigns.selected_task))}
  end

  def handle_event("close_assignee_modal", _params, socket) do
    {:noreply, assign(socket, :show_assignee_modal, false)}
  end

  def handle_event("set_assignee_modal_mode", %{"mode" => mode}, socket) do
    next =
      case mode do
        "advanced" -> :advanced
        _ -> :simple
      end

    {:noreply, assign(socket, :assignee_modal_mode, next)}
  end

  def handle_event("save_assignees", %{"assignees" => params}, socket) do
    task = socket.assigns.selected_task

    if is_nil(task) do
      {:noreply, socket}
    else
      save(socket, task, params)
    end
  end

  defp save(socket, task, params) do
    attrs_by_phase = attrs_by_phase(socket.assigns.assignee_modal_mode, params)

    # An individual assignment from this modal protects the task from
    # stack-level fan-out — stamp `metadata["assignee_override"] = true`
    # so `Stacks.set_stack_phase_assignees/2` skips it.
    result =
      with {:ok, updated} <- Tasks.set_phase_assignees(task, attrs_by_phase) do
        Tasks.update_task(updated, %{
          metadata: Map.put(updated.metadata || %{}, "assignee_override", true)
        })
      end

    case result do
      {:ok, _} ->
        send(self(), {:assignees_saved, task.id})
        {:noreply, assign(socket, :show_assignee_modal, false)}

      {:error, _} ->
        send(self(), {:assignees_save_failed})
        {:noreply, socket}
    end
  end

  defp attrs_by_phase(:simple, params) do
    entry = phase_entry(Map.get(params, "all", ""))
    %{"planning" => entry, "execution" => entry, "review" => entry}
  end

  defp attrs_by_phase(:advanced, params) do
    %{
      "planning" => phase_entry(Map.get(params, "planning", "")),
      "execution" => phase_entry(Map.get(params, "execution", "")),
      "review" => phase_entry(Map.get(params, "review", ""))
    }
  end

  defp initial_mode(%{phase_assignees: pa}) when is_map(pa) and map_size(pa) > 0 do
    if all_phases_same_agent?(pa), do: :simple, else: :advanced
  end

  defp initial_mode(_), do: :simple
end
