defmodule PlatformWeb.Tasks.SupersedeComponent do
  @moduledoc """
  The Return-to-planning ("supersede the current plan") modal, extracted
  from `PlatformWeb.TasksLive` by task 01a008f6 stage 6.

  ## What the plan asked for, and what was actually there

  The stage plan described this concern as *Reopen/Supersede* — two render
  regions that are "the two MODES of one concern", to be served by one
  component with a `mode` attr rather than two components. That shape was
  correct when the plan was written. It is not what the tree looks like at
  `74448b78`: stage 4 had already moved the **reopen** half into
  `PlatformWeb.Tasks.TaskDetailComponent`, where it lives as
  `:show_reopen_modal` / `:reopen_reason` and the four `detail_*_reopen*`
  events. Only the supersede half was still shell-resident.

  Rebuilding the two-mode component would therefore mean pulling reopen
  back OUT of a component it already landed in — churning a shipped stage
  to satisfy a line of a plan whose premise had expired. So this component
  is the supersede mode alone, and it carries no `mode` attr: a mode
  discriminator with exactly one value is a comment pretending to be code.
  If reopen ever needs to rejoin, `mode` is a two-line addition here and a
  deletion there.

  Four events, not the plan's eight (the eight counted the reopen twins):
  `supersede_open`, `supersede_close`, `supersede_reason_changed`,
  `supersede_submit`.

  ## Ownership

  Owns `:show_supersede_modal` and `:supersede_reason` outright — the shell
  holds neither. `selected_task` arrives as a read-only attr. A successful
  supersede changes the board and the selected task, so it reports up with
  `send(self(), {:supersede_completed, message})`.

  Every message to the user goes up as `{:supersede_flash, kind, message}`
  rather than through `put_flash/3` here. `put_flash/3` inside a
  LiveComponent writes to the component's own socket, which nothing
  renders — the call compiles, the test goes green on the state change, and
  the user is told nothing. Same reason `StacksComponent` uses
  `{:stacks_flash, ...}`.

  ## Render region

  `tasks_live.html.heex` 1504-1592 at `74448b78` — the shell root, one
  region. The plan's cited ranges (3680-3765, 3766-3857) were written
  against the pre-stage-2 4,906-line template and point past its end today.
  """
  use PlatformWeb, :live_component

  alias Platform.Tasks

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(:show_supersede_modal, false) |> assign(:supersede_reason, "")}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Return-to-planning modal (in-flight tasks). Same bottom-sheet /
           centered-dialog shape as the reopen modal in TaskDetailComponent;
           only the copy, event names, and destructive tone differ.
           Server-side re-validates the reason and surfaces
           `:reason_required` / `:not_in_flight` / `:no_active_plan` as
           flashes if the client check is bypassed. --%>
      <div
        :if={@show_supersede_modal && @selected_task}
        class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
        id="supersede-modal"
      >
        <%!-- Backdrop --%>
        <div class="absolute inset-0 bg-black/40" phx-click="supersede_close" phx-target={@myself} />

        <%!-- Sheet / dialog --%>
        <div class="relative w-full max-w-lg rounded-t-2xl sm:rounded-2xl bg-base-100 shadow-2xl pb-[env(safe-area-inset-bottom)] max-h-[90vh] overflow-y-auto">
          <%!-- Header --%>
          <div class="flex items-center justify-between border-b border-edge px-4 py-3">
            <div class="min-w-0">
              <h2 class="text-base font-semibold">Return to planning</h2>
              <p class="mt-0.5 text-xs text-subtle truncate">
                {@selected_task.title}
              </p>
            </div>
            <button
              type="button"
              phx-click="supersede_close"
              phx-target={@myself}
              class="btn btn-sm btn-ghost btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <%!-- Form body --%>
          <form
            id="task-supersede-form"
            phx-hook="ButtonLoading"
            phx-submit="supersede_submit"
            phx-target={@myself}
            class="flex flex-col gap-3 px-4 py-4"
          >
            <p class="text-xs text-base-content/70" data-role="supersede-explanation">
              This marks the current plan superseded and requires re-planning. Any in-flight executor will stop. The task branch and any open PR are kept intact.
            </p>

            <div class="flex flex-col gap-1">
              <label
                for="supersede-reason-textarea"
                class="text-xs font-semibold uppercase tracking-wider text-base-content"
              >
                Why is this being returned to planning?
              </label>
              <textarea
                id="supersede-reason-textarea"
                name="reason"
                data-role="supersede-reason-textarea"
                rows="5"
                phx-change="supersede_reason_changed"
                phx-target={@myself}
                placeholder="Describe what's wrong or what should change. The current plan will be marked superseded and the task will return to planning."
                class="textarea textarea-bordered w-full text-sm"
              >{@supersede_reason}</textarea>
              <p
                :if={String.trim(@supersede_reason) == ""}
                class="text-xs text-subtle"
                data-role="supersede-reason-hint"
              >
                A reason is required so the planner has context for the next revision.
              </p>
            </div>

            <div class="flex items-center justify-end gap-2 pt-1">
              <button
                type="button"
                phx-click="supersede_close"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-role="supersede-submit-button"
                class="btn btn-error btn-sm"
                disabled={String.trim(@supersede_reason) == ""}
              >
                Return to planning
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("supersede_open", _params, socket) do
    {:noreply, socket |> assign(:show_supersede_modal, true) |> assign(:supersede_reason, "")}
  end

  def handle_event("supersede_close", _params, socket) do
    {:noreply, socket |> assign(:show_supersede_modal, false) |> assign(:supersede_reason, "")}
  end

  def handle_event("supersede_reason_changed", params, socket) do
    # Accept either a top-level `reason` string or a `value` fallback so a
    # wrapping-form shape change doesn't silently drop keystrokes.
    reason =
      cond do
        is_binary(Map.get(params, "reason")) -> Map.get(params, "reason")
        is_binary(Map.get(params, "value")) -> Map.get(params, "value")
        true -> ""
      end

    {:noreply, assign(socket, :supersede_reason, reason)}
  end

  def handle_event("supersede_submit", params, socket) do
    task = PlatformWeb.Tasks.Selection.writable_selected_task(socket)

    reason =
      case Map.get(params, "reason") do
        v when is_binary(v) -> v
        _ -> socket.assigns.supersede_reason
      end

    cond do
      is_nil(task) ->
        flash(:error, "No task selected.")
        {:noreply, reset(socket)}

      String.trim(reason || "") == "" ->
        # Client-side submit is disabled while blank; keep the modal open
        # and surface the validation error if the event still lands.
        flash(:error, "A reason is required to return the task to planning.")
        {:noreply, socket}

      true ->
        by_actor_id = socket.assigns[:current_user_id]

        case Tasks.supersede_current_plan(task.id, reason, by_actor_id) do
          {:ok, _task} ->
            # The board and the selected task both change; the shell owns
            # both, so it reloads them.
            send(self(), {:supersede_completed, "Task returned to planning."})
            {:noreply, reset(socket)}

          {:error, :reason_required} ->
            flash(:error, "A reason is required to return the task to planning.")
            {:noreply, socket}

          {:error, :not_in_flight} ->
            # The task moved underneath us — the shell must re-read it, so
            # this failure reports up like a success does.
            send(self(), {:supersede_stale, "Only in-flight tasks can be returned to planning."})
            {:noreply, reset(socket)}

          {:error, :no_active_plan} ->
            flash(:error, "Cannot return to planning: no active plan to supersede.")
            {:noreply, reset(socket)}

          {:error, reason} ->
            flash(:error, "Return to planning failed: #{inspect(reason)}")
            {:noreply, socket}
        end
    end
  end

  defp reset(socket) do
    socket |> assign(:show_supersede_modal, false) |> assign(:supersede_reason, "")
  end

  defp flash(kind, message), do: send(self(), {:supersede_flash, kind, message})
end
