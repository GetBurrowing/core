defmodule PlatformWeb.AdminFederationLive do
  use PlatformWeb, :live_view

  require Logger

  alias Platform.Federation
  alias Platform.Federation.DeadLetterBuffer

  @refresh_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval_ms, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Admin · Federation")
     |> assign(:runtimes, federation_status())
     |> assign(:dead_letters, DeadLetterBuffer.list())
     |> assign(:ping_results, %{})}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply,
     socket
     |> assign(:runtimes, federation_status())
     |> assign(:dead_letters, DeadLetterBuffer.list())}
  end

  def handle_info({:clear_ping, runtime_id}, socket) do
    ping_results = Map.delete(socket.assigns.ping_results, runtime_id)
    {:noreply, assign(socket, :ping_results, ping_results)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:runtimes, federation_status())
     |> assign(:dead_letters, DeadLetterBuffer.list())}
  end

  def handle_event("ping", %{"runtime-id" => runtime_id}, socket) do
    case Federation.ping_runtime(runtime_id) do
      :ok ->
        ping_results = Map.put(socket.assigns.ping_results, runtime_id, :sent)
        # Clear the result after 5 seconds
        Process.send_after(self(), {:clear_ping, runtime_id}, 5_000)
        {:noreply, assign(socket, :ping_results, ping_results)}

      {:error, reason} ->
        ping_results =
          Map.put(socket.assigns.ping_results, runtime_id, {:error, inspect(reason)})

        {:noreply, assign(socket, :ping_results, ping_results)}
    end
  end

  def handle_event("clear_dead_letters", _params, socket) do
    DeadLetterBuffer.clear()
    {:noreply, assign(socket, :dead_letters, [])}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp federation_status do
    try do
      Federation.federation_status()
    rescue
      _ -> []
    end
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(dt, "%b %d %H:%M")
    end
  end
end
