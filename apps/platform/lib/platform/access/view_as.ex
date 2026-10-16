defmodule Platform.Access.ViewAs do
  @moduledoc """
  Read-only view of a principal's real access scope. Resource lists use the
  same scoped context calls as the live surfaces and are narrowed again to
  resources the viewer may read.
  """

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Tasks
  alias Platform.Tenancy

  @roles ~w(admin member guest)

  @spec compute(Scope.t(), tuple()) :: {:ok, map()} | {:error, map()}
  def compute(%Scope{} = viewer, target) do
    with {:ok, scope, subject, org_ids, surface} <- resolve(target),
         :ok <- authorize(viewer, org_ids) do
      projects =
        Tasks.list_projects_for_user(subject, access_scope: scope)
        |> Enum.filter(&Access.can?(scope, "tasks.read", {:project, &1.id}))
        |> Enum.filter(&Access.can?(viewer, "tasks.read", {:project, &1.id}))

      channels =
        Chat.list_spaces(kind: "channel", scope: scope)
        |> Enum.filter(&Access.can?(scope, "chat.read", {:space, &1.id}))
        |> Enum.filter(&Access.can?(viewer, "chat.read", {:space, &1.id}))

      {:ok,
       %{
         scope: scope,
         resources: %{projects: projects, channels: channels},
         surface: surface,
         capped: if(match?({:agent, _}, target), do: match?(%Scope{}, scope.owner_cap), else: nil)
       }}
    end
  end

  defp resolve({:user, id}) when is_binary(id) do
    case Accounts.get_user(id) do
      nil ->
        {:error, %{rule: :not_found}}

      user ->
        org_ids = Enum.map(user.org_memberships, & &1.org_id)
        surface = if Tenancy.external_user?(user), do: :external_chat, else: :authenticated
        {:ok, Scope.for_user(user), user, org_ids, surface}
    end
  end

  defp resolve({:role, org_id, key}) when key in @roles do
    case Tenancy.get_org(org_id) do
      nil ->
        {:error, %{rule: :not_found}}

      org ->
        scope = Scope.for_role(org, key)

        {:ok, scope, scope.actor, [org.id],
         if(key == "guest", do: :external_chat, else: :authenticated)}
    end
  end

  defp resolve({:agent, runtime_id}) when is_binary(runtime_id) do
    runtime =
      Federation.get_runtime_by_runtime_id(runtime_id) ||
        if Platform.UUID.valid?(runtime_id), do: Federation.get_runtime(runtime_id)

    case runtime do
      nil ->
        {:error, %{rule: :not_found}}

      runtime ->
        owner = Accounts.get_user(runtime.owner_user_id)
        org_ids = if owner, do: Enum.map(owner.org_memberships, & &1.org_id), else: []
        {:ok, Scope.for_runtime(runtime), owner, org_ids, :agent}
    end
  end

  defp resolve(_), do: {:error, %{rule: :not_found}}

  defp authorize(viewer, org_ids) do
    root? = Access.can?(viewer, "install.admin", nil)

    org_manager? = Enum.any?(org_ids, &Access.can?(viewer, "access.manage", &1))

    resource_manager? =
      Enum.any?(org_ids, fn org_id ->
        # Authorization must see managed resources even when the viewer
        # cannot read their module's listing. These rows stay inside Access;
        # the rendered list above remains viewer-scoped.
        projects = Tasks.list_projects_unscoped(org_id: org_id)
        channels = Chat.list_spaces(kind: "channel")

        Enum.any?(projects, &Access.can?(viewer, "access.manage", &1)) or
          Enum.any?(channels, &(&1.org_id == org_id and Access.can?(viewer, "access.manage", &1)))
      end)

    if root? or org_manager? or resource_manager?,
      do: :ok,
      else: {:error, %{missing: "access.manage", rule: :not_granted}}
  end
end
