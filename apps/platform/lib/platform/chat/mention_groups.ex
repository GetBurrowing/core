defmodule Platform.Chat.MentionGroups do
  @moduledoc "Organization-scoped groups. Membership is an address book, never an access grant."
  import Ecto.Query
  alias Platform.{Repo, Tenancy}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat.{MentionGroup, MentionGroupMember, Participant, Space}
  alias Platform.Tenancy.{Org, OrgMembership}

  def list_groups(actor, org_id) do
    if discover?(actor, org_id) do
      {:ok, active_groups(org_id) |> Repo.all() |> attach_members()}
    else
      {:error, :forbidden}
    end
  end

  def get_group(actor, id) do
    with %MentionGroup{} = group <- lookup_group(id),
         true <- discover?(actor, group.org_id) do
      {:ok, attach_members(group)}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :forbidden}
    end
  end

  def create_group(actor, org_id, attrs) when is_map(attrs) do
    if manage?(actor, org_id) do
      Repo.transaction(fn ->
        members = validated_members!(org_id, value(attrs, :members, []))
        group = %MentionGroup{org_id: org_id, created_by_user_id: user_id(actor)}
        group = insert_or_rollback(MentionGroup.changeset(group, name_attrs(attrs)))
        replace_members!(group, members)
        attach_members(group)
      end)
    else
      {:error, :forbidden}
    end
  end

  def create_group(_, _, _), do: {:error, :invalid_attrs}

  def update_group(actor, id, attrs) when is_map(attrs) do
    mutate(actor, id, fn group ->
      members = value(attrs, :members, :unchanged)
      if members != :unchanged, do: validated_members!(group.org_id, members)
      updated = update_or_rollback(MentionGroup.changeset(group, name_attrs(attrs)))

      if members != :unchanged,
        do: replace_members!(updated, validated_members!(group.org_id, members))

      attach_members(updated)
    end)
  end

  def update_group(_, _, _), do: {:error, :invalid_attrs}

  def archive_group(actor, id) do
    mutate(actor, id, fn group ->
      group
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> update_or_rollback()
      |> attach_members()
    end)
  end

  def list_candidates(actor, org_id) do
    if manage?(actor, org_id), do: {:ok, candidates(org_id)}, else: {:error, :forbidden}
  end

  def groups_for_space(%Space{} = space, %Participant{} = author) do
    if eligible_participant?(author, space) and usable_author?(author, space.org_id) do
      participants = Repo.all(from(p in Participant, where: p.space_id == ^space.id))

      eligible =
        participants
        |> Enum.reject(&(&1.id == author.id))
        |> Enum.filter(&eligible_participant?(&1, space))
        |> MapSet.new(&{&1.participant_type, &1.participant_id})

      active_groups(space.org_id)
      |> Repo.all()
      |> attach_members()
      |> Enum.map(fn group ->
        %{
          group
          | eligible_count: Enum.count(group.members, &MapSet.member?(eligible, {&1.type, &1.id}))
        }
      end)
    else
      []
    end
  end

  def groups_for_space(_, _), do: []

  @doc "Current exact participation, active principals/org/space, and existing read/wake policy."
  def eligible_participant?(%Participant{} = participant, %Space{id: space_id}) do
    with true <- Platform.UUID.valid?(participant.id) and Platform.UUID.valid?(space_id),
         %Space{archived_at: nil, deletion_scheduled_at: nil} = space <- Repo.get(Space, space_id),
         true <- active_org?(space.org_id),
         %Participant{} = current <- Repo.get(Participant, participant.id),
         true <-
           current.space_id == space.id and
             current.participant_type == participant.participant_type and
             current.participant_id == participant.participant_id do
      eligible_principal?(current, space)
    else
      _ -> false
    end
  end

  def eligible_participant?(_, _), do: false

  defp eligible_principal?(%Participant{participant_type: "user", participant_id: id}, space) do
    with %User{archived_at: nil} = user <- Repo.get(User, id),
         true <-
           Repo.exists?(
             from(m in OrgMembership, where: m.org_id == ^space.org_id and m.user_id == ^id)
           ) do
      Platform.Access.check(Platform.Access.Scope.for_user(user), "chat.read", {:space, space.id}) ==
        :ok
    else
      _ -> false
    end
  end

  defp eligible_principal?(
         %Participant{participant_type: "agent", participant_id: id, role: role},
         space
       )
       when role in ["principal", "member"] do
    match?(%Agent{status: "active"}, Repo.get(Agent, id)) and
      not MapSet.member?(
        Platform.Access.AgentWake.denied([id], "chat.read", {:space, space.id}),
        id
      )
  end

  defp eligible_principal?(_, _), do: false

  defp usable_author?(%Participant{participant_type: "agent"}, _), do: true

  defp usable_author?(%Participant{participant_type: "user", participant_id: id}, org_id),
    do: discover?(%{id: id}, org_id)

  defp usable_author?(_, _), do: false

  defp mutate(actor, id, fun) do
    if Platform.UUID.valid?(id) do
      Repo.transaction(fn ->
        group =
          Repo.one(
            from(g in MentionGroup,
              where: g.id == ^id and is_nil(g.deleted_at),
              lock: "FOR UPDATE"
            )
          )

        if is_nil(group), do: Repo.rollback(:not_found)
        if not manage?(actor, group.org_id), do: Repo.rollback(:forbidden)
        fun.(group)
      end)
    else
      {:error, :not_found}
    end
  end

  defp active_groups(org_id),
    do:
      from(g in MentionGroup,
        where: g.org_id == ^org_id and is_nil(g.deleted_at),
        order_by: [asc: g.normalized_name]
      )

  defp lookup_group(id) do
    if Platform.UUID.valid?(id),
      do: Repo.one(from(g in MentionGroup, where: g.id == ^id and is_nil(g.deleted_at)))
  end

  defp active_org?(id) do
    Platform.UUID.valid?(id) and
      Repo.exists?(
        from(o in Org,
          where: o.id == ^id and is_nil(o.archived_at) and is_nil(o.deletion_scheduled_at)
        )
      )
  end

  defp discover?(actor, org_id),
    do:
      active_org?(org_id) and active_user?(actor) and
        Tenancy.internal_member?(%{id: user_id(actor)}, org_id) and
        not Tenancy.external_user?(%{id: user_id(actor)})

  defp manage?(actor, org_id),
    do: discover?(actor, org_id) and Tenancy.org_admin?(%{id: user_id(actor)}, org_id)

  defp active_user?(actor) do
    id = user_id(actor)
    Platform.UUID.valid?(id) and match?(%User{archived_at: nil}, Repo.get(User, id))
  end

  defp user_id(%Agent{}), do: nil
  defp user_id(%Participant{}), do: nil
  defp user_id(%{id: id}), do: id
  defp user_id({:user, id}), do: id
  defp user_id(_), do: nil

  defp candidates(org_id) do
    users =
      Repo.all(
        from(u in User,
          join: m in OrgMembership,
          on: m.user_id == u.id,
          where: m.org_id == ^org_id and is_nil(u.archived_at),
          select: %{type: "user", id: u.id, name: u.name}
        )
      )

    agents =
      Repo.all(
        from(a in Agent,
          join: p in Participant,
          on: p.participant_id == a.id and p.participant_type == "agent",
          join: s in Space,
          on: s.id == p.space_id,
          where:
            s.org_id == ^org_id and is_nil(s.archived_at) and is_nil(s.deletion_scheduled_at) and
              a.status == "active",
          distinct: true,
          select: %{type: "agent", id: a.id, name: a.name}
        )
      )

    Enum.sort_by(users ++ agents, &{&1.type, String.downcase(&1.name || ""), &1.id})
  end

  defp validated_members!(org_id, members) when is_list(members) do
    allowed = MapSet.new(candidates(org_id), &{&1.type, &1.id})

    Enum.map(members, fn
      member when is_map(member) ->
        type = value(member, :type)
        id = value(member, :id)

        if type not in ["user", "agent"] or not Platform.UUID.valid?(id) or
             not MapSet.member?(allowed, {type, id}),
           do: Repo.rollback(:invalid_members)

        %{type: type, id: id}

      _ ->
        Repo.rollback(:invalid_members)
    end)
    |> Enum.uniq()
  end

  defp validated_members!(_, _), do: Repo.rollback(:invalid_members)

  defp replace_members!(group, members) do
    Repo.delete_all(from(m in MentionGroupMember, where: m.group_id == ^group.id))

    Enum.each(members, fn member ->
      field = if member.type == "user", do: :user_id, else: :agent_id
      Repo.insert!(struct(MentionGroupMember, %{field => member.id, :group_id => group.id}))
    end)
  end

  defp attach_members(%MentionGroup{} = group), do: hd(attach_members([group]))

  defp attach_members(groups) do
    ids = Enum.map(groups, & &1.id)

    members =
      Repo.all(from(m in MentionGroupMember, where: m.group_id in ^ids, order_by: m.id))
      |> Enum.group_by(& &1.group_id, &MentionGroupMember.to_view/1)

    Enum.map(groups, &%{&1 | members: Map.get(members, &1.id, [])})
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp name_attrs(attrs),
    do:
      if(Map.has_key?(attrs, :name) or Map.has_key?(attrs, "name"),
        do: %{name: value(attrs, :name)},
        else: %{}
      )

  defp insert_or_rollback(cs) do
    case Repo.insert(cs) do
      {:ok, row} -> row
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp update_or_rollback(cs) do
    case Repo.update(cs) do
      {:ok, row} -> row
      {:error, error} -> Repo.rollback(error)
    end
  end
end
