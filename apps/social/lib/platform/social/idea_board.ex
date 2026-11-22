defmodule Platform.Social.IdeaBoard do
  @moduledoc """
  What the Ideas tab reads: the three views of one list, and one idea's
  detail. Read-only.

  Profiles come from the caller, who takes them from
  `Platform.Social.list_profiles_for_user/1` (the RBAC swap point); every
  idea is read through its profile's org scope (`Platform.Social.Ideas`).

  ## One list, three views

  `views/2` reads the active (not archived) ideas of the profiles ONCE, and
  the agent votes of those ideas ONCE (`Platform.Social.IdeaVotes.summaries/2`,
  agent votes on the idea's own profile and org), and derives everything in
  memory:

    * `all`: every active idea, newest first;
    * `voted`: ideas with at least one agent vote, most votes first, then
      `IdeaVotes.order_key/2` (oldest, then id);
    * `selected`: ideas a person selected for research, most recently
      selected first.

  An idea can be in all three. A vote count never selects an idea and a
  selection never moves a vote. No lane, stage or post is read for the page.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Idea, IdeaNotes, Ideas, IdeaVotes, Post, PostEvents, Profile}

  @views ~w(all voted selected)

  @doc "The view keys, in button order."
  @spec views() :: [String.t()]
  def views, do: @views

  @doc """
  The three views for `profiles` as seen by `user_id`:
  `%{all: [card], voted: [card], selected: [card], counts: %{"all" => n, ...}}`.

  A card is `%{id, idea, profile, vote_count, voted, own_idea?, selected?,
  selected_at, selected_by_name, creator_name, notes_count, wikipedia?}`.
  `selected_by_name` is the selector's name, or "a former user" when the
  selection stands but its user is gone.
  """
  @spec views([Profile.t()], Ecto.UUID.t() | nil) :: map()
  def views(profiles, user_id) do
    ideas =
      profiles
      |> Enum.flat_map(fn %Profile{} = p -> Ideas.list(p.org_id, p.id) end)
      |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}, :desc)

    wikipedia = Social.Trends.wikipedia_idea_ids(ideas)
    votes = IdeaVotes.summaries(ideas, {:user, user_id})
    notes = IdeaNotes.counts_for_ideas(Enum.map(ideas, & &1.id))
    by_id = Map.new(profiles, &{&1.id, &1})
    names = people_names(ideas)

    all =
      for idea <- ideas do
        vote = Map.fetch!(votes, idea.id)

        %{
          id: idea.id,
          idea: idea,
          profile: Map.get(by_id, idea.profile_id),
          vote_count: vote.vote_count,
          voted: vote.voted,
          own_idea?: idea.created_by_user_id == user_id,
          selected?: not is_nil(idea.selected_at),
          selected_at: idea.selected_at,
          selected_by_name: selector_name(idea, names),
          creator_name: creator_name(idea, names),
          notes_count: Map.get(notes, idea.id, 0),
          wikipedia?: MapSet.member?(wikipedia, idea.id)
        }
      end

    voted =
      all
      |> Enum.filter(&(&1.vote_count > 0))
      |> Enum.sort_by(&IdeaVotes.order_key(&1.idea, &1.vote_count))

    selected =
      all
      |> Enum.filter(& &1.selected?)
      |> Enum.sort_by(&{DateTime.to_unix(&1.selected_at, :microsecond), &1.id}, :desc)

    %{
      all: all,
      voted: voted,
      selected: selected,
      counts: %{"all" => length(all), "voted" => length(voted), "selected" => length(selected)}
    }
  end

  # `%{{:user | :agent, id} => name}` for every creator and selector, in two queries.
  defp people_names(ideas) do
    user_ids =
      ideas
      |> Enum.flat_map(&[&1.created_by_user_id, &1.selected_by_user_id])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    agent_ids =
      ideas |> Enum.map(& &1.created_by_agent_id) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    users =
      if user_ids == [],
        do: %{},
        else:
          from(u in Platform.Accounts.User,
            where: u.id in ^user_ids,
            select: {u.id, u.name, u.email}
          )
          |> Repo.all()
          |> Map.new(fn {id, name, email} ->
            {{:user, id}, if(is_binary(name) and name != "", do: name, else: email)}
          end)

    agents =
      agent_ids
      |> agent_names()
      |> Map.new(fn {id, name} -> {{:agent, id}, name} end)

    Map.merge(users, agents)
  end

  defp selector_name(%Idea{selected_at: nil}, _names), do: nil

  defp selector_name(%Idea{selected_by_user_id: nil}, _names), do: "a former user"

  defp selector_name(%Idea{selected_by_user_id: id}, names),
    do: Map.get(names, {:user, id}) || "a former user"

  defp creator_name(%Idea{created_by_agent_id: id}, names) when is_binary(id),
    do: Map.get(names, {:agent, id}) || "An agent"

  defp creator_name(%Idea{created_by_user_id: id}, names) when is_binary(id),
    do: Map.get(names, {:user, id}) || "Someone"

  defp creator_name(_idea, _names), do: "Someone"

  @doc """
  One idea's detail, or nil when it is not an idea of `profiles`:
  `%{idea, profile, posts, accounts, stage, has_published?, agent_id,
  agent_name, events, notes}`. `events` are the change log, oldest first,
  each `%{event, actor_name, actor_kind, platform, at}`; `notes` are the
  thread, each `%{note, author_name}`.
  """
  @spec detail([Profile.t()], term()) :: map() | nil
  @spec detail([Profile.t()], term(), Ecto.UUID.t() | nil) :: map() | nil
  def detail(profiles, idea_id, user_id \\ nil) do
    with %Idea{} = idea <- find_idea(profiles, idea_id),
         %Profile{} = profile <- Enum.find(profiles, &(&1.id == idea.profile_id)) do
      vote = IdeaVotes.summaries([idea], {:user, user_id}) |> Map.fetch!(idea.id)
      posts = Ideas.posts(idea)
      accounts = accounts(posts)
      agent_id = Ideas.drafting_agent_id(idea, posts, profile)
      events = posts |> Enum.map(& &1.id) |> PostEvents.list_for_posts() |> Map.values()
      events = events |> List.flatten() |> Enum.sort_by(&{&1.inserted_at, &1.id}, &sort_le/2)
      notes = IdeaNotes.list(idea.id)
      post_by_id = Map.new(posts, &{&1.id, &1})

      names =
        actor_names(
          Enum.map(events, &{&1.actor_kind, &1.actor_id}) ++
            Enum.map(notes, &{&1.author_kind, &1.author_id}) ++ [{"agent", agent_id}]
        )

      %{
        idea: idea,
        profile: profile,
        source: source(idea),
        wikipedia?: MapSet.member?(Social.Trends.wikipedia_idea_ids([idea]), idea.id),
        posts: posts,
        accounts: accounts,
        stage: Ideas.stage(posts),
        vote_count: vote.vote_count,
        voted: vote.voted,
        selected?: not is_nil(idea.selected_at),
        selected_at: idea.selected_at,
        selected_by_name: selector_name(idea, selector_names(idea)),
        has_published?: Enum.any?(posts, &(&1.status == "published")),
        agent_id: agent_id,
        agent_name: Map.get(names, {"agent", agent_id}),
        events:
          Enum.map(events, fn e ->
            %{
              event: e,
              actor_kind: e.actor_kind,
              actor_name: actor_name(names, e.actor_kind, e.actor_id),
              platform: platform_of(accounts, Map.get(post_by_id, e.post_id)),
              at: e.inserted_at
            }
          end),
        notes:
          Enum.map(notes, fn n ->
            %{note: n, author_name: actor_name(names, n.author_kind, n.author_id)}
          end)
      }
    end
  end

  defp selector_names(%Idea{} = idea), do: people_names([idea])

  defp sort_le({a_at, a_id}, {b_at, b_id}) do
    case DateTime.compare(a_at, b_at) do
      :lt -> true
      :gt -> false
      :eq -> a_id <= b_id
    end
  end

  # Where the idea came from, as a link: `%{kind, href}` (an in-app path
  # or the source URL) or `%{kind, tab}` (another Social tab), else nil.
  defp source(%Idea{clip_id: id}) when is_binary(id), do: %{kind: "clip", tab: "clips"}
  defp source(%Idea{task_id: id}) when is_binary(id), do: %{kind: "task", href: "/tasks/#{id}"}

  defp source(%Idea{meeting_id: id}) when is_binary(id) do
    case Platform.Meetings.get_meeting(id) do
      %{slug: slug} when is_binary(slug) -> %{kind: "meeting", href: "/meetings/#{slug}"}
      _ -> nil
    end
  end

  defp source(%Idea{message_id: id}) when is_binary(id) do
    with %{space_id: space_id} <- Platform.Chat.get_message(id),
         %{slug: slug} when is_binary(slug) <- Platform.Chat.get_space(space_id) do
      %{kind: "message", href: "/chat/#{slug}?message=#{id}"}
    else
      _ -> nil
    end
  end

  defp source(%Idea{source_url: url}) when is_binary(url), do: %{kind: "url", href: url}
  defp source(_idea), do: nil

  @doc "The idea `idea_id` when it belongs to one of `profiles`, else nil."
  @spec find_idea([Profile.t()], term()) :: Idea.t() | nil
  def find_idea(profiles, idea_id) do
    Enum.find_value(profiles, fn %Profile{} = p ->
      case Ideas.get(p.org_id, idea_id) do
        %Idea{profile_id: pid} = idea when pid == p.id -> idea
        _ -> nil
      end
    end)
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp accounts([]), do: %{}

  defp accounts(posts) do
    ids = posts |> Enum.map(& &1.account_id) |> Enum.uniq()
    from(a in Account, where: a.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
  end

  defp platform_of(_accounts, nil), do: nil

  defp platform_of(accounts, %Post{account_id: id}),
    do: (Map.get(accounts, id) || %{platform: nil}).platform

  defp agent_names(ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids == [],
      do: %{},
      else:
        from(a in Platform.Agents.Agent, where: a.id in ^ids, select: {a.id, a.name})
        |> Repo.all()
        |> Map.new()
  end

  defp actor_names(pairs) do
    agents = for {"agent", id} <- pairs, is_binary(id), do: id
    humans = for {"human", id} <- pairs, is_binary(id), do: id

    agent_map = agents |> agent_names() |> Map.new(fn {id, name} -> {{"agent", id}, name} end)

    human_map =
      if humans == [],
        do: %{},
        else:
          from(u in Platform.Accounts.User,
            where: u.id in ^Enum.uniq(humans),
            select: {u.id, u.name, u.email}
          )
          |> Repo.all()
          |> Map.new(fn {id, name, email} ->
            {{"human", id}, if(is_binary(name) and name != "", do: name, else: email)}
          end)

    Map.merge(agent_map, human_map)
  end

  defp actor_name(_names, "system", _id), do: "Burrow"

  defp actor_name(names, kind, id) do
    case Map.get(names, {kind, id}) do
      name when is_binary(name) and name != "" -> name
      _ -> if kind == "agent", do: "An agent", else: "Someone"
    end
  end
end
