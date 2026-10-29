defmodule PlatformWeb.ChatLive.ExecutionActivityHooks do
  @moduledoc "Keeps execution-space activity on the same server projection as Tasks."
  import Phoenix.LiveView
  import Phoenix.Component
  alias Platform.Orchestration.ExecutionStatus

  def attach(socket) do
    if connected?(socket) do
      Platform.Tasks.subscribe_board()
      Process.send_after(self(), :chat_execution_tick, 1_000)
    end

    socket
    |> assign(:chat_execution_activity, nil)
    |> refresh()
    |> attach_hook(:execution_activity, :handle_info, &info/2)
    |> PlatformWeb.ChatLive.PresenceHooks.attach()
  end

  def assign_space(socket, space), do: socket |> assign(:active_space, space) |> refresh()

  def refresh(socket) do
    task_id =
      case socket.assigns[:active_space] do
        %{metadata: metadata} when is_map(metadata) -> metadata["task_id"]
        _ -> nil
      end

    # A non-matching clause (e.g. a backlog %Task{}) must not fall through as
    # the status: a struct is a map, so is_map/1 would accept it.
    status =
      with true <- Platform.UUID.valid?(task_id),
           true <- readable?(socket.assigns[:access_scope], task_id),
           %{status: "in_progress"} = task <- Platform.Tasks.get_task_record(task_id) do
        ExecutionStatus.for_task(task, socket.assigns[:access_scope])
      else
        _ -> nil
      end

    assign(socket, :chat_execution_activity, status)
  end

  defp readable?(%Platform.Access.Scope{} = scope, id),
    do: Platform.Access.can?(scope, "tasks.read", {:task, id})

  defp readable?(_, _), do: false

  defp info(:chat_execution_tick, socket) do
    Process.send_after(self(), :chat_execution_tick, 1_000)
    {:halt, refresh(socket)}
  end

  defp info({:runtime_event, _}, socket), do: {:halt, refresh(socket)}
  defp info({:blocker_verification_requested, _}, socket), do: {:halt, refresh(socket)}
  defp info(_message, socket), do: {:cont, socket}
end
