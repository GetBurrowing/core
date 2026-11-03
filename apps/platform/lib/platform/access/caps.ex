defmodule Platform.Access.Caps do
  @moduledoc """
  Which of a runtime's bundle permissions its OWNER caps away (task
  `01a1a2e4-9265` stage 1).

  A runtime's tool decision is `Platform.Access.Tools.effective_tools/1`:
  a tool survives when `Platform.Access.holds_anywhere?/2` holds its
  permission over the runtime Scope, which ANDs the agent's own side
  (`own_cap`) with its owner's (`owner_cap`), both stored on the Scope by
  `Platform.Access.Scope.intersect/2`. A permission is CAPPED when the own
  side holds it and the owner side does not: the bundle is on and its
  profile allows the permission, yet the owner's roles remove it.

  This module reads that same Scope rather than re-deriving the owner's
  role data, so what the agent page reports cannot drift from what
  `Platform.Federation.ToolAuthorization.authorize/2` decides.

  Only the OWNER's roles lift a cap: an agent's own role assignments
  contribute keys and role grants, never permissions (`Scope` moduledoc).
  """

  alias Platform.Access
  alias Platform.Access.{PermissionLabels, RuntimeProfiles, Scope, ToolPermissions}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime

  @type capped :: %{permission: String.t(), label: String.t()}

  @doc """
  `%{bundle => [%{permission, label}]}` for every bundle in the runtime's
  tool profile that has at least one capped permission. Bundles with nothing
  capped are omitted, and a runtime whose Scope carries no own/owner sides
  answers `%{}`.
  """
  @spec for_runtime(AgentRuntime.t()) :: %{String.t() => [capped()]}
  def for_runtime(%AgentRuntime{} = runtime) do
    profile = RuntimeProfiles.get(runtime)

    runtime
    |> Scope.for_runtime(profile)
    |> from_scope(RuntimeProfiles.tool_profile(runtime, profile))
  end

  def for_runtime(_), do: %{}

  @doc """
  The capped permissions of `bundles` over an already-built runtime Scope.
  A Scope without both an own and an owner side caps nothing.
  """
  @spec from_scope(Scope.t(), [String.t()]) :: %{String.t() => [capped()]}
  def from_scope(%Scope{own_cap: %Scope{} = own, owner_cap: %Scope{} = owner}, bundles)
      when is_list(bundles) do
    bundles
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn bundle, acc ->
      case capped_in(bundle, own, owner) do
        [] -> acc
        entries -> Map.put(acc, bundle, entries)
      end
    end)
  end

  def from_scope(_scope, _bundles), do: %{}

  @doc """
  The runtime's owner and the owner's Scope org (the org a grant to lift the
  cap is made in). An ownerless runtime has `user: nil, org_id: nil`.
  """
  @spec owner(AgentRuntime.t()) :: %{user: User.t() | nil, org_id: binary() | nil}
  def owner(%AgentRuntime{owner_user_id: owner_id}) when is_binary(owner_id) do
    case Accounts.get_user(owner_id) do
      %User{} = user ->
        org_id =
          case Scope.for_user(user) do
            %Scope{org: %{id: id}} -> id
            _ -> nil
          end

        %{user: user, org_id: org_id}

      nil ->
        %{user: nil, org_id: nil}
    end
  end

  def owner(_runtime), do: %{user: nil, org_id: nil}

  defp capped_in(bundle, own, owner) do
    bundle
    |> ToolPermissions.bundle_permissions()
    |> Enum.sort()
    |> Enum.filter(&capped?(&1, own, owner))
    |> Enum.map(&%{permission: &1, label: PermissionLabels.label(&1)})
  end

  defp capped?(permission, own, owner),
    do: Access.holds_anywhere?(own, permission) and not Access.holds_anywhere?(owner, permission)
end
