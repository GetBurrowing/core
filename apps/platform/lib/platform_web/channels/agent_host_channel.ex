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

  # The answer to `agent.file_read`: one file of the agent's work dir, already
  # redacted by the host and redacted again by `Platform.Agents.Config`.
  def handle_in("agent.file", %{"ref" => ref} = payload, socket) when is_binary(ref) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      AgentHost.file_topic(ref),
      {:agent_host_file, ref, Map.take(payload, ["content", "sha256", "error"])}
    )

    {:reply, :ok, socket}
  end

  # The answer to `agent.restart` with a ref (task 01a17b1c stage 4): the
  # outcome and the tool snapshots, names only. Anything else is dropped.
  def handle_in("agent.restarted", %{"ref" => ref} = payload, socket) when is_binary(ref) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      AgentHost.restart_topic(ref),
      {:agent_host_restarted, ref,
       %{
         "outcome" => restart_outcome(payload["outcome"]),
         "before" => snapshot(payload["before"]),
         "after" => snapshot(payload["after"])
       }}
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

  # The answer to `host.env_names` / `host.admin` (task 01a17b10 stage 3).
  # Env names only; never logged here.
  def handle_in("host.reply", %{"ref" => ref, "result" => result}, socket)
      when is_binary(ref) and is_map(result) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      AgentHost.reply_topic(ref),
      {:agent_host_reply, ref, result}
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

  @restart_outcomes ~w(ready needs_login gone timeout)
  defp restart_outcome(o) when o in @restart_outcomes, do: o
  defp restart_outcome(_), do: "gone"

  defp snapshot(%{"tools" => tools} = snap) when is_list(tools) do
    %{
      "tools" =>
        tools
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.slice(&1, 0, 200))
        |> Enum.take(500),
      "servers" =>
        for %{"name" => name, "status" => status} = s <- List.wrap(snap["servers"]),
            is_binary(name),
            status in ["ok", "unreachable"] do
          %{
            "name" => String.slice(name, 0, 100),
            "status" => status,
            "tools" =>
              s |> Map.get("tools") |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.take(500)
          }
        end
    }
  end

  defp snapshot(_), do: nil

  defp reply(:ok), do: :ok
  defp reply({:error, reason}), do: {:error, %{reason: to_string(reason)}}
end
