defmodule PlatformWeb.ShellLive do
  @moduledoc "Mount hook that injects shell assigns for all authenticated surfaces."

  import Ecto.Query
  import Phoenix.Component
  import Phoenix.LiveView

  alias Platform.Accounts
  alias Platform.Agents.{Agent, AgentServer, WorkspaceBootstrap}
  alias Platform.Repo

  def on_mount(:default, _params, session, socket) do
    current_user =
      case session["current_user_id"] do
        user_id when is_binary(user_id) ->
          case Accounts.get_user(user_id) do
            %{name: name} when is_binary(name) and name != "" -> name
            %{email: email} when is_binary(email) -> email
            _ -> user_id
          end

        _ ->
          session["user_email"] || session["user_id"] || "user"
      end

    active_module = derive_active_module(socket.view)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_path, "/")
      |> assign(:agent_status, default_agent_status())
      |> assign(:drawer_open, false)
      |> assign(:active_module, active_module)
      |> attach_hook(:track_path, :handle_params, fn _params, url, socket ->
        uri = URI.parse(url)
        {:cont, assign(socket, :current_path, uri.path)}
      end)
      |> attach_hook(:drawer_events, :handle_event, fn
        "toggle_drawer", _params, socket ->
          {:halt, assign(socket, :drawer_open, !socket.assigns.drawer_open)}

        "close_drawer", _params, socket ->
          {:halt, assign(socket, :drawer_open, false)}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  def default_agent_status do
    case WorkspaceBootstrap.boot() do
      {:ok, %{reachable?: true}} ->
        :online

      {:ok, %{configured?: true}} ->
        :offline

      {:error, _reason} ->
        fallback_default_agent_status()
    end
  end

  defp fallback_default_agent_status do
    case default_persisted_agent() do
      %Agent{} = agent ->
        case AgentServer.start_agent(agent) do
          {:ok, pid} when is_pid(pid) ->
            :online

          {:error, _reason} ->
            if agent.status == "paused", do: :paused, else: :offline
        end

      nil ->
        :unknown
    end
  end

  defp default_persisted_agent do
    from(a in Agent,
      where: a.slug == "main" and a.status != "archived",
      limit: 1
    )
    |> Repo.one()
  rescue
    _ -> nil
  end

  # Derive a human-readable module name from the LiveView module atom.
  defp derive_active_module(view) do
    case view do
      PlatformWeb.ChatLive ->
        "Chat"

      PlatformWeb.ControlCenterLive ->
        "Agent Resources"

      PlatformWeb.TasksLive ->
        "Tasks"

      _ ->
        view
        |> Module.split()
        |> List.last()
        |> String.replace("Live", "")
        |> String.replace("_", " ")
    end
  end
end
