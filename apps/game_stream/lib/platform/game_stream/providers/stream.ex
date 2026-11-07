defmodule Platform.GameStream.Providers.Stream do
  @moduledoc "Adapter for the existing streamed review-build lifecycle."
  @behaviour Platform.GameStream.Provider
  @impl true
  def start(_id, %{task_id: task_id}, limits), do: Platform.GameStream.start_session(task_id, Map.to_list(limits))
  @impl true
  def status(%{session_id: id}), do: Platform.GameStream.status(id)
  @impl true
  def stop(%{session_id: id}, reason), do: Platform.GameStream.stop_session(id, reason)
  @impl true
  def reconcile(id), do: Platform.GameStream.status(id)
end
