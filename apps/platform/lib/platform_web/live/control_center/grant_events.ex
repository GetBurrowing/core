defmodule PlatformWeb.ControlCenter.GrantEvents do
  @moduledoc """
  The Grant panel behind the capped bundle line (task `01a1a2e4-9265`
  stage 3): an org admin lifts an owner cap in place by giving the owner
  (and the agent) a custom role that carries the missing permission.

  Two gates, both server-side:

    1. `ControlCenterLive`'s `:access_admin` event policy, which calls
       `can_grant?/2` with a Scope rebuilt for the event and the runtime of
       `socket.assigns.selected_agent`. The org is derived from that runtime's
       owner, never from event params.
    2. `Platform.Access.RoleAdmin`, which re-checks `manages_org?` itself.

  A member owner manages their own agent, so the `:manage_selected` policy is
  the wrong rule here: they must not be able to grant themselves a role.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Platform.Access
  alias Platform.Access.{Caps, Effective, PermissionLabels, Registry, RoleAdmin, Scope}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation

  @forbidden "Only an org admin can grant this."
  @owner_required "The owner must get the role: an agent's own roles never lift its owner's cap."

  @doc "The refusal copy for a non-admin."
  @spec forbidden_message() :: String.t()
  def forbidden_message, do: @forbidden

  @doc """
  May `scope` grant roles for `agent`'s runtime? True only when the scope
  manages the org of the runtime's owner (`Effective.manages_org?/2`).
  """
  @spec can_grant?(Scope.t() | nil, Agent.t() | nil) :: boolean()
  def can_grant?(%Scope{} = scope, %Agent{} = agent) do
    case runtime_for(agent) do
      %AgentRuntime{} = runtime ->
        case Caps.owner(runtime) do
          %{org_id: org_id} when is_binary(org_id) -> Effective.manages_org?(scope, org_id)
          _ -> false
        end

      nil ->
        false
    end
  end

  def can_grant?(_scope, _agent), do: false

  @doc "Handle one Grant panel event. The policy gate has already run."
  def handle("open_grant_panel", %{"bundle" => bundle, "permission" => permission}, socket) do
    with %AgentRuntime{} = runtime <- runtime_for(socket.assigns[:selected_agent]),
         true <- capped?(runtime, bundle, permission) do
      {:noreply, assign(socket, :grant_panel, panel(socket, runtime, bundle, permission))}
    else
      _ -> {:noreply, put_flash(socket, :error, "That permission is not capped.")}
    end
  end

  def handle("open_grant_panel", _params, socket), do: {:noreply, socket}

  def handle("close_grant_panel", _params, socket),
    do: {:noreply, assign(socket, :grant_panel, nil)}

  def handle("grant_path_change", params, socket) do
    case socket.assigns[:grant_panel] do
      %{} = panel -> {:noreply, assign(socket, :grant_panel, apply_params(panel, params))}
      nil -> {:noreply, socket}
    end
  end

  def handle("grant_capped_permission", params, socket) do
    panel = socket.assigns[:grant_panel]
    panel = if panel, do: apply_params(panel, params), else: nil
    permission = (panel && panel.permission) || Map.get(params, "permission")

    result =
      case runtime_for(socket.assigns[:selected_agent]) do
        %AgentRuntime{} = runtime ->
          RoleAdmin.grant_capped(socket.assigns.access_scope, runtime, %{
            permission: permission,
            role: role_choice(panel, params),
            owner?: flag(panel, params, :owner?, "owner"),
            agent?: flag(panel, params, :agent?, "agent")
          })

        nil ->
          {:error, :not_found}
      end

    case {result, panel} do
      {{:ok, _}, _} ->
        {:noreply,
         socket
         |> assign(:grant_panel, nil)
         |> put_flash(:info, "Granted.")}

      {{:error, reason}, %{} = panel} ->
        {:noreply, assign(socket, :grant_panel, %{panel | error: error_message(reason)})}

      {{:error, reason}, nil} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @doc "The copy shown inline in the panel for a `grant_capped/3` error."
  @spec error_message(term()) :: String.t()
  def error_message(:owner_required), do: @owner_required
  def error_message(:forbidden), do: @forbidden
  def error_message(:role_lacks_permission), do: "That role doesn't carry this permission."

  def error_message({:exceeds_actor, _}),
    do: "You can only grant permissions you hold yourself."

  def error_message({:module_admin, _}), do: "Module admin permissions can't be granted here."

  def error_message(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :name) do
      {msg, _} -> "Role name #{msg}."
      nil -> "Couldn't save the role."
    end
  end

  def error_message(_), do: "Couldn't grant this."

  # ── internals ─────────────────────────────────────────────────────────

  defp runtime_for(%Agent{} = agent), do: Federation.get_runtime_for_agent(agent)
  defp runtime_for(_), do: nil

  defp capped?(runtime, bundle, permission) do
    runtime
    |> Caps.for_runtime()
    |> Map.get(bundle, [])
    |> Enum.any?(&(&1.permission == permission))
  end

  defp panel(socket, runtime, bundle, permission) do
    scope = socket.assigns.access_scope
    %{user: owner, org_id: org_id} = Caps.owner(runtime)

    roles =
      case RoleAdmin.list_custom_roles(scope, org_id) do
        {:ok, roles} -> Enum.filter(roles, &Map.has_key?(&1.permissions || %{}, permission))
        _ -> []
      end

    %{
      bundle: bundle,
      permission: permission,
      label: PermissionLabels.label(permission),
      owner_name: (owner && (owner.name || owner.email)) || "",
      agent_id: socket.assigns.selected_agent.id,
      agent_name: socket.assigns.selected_agent.name,
      roles: roles,
      offered: offered(scope, permission),
      path: if(roles == [], do: "new", else: "existing"),
      role_key: roles |> List.first() |> then(&(&1 && &1.key)),
      new_name: "",
      new_permissions: [permission],
      owner?: true,
      agent?: true,
      error: nil
    }
  end

  # The missing permission plus its module siblings the acting admin holds
  # (module-admin permissions are never offered, matching RoleAdmin).
  defp offered(scope, permission) do
    module = Registry.module_of(permission)

    Registry.permissions()
    |> Enum.filter(&(&1.module == module and not &1.module_admin and not &1.install_level))
    |> Enum.map(& &1.name)
    |> Enum.filter(&(&1 == permission or Access.holds_anywhere?(scope, &1)))
    |> Enum.map(&%{permission: &1, label: PermissionLabels.label(&1)})
  end

  defp apply_params(panel, params) do
    path = if Map.get(params, "path") in ~w(existing new), do: params["path"], else: panel.path
    path = if path == "existing" and panel.roles == [], do: "new", else: path

    %{
      panel
      | path: path,
        role_key: Map.get(params, "role_key", panel.role_key),
        new_name: Map.get(params, "name", panel.new_name),
        new_permissions:
          params
          |> Map.get("permissions", panel.new_permissions)
          |> List.wrap()
          |> Enum.reject(&(&1 == "")),
        owner?: Map.get(params, "owner", to_string(panel.owner?)) == "true",
        agent?: Map.get(params, "agent", to_string(panel.agent?)) == "true",
        error: nil
    }
  end

  defp role_choice(%{path: "existing", role_key: key}, _params), do: {:existing, key}

  defp role_choice(%{path: "new"} = panel, _params),
    do: {:new, String.trim(panel.new_name || ""), List.wrap(panel.new_permissions)}

  defp role_choice(nil, %{"path" => "new"} = params),
    do:
      {:new, Map.get(params, "name", ""),
       params |> Map.get("permissions", []) |> List.wrap() |> Enum.reject(&(&1 == ""))}

  defp role_choice(nil, params), do: {:existing, Map.get(params, "role_key")}

  defp flag(%{} = panel, _params, key, _name), do: Map.fetch!(panel, key)
  defp flag(nil, params, _key, name), do: Map.get(params, name, "true") == "true"
end
