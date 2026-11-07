defmodule PlatformWeb.AgentHostChannel do
  @moduledoc """
  The agent host's control channel, `agent_host:control` (task 01a10322
  stage 2). One per install: a second host is refused at join.

  Events from the host are handed to `Platform.AgentHost.Reconciler`.
  Commands from core arrive as `{:agent_host_push, event, payload}` messages
  and are pushed down unchanged, except that a `Platform.AgentHost.LoginCode`
  is unwrapped here, as the push is serialised, and nowhere earlier (task
  01a1b365). Payloads that carry a runtime token or a login code are never
  logged here, and incoming events are not logged at all (`log_handle_in:
  false`): the `agent.claude_login` reply carries the sign-in URL.
  """
  use Phoenix.Channel, log_handle_in: false

  alias Platform.AgentHost
  alias Platform.AgentHost.{LoginCode, Reconciler}

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

  # The answer to `agent.claude_login_start` / `_code` / `agent.claude_logout`
  # (task 01a1b365). It never carries the code. Only the known results pass,
  # the URL only on a start and only on Anthropic's sign-in hosts, account and
  # plan only on an `ok`. Broadcast on the ref's own reply topic, which only
  # the caller waiting on that ref subscribes to; never on the status topic.
  def handle_in("agent.claude_login", %{"ref" => ref, "result" => result} = payload, socket)
      when is_binary(ref) and is_binary(result) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      AgentHost.reply_topic(ref),
      {:agent_host_claude_login, ref, claude_login_reply(result, payload)}
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
    push(socket, event, unwrap_login_code(payload))
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The one place a login code becomes a string again: the push to the host.
  defp unwrap_login_code(%{"code" => %LoginCode{} = code} = payload),
    do: %{payload | "code" => LoginCode.reveal(code)}

  defp unwrap_login_code(payload), do: payload

  @login_results ~w(ok bad_code no_subscription no_session failed)

  @doc false
  # The sanitised `agent.claude_login` reply. Public for the stand-in hosts.
  def claude_login_reply("url", %{"url" => url}) when is_binary(url) do
    if anthropic_sign_in_url?(url),
      do: %{"result" => "url", "url" => url},
      else: %{"result" => "failed"}
  end

  def claude_login_reply("ok", %{"account" => account, "plan" => plan})
      when is_binary(account) and is_binary(plan) do
    %{
      "result" => "ok",
      "account" => String.slice(account, 0, 320),
      "plan" => String.slice(plan, 0, 32)
    }
  end

  # A logout's `ok`, or a login's `ok` without its account (which
  # `AgentHost.claude_login_submit/4` then reads as `failed`).
  def claude_login_reply(result, _payload) when result in @login_results,
    do: %{"result" => result}

  def claude_login_reply(_result, _payload), do: %{"result" => "failed"}

  # The host sends only claude.com / claude.ai https URLs (claude_login.ts
  # LOGIN_URL); anything else is dropped here too.
  defp anthropic_sign_in_url?(url) do
    byte_size(url) <= 4096 and
      match?(
        %URI{scheme: "https", host: host, userinfo: nil, port: 443}
        when host in ["claude.com", "claude.ai"],
        URI.parse(url)
      )
  end

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
