defmodule PlatformWeb.ControlCenter.NativeAgentEvents do
  @moduledoc """
  Handle_event clauses for native (install-managed) agents on Agent Resources
  (task 01a10322 stage 4): Start, Stop and Restart, from a row or the detail
  header, and the "Run on this server" create flow. Stage 6 adds the login
  (save or remove an Anthropic API key) and the read-only "Recent output".

  ## Refused server-side

  Every control re-checks `Platform.Agents.NativeAgents.can_manage?/2` for
  the acting user before it touches the agent. The disabled buttons a
  non-manager sees are an affordance only: a `native_start` sent straight
  down the socket is refused here, not by the template.
  """
  use PlatformWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]
  import PlatformWeb.ControlCenter.Helpers, only: [changeset_error_summary: 1]

  alias Platform.AgentHost
  alias Platform.Agents.{Agent, NativeAgents, NativeLogin}
  alias Platform.Repo

  @refused "Only the agent's owner or an admin can do that."

  @doc "The flash a refused control shows."
  def refused_message, do: @refused

  def handle(event, %{"agent_id" => agent_id}, socket)
      when event in ["native_start", "native_stop", "native_restart"] and is_binary(agent_id) do
    # `agent_id` is a LiveView param: anything can arrive, and Repo.get/2
    # raises on a malformed id against Agent's UUIDv7 PK.
    with true <- Platform.UUID.valid?(agent_id) || :not_found,
         %Agent{} = agent <- Repo.get(Agent, agent_id),
         true <- NativeAgents.managed?(agent) || :not_managed,
         true <- NativeAgents.can_manage?(socket.assigns.current_user_id, agent) || :forbidden do
      run(event, agent, socket)
    else
      :forbidden -> {:noreply, put_flash(socket, :error, @refused)}
      _ -> {:noreply, put_flash(socket, :error, "That agent is not run by this server.")}
    end
  end

  def handle(event, _params, socket)
      when event in ["native_start", "native_stop", "native_restart"],
      do: {:noreply, socket}

  # ── Login (stage 6): an Anthropic API key, and nothing that takes a code ──
  #
  # There is deliberately no event here, or anywhere on this page, that
  # accepts a Claude login code: relaying one to the agent would be Suite
  # intermediating a Claude login. See `Platform.Agents.NativeLogin`.

  def handle("native_api_key_save", %{"agent_id" => agent_id} = params, socket)
      when is_binary(agent_id) do
    value = get_in(params, ["api_key", "value"])

    with_manageable(agent_id, socket, fn agent ->
      case NativeLogin.put_api_key(socket.assigns.current_user_id, agent, value) do
        :ok ->
          message =
            case apply_login(agent) do
              :restarted -> "Saved the API key. Restarting #{agent.name}."
              _ -> "Saved the API key. #{agent.name} will use it the next time it starts."
            end

          {:noreply, socket |> put_flash(:info, message) |> refresh()}

        {:error, :invalid_api_key} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "That is not an Anthropic API key. It starts with sk-ant- and has no spaces."
           )}

        {:error, :unsupported_harness} ->
          {:noreply, put_flash(socket, :error, "This agent cannot log in with an API key yet.")}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, @refused)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not save the API key.")}
      end
    end)
  end

  def handle("native_api_key_remove", %{"agent_id" => agent_id}, socket)
      when is_binary(agent_id) do
    with_manageable(agent_id, socket, fn agent ->
      case NativeLogin.remove_api_key(socket.assigns.current_user_id, agent) do
        :ok ->
          _ = apply_login(agent)

          {:noreply,
           socket
           |> put_flash(:info, "Removed the API key.")
           |> refresh()}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, @refused)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not remove the API key.")}
      end
    end)
  end

  # "Recent output" (stage 6): read only, managers only, login screens
  # withheld by the host and again by `AgentHost.recent_output/2`.
  def handle("native_recent_output", %{"agent_id" => agent_id}, socket)
      when is_binary(agent_id) do
    with_manageable(agent_id, socket, fn agent ->
      output =
        case AgentHost.recent_output(agent) do
          {:ok, output} -> output
          {:error, reason} -> {:error, reason}
        end

      {:noreply, assign(socket, :native_recent_output, {agent.id, output})}
    end)
  end

  def handle(event, _params, socket)
      when event in ["native_api_key_save", "native_api_key_remove", "native_recent_output"],
      do: {:noreply, socket}

  def handle("submit_native", %{"native" => params}, socket) do
    name = String.trim(params["name"] || "")
    harness = params["harness"] || "claude_code"
    owner_id = socket.assigns.current_user_id

    cond do
      not AgentHost.connected?() ->
        {:noreply, put_flash(socket, :error, AgentHost.describe() <> ".")}

      is_nil(owner_id) ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      name == "" ->
        {:noreply, put_flash(socket, :error, "Name is required.")}

      # Codex is offered only once suite-cli's `suite codex` has merged.
      harness not in available_harnesses() ->
        {:noreply, put_flash(socket, :error, "That harness is not available yet.")}

      true ->
        create(owner_id, name, harness, socket)
    end
  end

  def handle("submit_native", _params, socket), do: {:noreply, socket}

  @doc "Harnesses this build can run. Codex waits on suite-cli's `suite codex`."
  def available_harnesses, do: ["claude_code"]

  @doc "Per-agent assigns this module owns, reset on a new selection."
  def reset(socket), do: assign(socket, :native_recent_output, nil)

  # The same three checks as the Start/Stop/Restart controls.
  defp with_manageable(agent_id, socket, fun) do
    with true <- Platform.UUID.valid?(agent_id) || :not_found,
         %Agent{} = agent <- Repo.get(Agent, agent_id),
         true <- NativeAgents.managed?(agent) || :not_managed,
         true <- NativeAgents.can_manage?(socket.assigns.current_user_id, agent) || :forbidden do
      fun.(agent)
    else
      :forbidden -> {:noreply, put_flash(socket, :error, @refused)}
      _ -> {:noreply, put_flash(socket, :error, "That agent is not run by this server.")}
    end
  end

  # A new or removed key reaches the agent only through its env file, which
  # the host writes on a start: restart a running agent; for a stopped one,
  # the next start carries it.
  defp apply_login(agent) do
    with %{desired_state: "running"} <- NativeAgents.get_managed_runtime(agent),
         :ok <- AgentHost.restart_agent(agent) do
      :restarted
    else
      _ -> :not_restarted
    end
  end

  defp create(owner_id, name, harness, socket) do
    case NativeAgents.create(owner_id, %{name: name, harness: harness}) do
      {:ok, agent, _runtime} ->
        _ = AgentHost.start_agent(agent)

        {:noreply,
         socket
         |> assign(:show_onboarding_chooser, false)
         |> assign(:onboarding_flow, nil)
         |> put_flash(:info, "Created #{agent.name}.")
         |> push_patch(to: ~p"/control/#{agent.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error_summary(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create the agent: #{inspect(reason)}")}
    end
  end

  defp run("native_start", agent, socket) do
    agent |> AgentHost.start_agent() |> reply(socket, "Start")
  end

  defp run("native_stop", agent, socket) do
    agent |> AgentHost.stop_agent() |> reply(socket, "Stop")
  end

  defp run("native_restart", agent, socket) do
    case AgentHost.restart_agent(agent) do
      :ok -> {:noreply, assign(socket, :restarting_agent_id, agent.id) |> refresh()}
      other -> reply(other, socket, "Restart")
    end
  end

  defp reply(:ok, socket, _verb), do: {:noreply, refresh(socket)}

  defp reply({:error, :not_connected}, socket, verb),
    do: {:noreply, put_flash(socket, :error, "#{verb} failed: #{AgentHost.describe()}.")}

  defp reply({:error, reason}, socket, verb),
    do: {:noreply, put_flash(socket, :error, "#{verb} failed: #{inspect(reason)}")}

  defp refresh(socket), do: PlatformWeb.ControlCenterLive.refresh_native(socket)
end
