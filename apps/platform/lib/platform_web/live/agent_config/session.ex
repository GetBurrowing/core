defmodule PlatformWeb.AgentConfig.Session do
  @moduledoc """
  The session strip's state and events, shared by the configuration screen
  (`PlatformWeb.AgentConfigLive`) and the agent page (`ControlCenterLive`),
  so the two strips cannot drift.

  The host LiveView keeps one assign, `:session` (nil when the viewer may not
  restart this agent), and forwards:

    * events `session_restart`, `session_restart_confirm`,
      `session_restart_cancel` to `handle_event/3`;
    * `handle_async(:session_restart, ...)` to `handle_async/2`;
    * `{:agent_session_restarted, id, diff}` (PubSub
      `ConfigFiles.restart_topic/1`) and `{:session_strip_collapse, token}` to
      `handle_info/2`.

  Restart goes through `Platform.Agents.ConfigFiles.restart/3` only: it
  authorizes, audits the request and the result, and broadcasts the diff.
  It runs in `start_async/3` (a host may take minutes), so editing stays
  available while it runs.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3, connected?: 1]

  alias Platform.Agents.{Agent, ConfigFiles}

  @collapse_ms 10_000

  @doc "The strip's state for `agent`, or nil when `info` is not an authorized describe."
  @spec init(Phoenix.LiveView.Socket.t(), term(), Agent.t(), {:ok, map()} | term()) ::
          Phoenix.LiveView.Socket.t()
  def init(socket, actor, %Agent{} = agent, {:ok, info}) do
    previous = socket.assigns[:session]

    case previous do
      # The same agent again (the agent page re-assigns its panel after every
      # control): keep the phase and the last diff, re-count pending.
      %{agent: %{id: id}} when id == agent.id ->
        assign(socket, :session, %{
          previous
          | agent: agent,
            agent_name: agent.name,
            restart?: info.restart?,
            resumes?: info.resumes?,
            pending: length(ConfigFiles.pending_changes(agent))
        })

      _ ->
        unsubscribe(socket, previous)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Platform.PubSub, ConfigFiles.restart_topic(agent.id))
        end

        assign(socket, :session, %{
          agent: agent,
          agent_name: agent.name,
          actor: actor,
          restart?: info.restart?,
          resumes?: info.resumes?,
          pending: length(ConfigFiles.pending_changes(agent)),
          phase: :idle,
          diff: nil,
          last: nil,
          error: nil,
          confirm: nil,
          token: nil
        })
    end
  end

  def init(socket, _actor, _agent, _refused) do
    unsubscribe(socket, socket.assigns[:session])
    assign(socket, :session, nil)
  end

  defp unsubscribe(socket, %{agent: %{id: id}}) do
    if connected?(socket),
      do: Phoenix.PubSub.unsubscribe(Platform.PubSub, ConfigFiles.restart_topic(id))
  end

  defp unsubscribe(_socket, _), do: :ok

  @doc "Re-count saved changes the session has not loaded (after a save)."
  def refresh_pending(%{assigns: %{session: %{agent: agent} = s}} = socket),
    do: assign(socket, :session, %{s | pending: length(ConfigFiles.pending_changes(agent))})

  def refresh_pending(socket), do: socket

  def handle_event(
        "session_restart",
        _params,
        %{assigns: %{session: %{restart?: true} = s}} = socket
      ) do
    case ConfigFiles.running_task(s.agent) do
      nil -> {:noreply, start(socket)}
      task -> {:noreply, assign(socket, :session, %{s | confirm: task})}
    end
  end

  def handle_event("session_restart_confirm", _params, %{assigns: %{session: %{} = s}} = socket) do
    socket = assign(socket, :session, %{s | confirm: nil})
    {:noreply, start(socket)}
  end

  def handle_event("session_restart_cancel", _params, %{assigns: %{session: %{} = s}} = socket),
    do: {:noreply, assign(socket, :session, %{s | confirm: nil})}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp start(%{assigns: %{session: %{phase: :restarting}}} = socket), do: socket

  defp start(%{assigns: %{session: s}} = socket) do
    actor = s.actor
    agent = s.agent

    socket
    |> assign(:session, %{s | phase: :restarting, error: nil})
    |> start_async(:session_restart, fn -> ConfigFiles.restart(actor, agent) end)
  end

  @doc "The async restart's result."
  def handle_async({:ok, {:ok, diff}}, socket), do: {:noreply, restarted(socket, diff)}

  def handle_async({:ok, {:error, reason}}, socket), do: {:noreply, failed(socket, reason)}
  def handle_async({:exit, _reason}, socket), do: {:noreply, failed(socket, :exit)}

  @doc "PubSub and timer messages for the strip; `:unhandled` for anything else."
  def handle_info(
        {:agent_session_restarted, id, diff},
        %{assigns: %{session: %{agent: %{id: id}}}} = socket
      ),
      do: {:noreply, restarted(socket, diff)}

  def handle_info(
        {:session_strip_collapse, token},
        %{assigns: %{session: %{token: token} = s}} = socket
      )
      when not is_nil(token) do
    {:noreply, assign(socket, :session, %{s | phase: :idle, diff: nil, token: nil})}
  end

  def handle_info({:session_strip_collapse, _}, socket), do: {:noreply, socket}
  def handle_info({:agent_session_restarted, _, _}, socket), do: {:noreply, socket}
  def handle_info(_msg, _socket), do: :unhandled

  # Our own restart arrives twice (the async result and the broadcast): the
  # second, with the same restarted_at, changes nothing.
  defp restarted(%{assigns: %{session: %{diff: %{restarted_at: at}}}} = socket, %{
         restarted_at: at
       }),
       do: socket

  defp restarted(%{assigns: %{session: %{} = s}} = socket, diff) do
    token = make_ref()
    Process.send_after(self(), {:session_strip_collapse, token}, @collapse_ms)

    assign(socket, :session, %{
      s
      | phase: :restarted,
        diff: diff,
        last: diff,
        error: nil,
        token: token,
        pending: length(ConfigFiles.pending_changes(s.agent))
    })
  end

  defp restarted(socket, _diff), do: socket

  defp failed(%{assigns: %{session: %{} = s}} = socket, reason),
    do: assign(socket, :session, %{s | phase: :idle, error: failure_copy(reason)})

  defp failed(socket, _reason), do: socket

  @doc "Plain copy for a refused or failed restart."
  def failure_copy(:host_offline), do: "Restart failed: the agent's machine did not answer."
  def failure_copy(:forbidden), do: "Restart refused: only the agent's owner can restart it."
  def failure_copy(:unsupported_harness), do: "This agent's harness has no restart."

  def failure_copy({:host_error, "no_recorded_session"}),
    do: "Restart failed: no running session was found on the machine."

  def failure_copy(_), do: "Restart failed. Try again in a moment."
end
