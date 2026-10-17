defmodule PlatformWeb.Tasks.MergeControlComponent do
  @moduledoc """
  The Merge Control concern of the Tasks surface. Task `019ff182` moved
  the *markup* into `PlatformWeb.Components.TaskMergeControls` (a pure
  function component) but left the `:merge_control` assign and the
  `merge_task_branch` event in the shell — a half-extraction. Task
  01a008f6 stage 5 finishes it: the shell now retains neither.

  ## Ownership

    * Assign owned here: `:merge_control`, derived from the `selected_task`
      attr via `Platform.Tasks.MergeControl.for_task/1` whenever the
      shell bumps `detail_epoch`. `nil` — nothing renders at all — unless
      the deploy is `pr_merge` with `auto_merge: false` on a non-stacked
      task with a live `pr_merged` gate.
    * Event owned here: `merge_task_branch`. A successful merge is
      reported up with `send(self(), {:merge_control_merged, task_id,
      branch})` because reloading the task and flashing are shell
      concerns; a REFUSED merge stays local — it only re-tones the band.

  The colour rule and every other presentation decision remain in
  `TaskMergeControls`; this module adds state and one event, nothing else.
  """
  use PlatformWeb, :live_component

  alias Platform.Tasks.MergeControl
  alias Platform.Tasks.Task

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(:merge_control, nil) |> assign(:loaded_epoch, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    epoch = assigns[:detail_epoch]

    if epoch != socket.assigns.loaded_epoch do
      {:ok,
       socket
       |> assign(:loaded_epoch, epoch)
       |> assign(:merge_control, control_for(socket.assigns[:selected_task]))}
    else
      {:ok, socket}
    end
  end

  defp control_for(%Task{} = task), do: MergeControl.for_task(task)
  defp control_for(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <PlatformWeb.Components.TaskMergeControls.task_merge_controls
        :if={@merge_control}
        control={@merge_control}
        target={@myself}
      />
    </div>
    """
  end

  # Deliberately NOT touching the `pr_merged` validation: that gate
  # auto-passes on the `pull_request.closed` webhook, so passing it from
  # the click would pass it on a merge that might not have landed. Every
  # failure — including a missing `gh` — lands in the state band as a
  # named sentence rather than a flash, a crash, or a vanishing button.
  @impl true
  def handle_event("merge_task_branch", _params, socket) do
    case {PlatformWeb.Tasks.Selection.writable_selected_task(socket),
          socket.assigns.merge_control} do
      {%Task{} = task, %{} = control} ->
        actor = %{id: socket.assigns[:current_user_id], org_id: nil}

        case MergeControl.merge(task, control, actor) do
          {:ok, _sha} ->
            send(self(), {:merge_control_merged, task.id, control.branch})
            {:noreply, socket}

          {:error, band} ->
            {:noreply, assign(socket, :merge_control, %{control | band: band})}
        end

      _ ->
        {:noreply, socket}
    end
  end
end
