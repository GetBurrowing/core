defmodule PlatformWeb.ControlCenter.RuntimeEvents do
  @moduledoc """
  Handle_event clauses for federated runtime management: suspend, revoke,
  regenerate token, and dismiss regenerated token.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Platform.Agents.Agent
  alias Platform.Federation

  def handle(
        "suspend_federated_runtime",
        _params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    case Federation.get_runtime(rid) do
      %{} = runtime ->
        case Federation.suspend_runtime(runtime) do
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
        "revoke_federated_runtime",
        _params,
        %{assigns: %{selected_agent: %Agent{runtime_id: rid}}} = socket
      )
      when is_binary(rid) do
    case Federation.get_runtime(rid) do
      %{} = runtime ->
        case Federation.revoke_runtime(runtime) do
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
      %{} = runtime ->
        case Federation.generate_runtime_token(runtime) do
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

  # Delegate reload back to the main LiveView module
  defp reload(socket, _original_socket) do
    PlatformWeb.ControlCenterLive.reload_selected_agent(socket)
  end
end
