defmodule PlatformWeb.TasksLive do
  use PlatformWeb, :live_view

  alias Platform.Tasks
  alias Platform.Tasks.Detail
  alias Platform.Execution.Run
  alias Platform.Context.Delta
  alias Platform.Context.Item
  alias Platform.Artifacts.Artifact

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tasks")
     |> assign(:tasks, Tasks.list_tasks())
     |> assign(:selected_task_id, nil)
     |> assign(:task_detail, nil)
     |> assign(:subscribed_task_id, nil)
     |> assign(
       :explanation,
       "Tasks UI MVP is currently a read-side over execution/context/artifact state while the persistent Tasks domain is still being built."
     )}
  end

  @impl true
  def handle_params(%{"task_id" => task_id}, _url, socket) do
    {:noreply,
     socket
     |> refresh_tasks()
     |> load_task(task_id)}
  end

  def handle_params(_params, _url, socket) do
    socket = refresh_tasks(socket)

    case socket.assigns.tasks do
      [%{task_id: task_id} | _] ->
        {:noreply, push_navigate(socket, to: ~p"/tasks/#{task_id}")}

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("request_stop", %{"run_id" => run_id}, socket) do
    socket =
      case Tasks.request_stop(run_id) do
        {:ok, _run} -> put_flash(socket, :info, "Requested stop for run #{run_id}.")
        {:error, reason} -> put_flash(socket, :error, "Stop failed: #{inspect(reason)}")
      end

    {:noreply, reload_selected_task(socket)}
  end

  def handle_event("force_stop", %{"run_id" => run_id}, socket) do
    socket =
      case Tasks.force_stop(run_id) do
        {:ok, _run} -> put_flash(socket, :info, "Forced stop for run #{run_id}.")
        {:error, reason} -> put_flash(socket, :error, "Force stop failed: #{inspect(reason)}")
      end

    {:noreply, reload_selected_task(socket)}
  end

  @impl true
  def handle_info({:artifact_registered, _artifact}, socket),
    do: {:noreply, reload_selected_task(socket)}

  def handle_info({:artifact_published, _artifact}, socket),
    do: {:noreply, reload_selected_task(socket)}

  def handle_info({:artifact_publication_failed, _artifact}, socket),
    do: {:noreply, reload_selected_task(socket)}

  def handle_info({:run_ctx_status_changed, _run_id, _ctx_status}, socket),
    do: {:noreply, reload_selected_task(socket)}

  def handle_info({:context_delta, _delta}, socket), do: {:noreply, reload_selected_task(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_tasks(socket) do
    assign(socket, :tasks, Tasks.list_tasks())
  end

  defp load_task(socket, task_id) do
    socket = maybe_switch_subscription(socket, task_id)

    case Tasks.get_task(task_id) do
      {:ok, %Detail{} = detail} ->
        socket
        |> assign(:selected_task_id, task_id)
        |> assign(:task_detail, detail)
        |> assign(:page_title, "Tasks · #{task_id}")

      {:error, :not_found} ->
        socket
        |> assign(:selected_task_id, task_id)
        |> assign(:task_detail, nil)
        |> put_flash(
          :error,
          "Task #{task_id} is not visible in the current execution/context/artifact state."
        )
    end
  end

  defp reload_selected_task(%{assigns: %{selected_task_id: nil}} = socket),
    do: refresh_tasks(socket)

  defp reload_selected_task(socket) do
    socket
    |> refresh_tasks()
    |> load_task(socket.assigns.selected_task_id)
  end

  defp maybe_switch_subscription(%{assigns: %{subscribed_task_id: task_id}} = socket, task_id),
    do: socket

  defp maybe_switch_subscription(socket, task_id) do
    if old_task_id = socket.assigns.subscribed_task_id do
      :ok = Tasks.unsubscribe(old_task_id)
    end

    :ok = Tasks.subscribe(task_id)
    assign(socket, :subscribed_task_id, task_id)
  end

  defp run_status_class(:completed), do: "badge badge-success badge-outline"
  defp run_status_class(:cancelled), do: "badge badge-warning badge-outline"
  defp run_status_class(:failed), do: "badge badge-error badge-outline"
  defp run_status_class(:running), do: "badge badge-success"
  defp run_status_class(:starting), do: "badge badge-info"
  defp run_status_class(:created), do: "badge badge-ghost"
  defp run_status_class(_), do: "badge badge-ghost"

  defp ctx_status_class(:current), do: "badge badge-success badge-outline"
  defp ctx_status_class(:stale), do: "badge badge-warning badge-outline"
  defp ctx_status_class(:dead), do: "badge badge-error badge-outline"
  defp ctx_status_class(:empty), do: "badge badge-ghost"
  defp ctx_status_class(_), do: "badge badge-ghost"

  defp publication_status_class(%{"status" => "published"}),
    do: "badge badge-success badge-outline"

  defp publication_status_class(%{"status" => "failed"}), do: "badge badge-error badge-outline"
  defp publication_status_class(%{"status" => "requested"}), do: "badge badge-info badge-outline"
  defp publication_status_class(_), do: "badge badge-ghost"

  defp publication_status_text(%{"status" => status}) when is_binary(status), do: status
  defp publication_status_text(_), do: "unpublished"

  defp fmt_dt(nil), do: "—"
  defp fmt_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp active_run?(%Run{} = run), do: not Run.terminal?(run)

  defp item_value_preview(%Item{value: value}) when is_binary(value),
    do: String.slice(value, 0, 120)

  defp item_value_preview(%Item{value: value}) when is_map(value),
    do: inspect(value, pretty: true, limit: 6)

  defp item_value_preview(%Item{value: value}), do: inspect(value, pretty: true, limit: 6)

  defp delta_summary(%Delta{} = delta) do
    puts = Map.keys(delta.puts || %{})
    deletes = delta.deletes || []

    cond do
      puts != [] and deletes != [] -> "+#{length(puts)} / -#{length(deletes)}"
      puts != [] -> "+#{length(puts)}"
      deletes != [] -> "-#{length(deletes)}"
      true -> "no-op"
    end
  end

  defp artifact_name(%Artifact{name: nil, id: id}), do: id
  defp artifact_name(%Artifact{name: name}), do: name

  defp blank_to_em_dash(""), do: "—"
  defp blank_to_em_dash(value), do: value
end
