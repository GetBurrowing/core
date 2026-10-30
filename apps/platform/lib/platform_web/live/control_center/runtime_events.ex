defmodule PlatformWeb.ControlCenter.RuntimeEvents do
  @moduledoc """
  Handle_event clauses for federated runtime management: suspend, unsuspend, revoke,
  regenerate token, and dismiss regenerated token.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Platform.Agents.Agent
  alias Platform.Access.RuntimeProfiles
  alias Platform.Federation

  def handle(
        "suspend_federated_runtime",
        _params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    case Federation.get_runtime(rid) do
      %{} = runtime ->
        case Federation.suspend_runtime(socket.assigns.access_scope, runtime) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Runtime suspended.") |> reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not suspend runtime.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Runtime not found.")}
    end
  end

  def handle("suspend_federated_runtime", _params, socket), do: {:noreply, socket}

  def handle(
        "unsuspend_federated_runtime",
        _params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    case Federation.get_runtime(rid) do
      %{} = runtime ->
        case Federation.unsuspend_runtime(socket.assigns.access_scope, runtime) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Runtime unsuspended.") |> reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not unsuspend runtime.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Runtime not found.")}
    end
  end

  def handle("unsuspend_federated_runtime", _params, socket), do: {:noreply, socket}

  def handle(
        "revoke_federated_runtime",
        _params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    case Federation.get_runtime(rid) do
      %{} = runtime ->
        case Federation.revoke_runtime(socket.assigns.access_scope, runtime) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Runtime revoked.") |> reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not revoke runtime.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Runtime not found.")}
    end
  end

  def handle("revoke_federated_runtime", _params, socket), do: {:noreply, socket}

  def handle(
        "regenerate_federated_token",
        _params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    case Federation.get_runtime(rid) do
      # A native agent's token is minted fresh on every start by the agent
      # host's reconciler (task 01a10322); a token handed out here would only
      # knock the running agent off its socket.
      %{managed_by: "install"} ->
        {:noreply, put_flash(socket, :error, "This agent gets a new token every time it starts.")}

      %{} = runtime ->
        case Federation.generate_runtime_token(socket.assigns.access_scope, runtime) do
          {:ok, _runtime, raw_token} ->
            {:noreply,
             socket
             |> assign(:regenerated_token, raw_token)
             |> put_flash(:info, "New token generated. Save it now.")
             |> reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not regenerate token.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Runtime not found.")}
    end
  end

  def handle("regenerate_federated_token", _params, socket), do: {:noreply, socket}

  def handle("dismiss_regenerated_token", _params, socket) do
    {:noreply, assign(socket, :regenerated_token, nil)}
  end

  def handle(
        "save_tool_profile",
        params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    modules = params |> Map.get("modules", []) |> List.wrap()

    case Federation.get_runtime(rid) do
      %{} = runtime ->
        case RuntimeProfiles.set_tool_profile(socket.assigns.access_scope, runtime, modules) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Tool profile updated.") |> reload(socket)}

          {:error, _changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not update tool profile."
             )}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Runtime not found.")}
    end
  end

  def handle("save_tool_profile", _params, socket), do: {:noreply, socket}

  def handle(
        "save_agent_restrictions",
        params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    permissions =
      if params["inherit"] == "true" do
        nil
      else
        params
        |> Map.get("permissions", [])
        |> List.wrap()
        |> Map.new(&{&1, "all"})
      end

    case Federation.get_runtime(rid) do
      %{} = runtime ->
        case RuntimeProfiles.restrict(socket.assigns.access_scope, runtime, permissions) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Agent access updated.") |> reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update agent access.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Runtime not found.")}
    end
  end

  def handle("save_agent_restrictions", _params, socket), do: {:noreply, socket}

  # Delegate reload back to the main LiveView module
  defp reload(socket, _original_socket) do
    PlatformWeb.ControlCenterLive.reload_selected_agent(socket)
  end
end
