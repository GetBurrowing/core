defmodule Platform.Mobile.AppPeople do
  @moduledoc """
  The native app's people directory (task 01a111bb): the humans and agents
  Siri can message or call, served as `GET /api/app/people` and
  `POST /api/app/people/:user_id/dm` by `PlatformWeb.AppIntentsController`.

  ## One candidate predicate

  Every person this module returns comes out of `Platform.Chat.dm_candidates/3`
  (humans) or `Platform.Chat.dm_agent_candidates/3` (agents), the functions
  the web New Conversation picker calls. A search passes the query through;
  the recent-collaborator list passes the ids it found through `:ids`. So an
  external user is offered exactly the allow-listed people the picker offers
  them, and no agents, on both branches.

  ## Rows

  `%{id, kind: "user" | "agent", name, org_names, dm_space_id}`.

  ## The directory (`scope: "directory"`)

  What the app puts in the device's Spotlight index so Siri can resolve a
  spoken name (task 01a111bb stage 7): on iOS 27.0.1 Siri matches a name
  against indexed entities and never calls the app's string query. It is the
  recent collaborators, then everyone who shares a space with the caller,
  then the members of the caller's orgs, plus the agents the picker offers.
  Every human goes through `Chat.dm_candidates/3` with `:ids`, so an
  external caller gets only allow-listed people and no agents, exactly as
  the search does. No email and
  no phone: a person is named by display name only. `dm_space_id` is the
  caller's existing DM with that person, or nil; listing never creates one.

  The caller is never in the list.

  Nothing here logs a name, a query or a message.
  """

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Mobile.AppEntities
  alias Platform.Repo
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @search_default_limit 20
  @search_max_limit 50
  @recent_limit 20
  @recent_days 30
  @directory_limit 500
  @directory_agent_limit 100

  @doc """
  With a non-blank `opts[:q]`, a search over humans and agents, at most
  `opts[:limit]` rows (clamped by `AppEntities.clamp_limit/3`). Without it,
  the caller's recent collaborators: the humans and agents in DMs and groups
  where the caller posted in the last #{@recent_days} days, ordered by the
  last activity in a space they share, at most #{@recent_limit}.

  With no `q` and `opts[:scope] == "directory"`, the directory (see the
  moduledoc): at most #{@directory_limit} humans and #{@directory_agent_limit}
  agents.
  """
  @spec list_people(User.t(), keyword()) :: [map()]
  def list_people(%User{} = user, opts \\ []) do
    case {normalize_query(Keyword.get(opts, :q)), Keyword.get(opts, :scope)} do
      {nil, "directory"} -> directory(user)
      {nil, _scope} -> recent_collaborators(user)
      {q, _scope} -> search(user, q, Keyword.get(opts, :limit))
    end
  end

  defp normalize_query(q) when is_binary(q) do
    case String.trim(q) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_query(_), do: nil

  # ── search ───────────────────────────────────────────────────────────

  defp search(user, q, limit) do
    limit = AppEntities.clamp_limit(limit, @search_default_limit, @search_max_limit)

    humans =
      user
      |> Chat.dm_candidates(q)
      |> Enum.reject(&(&1.id == user.id))
      |> Enum.map(&{"user", &1.id, &1.name})

    agents =
      user
      |> Chat.dm_agent_candidates(q)
      |> Enum.map(&{"agent", &1.id, &1.name})

    (humans ++ agents)
    |> Enum.sort_by(fn {_kind, id, name} -> {String.downcase(name || ""), id} end)
    |> Enum.take(limit)
    |> to_rows(user)
  end

  # ── recent collaborators ─────────────────────────────────────────────

  defp recent_collaborators(user) do
    since = DateTime.add(DateTime.utc_now(), -@recent_days * 86_400, :second)

    ranked = collaborator_activity(user, since)

    user_ids = for {"user", id, _at} <- ranked, do: id
    agent_ids = for {"agent", id, _at} <- ranked, do: id

    # The SAME predicate the search and the picker use, asked about this set.
    humans = permitted(user_ids, &Chat.dm_candidates(user, "", ids: &1))
    agents = permitted(agent_ids, &Chat.dm_agent_candidates(user, "", ids: &1))

    ranked
    |> Enum.flat_map(fn {kind, id, _at} ->
      source = if kind == "user", do: humans, else: agents

      case Map.fetch(source, id) do
        {:ok, name} -> [{kind, id, name}]
        :error -> []
      end
    end)
    |> Enum.take(@recent_limit)
    |> to_rows(user)
  end

  defp permitted([], _fun), do: %{}
  defp permitted(ids, fun), do: ids |> fun.() |> Map.new(&{&1.id, &1.name})

  # `[{kind, id, last_activity}]`, newest first: every other human or agent
  # in a non-archived DM or group where the caller posted since `since`,
  # ranked by the newest message in any such space they share.
  defp collaborator_activity(%User{id: user_id}, since) do
    my_spaces =
      from(m in Message,
        join: p in Participant,
        on: p.id == m.participant_id,
        join: s in Space,
        on: s.id == m.space_id,
        where:
          p.participant_type == "user" and p.participant_id == ^user_id and
            s.kind in ["dm", "group"] and is_nil(s.archived_at) and is_nil(m.deleted_at) and
            m.inserted_at >= ^since,
        distinct: true,
        select: m.space_id
      )

    activity =
      from(m in Message,
        where:
          m.space_id in subquery(my_spaces) and is_nil(m.deleted_at) and
            m.inserted_at >= ^since,
        group_by: m.space_id,
        select: %{space_id: m.space_id, last_at: max(m.inserted_at)}
      )

    from(p in Participant,
      join: a in subquery(activity),
      on: a.space_id == p.space_id,
      where:
        p.participant_type in ["user", "agent"] and
          not (p.participant_type == "user" and p.participant_id == ^user_id),
      group_by: [p.participant_type, p.participant_id],
      order_by: [desc: max(a.last_at), asc: p.participant_id],
      select: {p.participant_type, p.participant_id, max(a.last_at)}
    )
    |> Repo.all()
  end

  # ── directory ────────────────────────────────────────────────────

  defp directory(%User{id: user_id} = user) do
    since = DateTime.add(DateTime.utc_now(), -@recent_days * 86_400, :second)
    recent = for {"user", id, _at} <- collaborator_activity(user, since), do: id

    candidates =
      (recent ++ space_mates(user_id) ++ org_mates(user_id))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == user_id))

    # The SAME predicate as the search and the picker, asked about this set.
    humans = permitted(candidates, &Chat.dm_candidates(user, "", ids: &1))
    recent_set = MapSet.new(recent)

    {recent_rows, rest} =
      candidates
      |> Enum.flat_map(fn id ->
        case Map.fetch(humans, id) do
          {:ok, name} -> [{"user", id, name}]
          :error -> []
        end
      end)
      |> Enum.split_with(fn {_kind, id, _name} -> MapSet.member?(recent_set, id) end)

    by_name = fn {_kind, id, name} -> {String.downcase(name || ""), id} end
    human_rows = Enum.take(recent_rows ++ Enum.sort_by(rest, by_name), @directory_limit)

    agent_rows =
      user
      |> Chat.dm_agent_candidates("")
      |> Enum.map(&{"agent", &1.id, &1.name})
      |> Enum.sort_by(by_name)
      |> Enum.take(@directory_agent_limit)

    to_rows(human_rows ++ agent_rows, user)
  end

  # Every other human in a non-archived space the caller is a member of.
  defp space_mates(user_id) do
    mine =
      from(p in Participant,
        join: s in Space,
        on: s.id == p.space_id,
        where:
          p.participant_type == "user" and p.participant_id == ^user_id and
            is_nil(s.archived_at),
        select: p.space_id
      )

    from(p in Participant,
      where: p.space_id in subquery(mine) and p.participant_type == "user",
      distinct: true,
      select: p.participant_id
    )
    |> Repo.all()
  end

  # Every member of an org the caller belongs to.
  defp org_mates(user_id) do
    mine = from(m in OrgMembership, where: m.user_id == ^user_id, select: m.org_id)

    from(m in OrgMembership,
      where: m.org_id in subquery(mine),
      distinct: true,
      select: m.user_id
    )
    |> Repo.all()
  end

  # ── rows ─────────────────────────────────────────────────────────────

  defp to_rows([], _user), do: []

  defp to_rows(entries, user) do
    user_ids = for {"user", id, _name} <- entries, do: id
    orgs = org_names(user_ids)
    dms = dm_spaces(user, entries)

    Enum.map(entries, fn {kind, id, name} ->
      %{
        id: id,
        kind: kind,
        name: display_name(kind, name),
        org_names: Map.get(orgs, id, []),
        dm_space_id: Map.get(dms, {kind, id})
      }
    end)
  end

  defp display_name(_kind, name) when is_binary(name) and name != "", do: name
  defp display_name("agent", _name), do: "Agent"
  defp display_name(_kind, _name), do: "User"

  defp org_names([]), do: %{}

  defp org_names(user_ids) do
    from(m in OrgMembership,
      join: o in Org,
      on: o.id == m.org_id,
      where: m.user_id in ^user_ids,
      order_by: [asc: o.name],
      select: {m.user_id, o.name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, names} -> {id, Enum.uniq(names)} end)
  end

  # The caller's existing, non-archived direct DMs with these people, in one
  # query. Keyed `{kind, id}`.
  defp dm_spaces(%User{id: user_id}, entries) do
    ids = entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    from(s in Space,
      join: me in Participant,
      on: me.space_id == s.id,
      join: them in Participant,
      on: them.space_id == s.id,
      where:
        s.kind == "dm" and s.is_direct == true and is_nil(s.archived_at) and
          me.participant_type == "user" and me.participant_id == ^user_id and
          them.id != me.id and them.participant_id in ^ids,
      order_by: [asc: s.inserted_at],
      select: {{them.participant_type, them.participant_id}, s.id}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {key, space_id}, acc -> Map.put_new(acc, key, space_id) end)
  end

  # ── open a DM ────────────────────────────────────────────────────────

  @doc """
  Find or create the caller's DM with the human `target_user_id`, through
  `Chat.find_or_create_dm/4` (which refuses a non-allow-listed target for an
  external caller with `:dm_not_allowed`). Returns the space id and its
  `path_segment`.
  """
  @spec open_dm(User.t(), term()) ::
          {:ok, map()} | {:error, :not_found | :dm_not_allowed | term()}
  def open_dm(%User{id: user_id}, target_user_id) do
    with true <- is_binary(target_user_id) and Platform.UUID.valid?(target_user_id),
         true <- target_user_id != user_id,
         %User{archived_at: nil} <- Accounts.get_user(target_user_id),
         {:ok, %Space{} = space} <- Chat.find_or_create_dm(user_id, "user", target_user_id) do
      {:ok, %{space_id: space.id, path_segment: Chat.space_path_segment(space)}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end
end
