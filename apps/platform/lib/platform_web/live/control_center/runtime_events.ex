defmodule PlatformWeb.ControlCenter.RuntimeEvents do
  @moduledoc """
  Handle_event clauses for federated runtime management: suspend, unsuspend, revoke,
  regenerate token, and dismiss regenerated token; and, for an install-managed
  agent, the Owner control (review, confirm, cancel), which goes through
  `Platform.Agents.NativeAgents.transfer_owner/4`.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Platform.Accounts
  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Access.RuntimeProfiles
  alias Platform.Federation
  alias PlatformWeb.ControlCenter.{NativeAgentEvents, RuntimePanel}

  @invalid_owner "That person can't own this agent. Pick someone who belongs to this install and hasn't been archived."

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

  # ── Owner control (task 01a1f42d stage 4) ─────────────────────────
  #
  # Two steps: review (pick a person, see a confirm) and confirm (the
  # transfer). The ONE authority is `NativeAgents.transfer_owner/4`: confirm
  # calls it with the signed-in user as actor, and whatever it refuses is
  # turned into a sentence here. Review checks `can_transfer_owner?/2` (the
  # same rule) only so that a forged review never opens a confirm.

  def handle(
        "owner_transfer_review",
        %{"new_owner_id" => new_owner_id},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      )
      when is_binary(new_owner_id) do
    user_id = socket.assigns.current_user_id

    cond do
      not NativeAgents.can_transfer_owner?(user_id, agent) ->
        {:noreply, put_flash(socket, :error, NativeAgentEvents.refused_message())}

      match?(%{owner_user_id: ^new_owner_id}, NativeAgents.get_managed_runtime(agent)) ->
        {:noreply, put_flash(socket, :error, same_owner_message(new_owner_id, agent))}

      user = Accounts.get_user(new_owner_id) ->
        pending = %{agent_id: agent.id, id: user.id, name: RuntimePanel.user_label(user)}
        {:noreply, assign(socket, :owner_transfer, pending)}

      true ->
        {:noreply, put_flash(socket, :error, @invalid_owner)}
    end
  end

  def handle("owner_transfer_review", _params, socket),
    do: {:noreply, put_flash(socket, :error, @invalid_owner)}

  def handle(
        "owner_transfer_confirm",
        %{"new_owner_id" => new_owner_id},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      )
      when is_binary(new_owner_id) do
    actor = %{id: socket.assigns.current_user_id}
    socket = assign(socket, :owner_transfer, nil)

    case NativeAgents.transfer_owner(actor, agent, new_owner_id) do
      {:ok, _runtime} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user_name(new_owner_id)} now owns #{agent.name}.")
         |> reload(socket)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, NativeAgentEvents.refused_message())}

      {:error, :invalid_owner} ->
        {:noreply, put_flash(socket, :error, @invalid_owner)}

      {:error, :same_owner} ->
        {:noreply, put_flash(socket, :error, same_owner_message(new_owner_id, agent))}

      {:error, :not_managed} ->
        {:noreply,
         put_flash(socket, :error, "Only agents that run on this server have an owner to change.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not change the owner. Nothing was changed.")}
    end
  end

  def handle("owner_transfer_confirm", _params, socket),
    do: {:noreply, socket |> assign(:owner_transfer, nil) |> put_flash(:error, @invalid_owner)}

  def handle("owner_transfer_cancel", _params, socket),
    do: {:noreply, assign(socket, :owner_transfer, nil)}

  defp same_owner_message(user_id, agent),
    do: "#{user_name(user_id)} already owns #{agent.name}."

  defp user_name(user_id) do
    case Accounts.get_user(user_id) do
      nil -> "That person"
      user -> RuntimePanel.user_label(user)
    end
  end

  # Delegate reload back to the main LiveView module
  defp reload(socket, _original_socket) do
    PlatformWeb.ControlCenterLive.reload_selected_agent(socket)
  end
end
