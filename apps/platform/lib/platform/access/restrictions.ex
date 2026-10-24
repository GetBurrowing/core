defmodule Platform.Access.Restrictions do
  @moduledoc """
  Context-only channel restrictions (task 01a1386e-59d1 stage 2).
  Replacing restrictions is atomic; only built-ins or custom roles belonging
  to the channel's org are accepted. Org-less channels belong to the root org.
  Reads are evaluated at decision time; holdings remain a Scope snapshot.
  """
  import Ecto.Query, only: [from: 2]
  alias Platform.Access.{Role, SpaceRestriction}
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy

  def restrict_space(space, role_keys, actor_id \\ nil)
  def restrict_space(%Space{id: id}, keys, actor_id), do: restrict_space(id, keys, actor_id)

  def restrict_space(id, keys, actor_id) when is_binary(id) and is_list(keys) do
    if Platform.UUID.valid?(id),
      do: do_restrict_space(id, keys, actor_id),
      else: {:error, :not_found}
  end

  defp do_restrict_space(id, keys, actor_id) do
    Repo.transaction(fn ->
      case Repo.one(from(s in Space, where: s.id == ^id, lock: "FOR UPDATE")) do
        %Space{kind: "channel"} = space ->
          org_id = space.org_id || root_id()
          keys = Enum.uniq(keys)
          # Lock the roles against concurrent deletion until the restriction is saved.
          roles = Repo.all(from(r in Role, where: r.key in ^keys, lock: "FOR SHARE"))

          unless length(roles) == length(keys) and
                   Enum.all?(roles, &(&1.builtin or &1.org_id == org_id)),
                 do: Repo.rollback(:invalid_role)

          Repo.delete_all(from(r in SpaceRestriction, where: r.space_id == ^id))
          now = DateTime.utc_now()

          rows =
            Enum.map(
              keys,
              &%{space_id: id, role_key: &1, restricted_by: actor_id, inserted_at: now}
            )

          Repo.insert_all(SpaceRestriction, rows)
          space

        nil ->
          Repo.rollback(:not_found)

        _ ->
          Repo.rollback(:unsupported_kind)
      end
    end)
  end

  def unrestrict_space(space), do: restrict_space(space, [], nil)

  def restricted_role_keys(space_id) do
    Repo.all(
      from(r in SpaceRestriction,
        where: r.space_id == ^space_id,
        order_by: r.role_key,
        select: r.role_key
      )
    )
  end

  @doc """
  The ids among `ids` that carry ANY restriction row, as a MapSet: the
  role-gated ("private") channels, whether or not a given reader holds the
  role. One query for the whole list. Which of them a reader cannot open is
  `Platform.Access.restricted_space_ids/2`'s answer, not this one's.
  """
  def gated_space_ids(ids) when is_list(ids) do
    case Enum.filter(ids, &Platform.UUID.valid?/1) do
      [] ->
        MapSet.new()

      valid ->
        from(r in SpaceRestriction,
          where: r.space_id in ^valid,
          distinct: true,
          select: r.space_id
        )
        |> Repo.all()
        |> MapSet.new()
    end
  end

  defp root_id do
    case Tenancy.get_root_org() do
      %{id: id} -> id
      nil -> nil
    end
  end
end
