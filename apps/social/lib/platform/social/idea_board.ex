defmodule Platform.Social.IdeaBoard do
  @moduledoc """
  What the Ideas tab reads (Social authoring 7/11, task 01a16c50-ea67): the
  board's cards and one idea's detail. Read-only.

  Profiles come from the caller, who takes them from
  `Platform.Social.list_profiles_for_user/1` (the RBAC swap point); every
  idea is read through its profile's org scope (`Platform.Social.Ideas`).

  ## Lanes are derived

  An idea's lane is `Platform.Social.Ideas.stage/1` of its posts, never
  stored and never dragged: Inbox, Drafting, In review, Scheduled, Live.
  An idea whose every post failed sits in Drafting (it needs another
  draft); any failed post puts a muted Failed marker on the card.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Idea, IdeaNotes, Ideas, Post, PostEvents, Profile}

  @lanes ~w(inbox drafting in_review scheduled live)

  @doc "The five lanes, in board order."
  @spec lanes() :: [String.t()]
  def lanes, do: @lanes

  @doc "The lane of a derived stage (`failed` sits in Drafting)."
  @spec lane(String.t()) :: String.t()
  def lane("failed"), do: "drafting"
  def lane(stage) when stage in @lanes, do: stage
  def lane(_), do: "drafting"

  @doc """
  The board's cards for `profiles` (each read through its own org), newest
  idea first, as seen by `user_id` (the "N waiting on you" count).
  """
  @spec cards([Profile.t()], Ecto.UUID.t() | nil, DateTime.t()) :: [map()]
  def cards(profiles, user_id, now \\ DateTime.utc_now()) do
    ideas =
      Enum.flat_map(profiles, fn %Profile{} = p -> Ideas.list(p.org_id, p.id) end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    posts = ideas |> Enum.map(& &1.id) |> Ideas.posts_by_idea()
    accounts = accounts(posts |> Map.values() |> List.flatten())
    by_id = Map.new(profiles, &{&1.id, &1})
    agent_ids = agent_ids_by_idea(ideas, posts, by_id)
    names = agent_names(Map.values(agent_ids))
    approver? = approver_fun(user_id)

    for idea <- ideas do
      idea_posts = Map.get(posts, idea.id, [])
      profile = Map.get(by_id, idea.profile_id)
      stage = Ideas.stage(idea_posts)

      %{
        id: idea.id,
        idea: idea,
        profile: profile,
        stage: stage,
        lane: lane(stage),
        failed?: Enum.any?(idea_posts, &(&1.status == "failed")),
        platforms: Enum.map(idea_posts, &platform_of(accounts, &1)),
        agent_name: Map.get(names, Map.get(agent_ids, idea.id)),
        next_at: next_at(idea_posts, now),
        waiting: waiting(idea_posts, accounts, profile, approver?)
      }
    end
  end

  @doc """
  One idea's detail, or nil when it is not an idea of `profiles`:
  `%{idea, profile, posts, accounts, stage, has_published?, agent_id,
  agent_name, events, notes}`. `events` are the change log, oldest first,
  each `%{event, actor_name, actor_kind, platform, at}`; `notes` are the
  thread, each `%{note, author_name}`.
  """
  @spec detail([Profile.t()], term()) :: map() | nil
  def detail(profiles, idea_id) do
    with %Idea{} = idea <- find_idea(profiles, idea_id),
         %Profile{} = profile <- Enum.find(profiles, &(&1.id == idea.profile_id)) do
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
        posts: posts,
        accounts: accounts,
        stage: Ideas.stage(posts),
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

  # The drafting agent per idea: the posts' first drafter (one query for
  # every post's `created` event), else the idea's creator agent, else the
  # profile's drafting agent.
  defp agent_ids_by_idea(ideas, posts, profiles) do
    post_ids = posts |> Map.values() |> List.flatten() |> Enum.map(& &1.id)

    created =
      if post_ids == [] do
        %{}
      else
        from(e in Platform.Social.PostEvent,
          where:
            e.post_id in ^post_ids and e.action == "created" and e.actor_kind == "agent" and
              not is_nil(e.actor_id),
          order_by: [asc: e.inserted_at, asc: e.id],
          select: {e.post_id, e.actor_id}
        )
        |> Repo.all()
        |> Enum.reduce(%{}, fn {post_id, agent_id}, acc -> Map.put_new(acc, post_id, agent_id) end)
      end

    Map.new(ideas, fn idea ->
      from_posts =
        posts
        |> Map.get(idea.id, [])
        |> Enum.find_value(&(&1.generated_by_agent_id || Map.get(created, &1.id)))

      profile = Map.get(profiles, idea.profile_id)

      {idea.id, from_posts || idea.created_by_agent_id || (profile && profile.drafting_agent_id)}
    end)
  end

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

  # The soonest time still ahead among the idea's open posts, else nil.
  defp next_at(posts, now) do
    posts
    |> Enum.filter(&(&1.status in ~w(draft needs_approval approved scheduled)))
    |> Enum.map(& &1.scheduled_at)
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.filter(&(DateTime.compare(&1, now) != :lt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp waiting(_posts, _accounts, nil, _approver?), do: 0

  defp waiting(posts, accounts, profile, approver?) do
    Enum.count(posts, fn post ->
      post.status == "needs_approval" and
        match?(%Account{}, Map.get(accounts, post.account_id)) and
        approver?.(profile, Map.get(accounts, post.account_id))
    end)
  end

  defp approver_fun(nil), do: fn _profile, _account -> false end

  defp approver_fun(user_id) do
    fn profile, account ->
      Social.post_approver_check(profile.org_id, profile, account, user_id) == :ok
    end
  end
end
