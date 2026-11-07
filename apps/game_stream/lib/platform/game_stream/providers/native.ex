defmodule Platform.GameStream.Providers.Native do
  @moduledoc "Native mode over the existing authenticated federation runtime channel."
  @behaviour Platform.GameStream.Provider
  alias Platform.GameStream.{Protocol, NativeSessionRecord}
  @impl true
  def start(id, build, limits) do
    payload = Map.merge(limits, %{session_id: id, mode: "native", build: build})
    with :ok <- dispatch(limits.host_runtime_id, "play_native_start", payload),
      do: {:ok, %{session_id: id, host_runtime_id: limits.host_runtime_id}}
  end
  @impl true
  def status(handle), do: dispatch(handle.host_runtime_id, "play_native_reconcile", %{session_id: handle.session_id})
  @impl true
  def stop(handle, reason), do: dispatch(handle.host_runtime_id, "play_native_stop", %{session_id: handle.session_id, reason: reason})
  @impl true
  def reconcile(id) do
    case Platform.Repo.get(NativeSessionRecord, id) do
      nil -> {:error, :not_found}
      row -> status(%{session_id: id, host_runtime_id: row.host_runtime_id})
    end
  end
  defp dispatch(runtime, event, payload), do: PlatformWeb.Endpoint.broadcast(Protocol.host_topic(runtime), event, payload)
end
