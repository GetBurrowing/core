defmodule PlatformWeb.AgentHostChannel do
  @moduledoc """
  The agent host's control channel, `agent_host:control` (task 01a10322
  stage 2). One per install: a second host is refused at join.

  Events from the host are handed to `Platform.AgentHost.Reconciler`.
  Commands from core arrive as `{:agent_host_push, event, payload}` messages
  and are pushed down unchanged. Payloads that carry a runtime token are never
  logged here.
  """
  use Phoenix.Channel

  alias Platform.AgentHost
  alias Platform.AgentHost.Reconciler

  @impl true
  def join("agent_host:control", payload, socket) do
    case Reconciler.host_joined(self(), payload || %{}) do
      :ok -> {:ok, socket}
      {:error, :already_connected} -> {:error, %{reason: "already_connected"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in("host.inventory", payload, socket) when is_map(payload) do
    {:reply, reply(Reconciler.inventory(self(), payload)), socket}
  end

  def handle_in("agent.state", payload, socket) when is_map(payload) do
    {:reply, reply(Reconciler.agent_state(self(), payload)), socket}
  end

  def handle_in("agent.log", %{"ref" => ref, "lines" => lines}, socket)
      when is_binary(ref) and is_list(lines) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      AgentHost.logs_topic(ref),
      {:agent_host_logs, ref, Enum.filter(lines, &is_binary/1)}
    )

    {:reply, :ok, socket}
  end

  # The pane text for "Recent output" (stage 6). Redacted again on the way
  # out of `AgentHost.recent_output/2`; never logged here.
  def handle_in("agent.pane", %{"ref" => ref} = payload, socket) when is_binary(ref) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      AgentHost.pane_topic(ref),
      {:agent_host_pane, ref, Map.take(payload, ["lines", "hidden"])}
    )

    {:reply, :ok, socket}
  end

  # The answer to `agent.check_auth` (stage 7 round 2). Carries no key.
  def handle_in("agent.auth", %{"ref" => ref, "result" => result}, socket)
      when is_binary(ref) and is_binary(result) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      AgentHost.auth_topic(ref),
      {:agent_host_auth, ref, result}
    )

    {:reply, :ok, socket}
  end

  def handle_in(_event, _payload, socket), do: {:reply, {:error, %{reason: "invalid"}}, socket}

  @impl true
  def handle_info({:agent_host_push, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reply(:ok), do: :ok
  defp reply({:error, reason}), do: {:error, %{reason: to_string(reason)}}
end
