defmodule PlatformWeb.RuntimeHostChannel do
  @moduledoc """
  `runtime_host:<runtime_id>`: the structured-operations channel held by a
  burrow-cli process that outlives the agent's harness (task 01a17b1c).

  It rides the same `PlatformWeb.RuntimeSocket` as `runtime:<id>`, so it
  authenticates with the same runtime id and token. It exists because the
  `runtime:` socket is held by the harness (Claude's channel plugin, or the
  Codex bridge) and dies with it; this one has to serve files while the
  harness restarts.

  ## Contract (shared with the remote terminal, task 01a17b17)

    * ONE host connection per agent folder, joined on `runtime_host:<id>`.
      Structured ops only: `file.list`, `file.read`, `file.write`,
      `file.delete` (only to a host whose hello capabilities name it),
      `secret.set` and `session.*`.
    * TERMINAL BYTES NEVER RIDE THIS TOPIC. The remote terminal has its own
      topic, `terminal:<runtime_id>` (`PlatformWeb.TerminalCliChannel`), with
      its own connection, lifetime and opt-in. An inbound `terminal.data` (or
      any event not listed below) is refused here.
    * Join only when the topic id equals the socket's authenticated
      `runtime_id`; any other id is `forbidden`.
    * Hello (join payload): `harness` (kind), `cli_version`, `capabilities`
      (`file`, `session`), `resumes` (restart resumes the conversation) and
      `config_opt_in` (`off` | `owner_only` | `admins`, chosen on the machine;
      absent means `off`). Core's gate for editing config over this channel is
      `Platform.Agents.ConfigFiles.Access`, which pairs that opt-in with the
      federation kind via `Platform.Federation.RemoteAccess`.
    * Core to host: `Platform.Federation.RuntimeHosts.ops/0` only, each with a
      `ref`. Host to core: `reply` `{ref, ok: map}` or `{ref, error: string}`,
      and `pong`. Nothing else is accepted.
  """
  use Phoenix.Channel

  alias Platform.Federation.RuntimeHosts

  @inbound ~w(reply pong)
  @opt_ins ~w(off owner_only admins)
  @max_str 64

  @doc "Inbound events this channel accepts."
  def inbound_events, do: @inbound

  @impl true
  def join("runtime_host:" <> runtime_id, params, socket) do
    if runtime_id == socket.assigns.runtime_id do
      RuntimeHosts.register(runtime_id, hello(params || %{}))
      {:ok, assign(socket, :pending, %{})}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "forbidden"}}

  @impl true
  def handle_in("reply", %{"ref" => ref} = payload, socket) when is_binary(ref) do
    case Map.pop(socket.assigns.pending, ref) do
      {nil, _} ->
        {:noreply, socket}

      {from, pending} ->
        send(from, {:host_reply, ref, result(payload)})
        {:noreply, assign(socket, :pending, pending)}
    end
  end

  def handle_in("pong", _payload, socket), do: {:noreply, socket}

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "event_not_allowed"}}, socket}

  @impl true
  def handle_info({:host_request, from, ref, event, payload}, socket) do
    if RuntimeHosts.op_allowed?(event) do
      push(socket, event, Map.put(payload, "ref", ref))
      {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
    else
      send(from, {:host_reply, ref, {:error, :event_not_allowed}})
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp result(%{"error" => reason}), do: {:error, {:host_error, to_string(reason)}}
  defp result(%{"ok" => %{} = ok}), do: {:ok, ok}
  defp result(_), do: {:error, {:host_error, "malformed reply"}}

  defp hello(params) do
    %{
      harness: str(params["harness"]),
      cli_version: str(params["cli_version"]),
      capabilities:
        params["capabilities"]
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.slice(&1, 0, @max_str))
        |> Enum.take(8),
      resumes: params["resumes"] == true,
      config_opt_in: opt_in(params["config_opt_in"])
    }
  end

  defp opt_in(v) when v in @opt_ins, do: String.to_existing_atom(v)
  defp opt_in(_), do: :off

  defp str(v) when is_binary(v), do: String.slice(v, 0, @max_str)
  defp str(_), do: nil
end
