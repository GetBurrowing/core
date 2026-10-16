defmodule Platform.Access.IdpGroupRoles do
  @moduledoc """
  IdP group mappings and login-time assignment sync. This context produces
  role holdings; `Platform.Access` remains the permission decision point.
  """
  import Ecto.Query, only: [from: 2]

  alias Platform.Access.{IdpGroupRole, Role, RoleAssignment, Roles}
  alias Platform.Accounts.User
  alias Platform.OIDC
  alias Platform.Repo
  alias Platform.Tenancy.OrgGroupClaim
  alias Platform.Tenancy.OrgMembership

  @doc "The configured external marker as an implicit guest mapping, followed by stored mappings."
  def mappings do
    implicit =
      case normalize(OIDC.external_group()) do
        nil -> []
        group -> [%{group_value: group, role_key: "guest", org_id: nil, implicit?: true}]
      end

    stored = Repo.all(from(m in IdpGroupRole, order_by: [m.group_value, m.role_key, m.org_id]))
    implicit ++ Enum.reject(stored, &duplicate_implicit?(&1, implicit))
  end

  @doc "Create a guest or custom-role mapping. Built-in admin/member cannot be mapped."
  def create(attrs) when is_map(attrs) do
    changeset = IdpGroupRole.changeset(%IdpGroupRole{}, attrs)
    key = Ecto.Changeset.get_field(changeset, :role_key)
    org_id = Ecto.Changeset.get_field(changeset, :org_id)
    group = Ecto.Changeset.get_field(changeset, :group_value)

    cond do
      key in ["admin", "member"] ->
        {:error, :builtin_role}

      key == "guest" and not is_nil(org_id) ->
        {:error, :guest_has_no_org}

      key == "guest" and group == normalize(OIDC.external_group()) ->
        {:error, :implicit_mapping}

      key == "guest" ->
        Repo.insert(changeset)

      not is_binary(key) ->
        Repo.insert(changeset)

      true ->
        case Roles.get_role(key) do
          %Role{builtin: false, org_id: ^org_id} when is_binary(org_id) ->
            Repo.insert(changeset)

          %Role{builtin: false} ->
            {:error, :org_mismatch}

          _ ->
            {:error, :role_not_found}
        end
    end
  end

  def create_mapping(attrs), do: create(attrs)

  @doc "Remove a stored mapping by id. The implicit external marker cannot be removed."
  def delete(%IdpGroupRole{id: id}), do: delete(id)

  def delete(id) when is_binary(id) do
    if Platform.UUID.valid?(id) do
      case Repo.get(IdpGroupRole, id) do
        nil -> {:error, :not_found}
        mapping -> Repo.delete(mapping)
      end
    else
      {:error, :not_found}
    end
  end

  def delete_mapping(mapping), do: delete(mapping)

  @doc "Every mapping matched by the normalized claim values."
  def roles_for_groups(groups) when is_list(groups) do
    values = groups |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
    Enum.filter(mappings(), &MapSet.member?(values, &1.group_value))
  end

  def roles_for_groups(_), do: []

  @doc "Whether any claim value names the guest role, including the implicit marker."
  def guest_group?(groups), do: Enum.any?(roles_for_groups(groups), &(&1.role_key == "guest"))

  @doc """
  Reconcile only `source: "idp"` custom-role assignments for an internal user.
  Matching roles in orgs without a nonexternal membership are ignored. Manual
  assignments are never changed. Returns applied and revoked row counts.
  """
  def sync_user(%User{id: user_id}, groups) when is_list(groups) do
    Repo.transaction(fn ->
      Repo.one!(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))

      member_orgs =
        Repo.all(
          from(m in OrgMembership,
            where: m.user_id == ^user_id and not m.external,
            select: m.org_id
          )
        )
        |> MapSet.new()

      desired =
        groups
        |> roles_for_groups()
        |> Enum.filter(&(&1.role_key != "guest" and MapSet.member?(member_orgs, &1.org_id)))
        |> Enum.map(&{&1.org_id, &1.role_key})
        |> MapSet.new()

      existing =
        Repo.all(
          from(a in RoleAssignment,
            where: a.principal_type == "user" and a.principal_id == ^user_id and a.source == "idp"
          )
        )

      revoked =
        Enum.count(existing, fn assignment ->
          if MapSet.member?(desired, {assignment.org_id, assignment.role_key}) do
            false
          else
            Repo.delete!(assignment)
            true
          end
        end)

      existing_keys = MapSet.new(existing, &{&1.org_id, &1.role_key})

      applied =
        desired
        |> MapSet.difference(existing_keys)
        |> Enum.count(fn {org_id, key} ->
          case Roles.assign(%{
                 principal: {:user, user_id},
                 role: key,
                 org_id: org_id,
                 source: "idp"
               }) do
            {:ok, _} -> true
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      %{applied: applied, revoked: revoked}
    end)
  end

  defp duplicate_implicit?(mapping, implicit) do
    Enum.any?(
      implicit,
      &(&1.group_value == mapping.group_value and &1.role_key == mapping.role_key)
    )
  end

  defp normalize(value) when is_binary(value) do
    case OrgGroupClaim.normalize(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize(_), do: nil
end
