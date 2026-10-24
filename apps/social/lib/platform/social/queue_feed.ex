defmodule Platform.Social.QueueFeed do
  @moduledoc """
  What the Queue ("Needs you", Social authoring 5/11, task 01a16c50) reads.
  Read only: every decision still goes through `Platform.Social.Approvals`
  and `Platform.Social.Ideas`.

  `scope` is the Queue's: `{:profile, profile}` (one brand) or `:all`
  (every profile `user` may see, `Platform.Social.list_posts_for_profiles/3`).
  Every post is read through `Platform.Social.list_posts/2`, so nothing
  outside the user's orgs is ever returned.

  ## Groups

  A group is one idea and its posts (one post per account), or one post with
  no idea (its own group, keyed by the post id):

      %{key: idea_id | post_id, idea: Idea.t() | nil, posts: [Post.t()],
        first_at: DateTime.t() | nil}

  `needs_you/2` groups the `needs_approval` posts and sorts the groups by
  their earliest suggested time (`scheduled_at`), groups with no time last,
  then by the oldest post. Inside a group the posts keep their drafting
  order (oldest first).
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, ClipReviewFeed, Idea, Post, Profile}

  @type scope :: {:profile, Profile.t() | nil} | :all
  @type group :: %{
          key: Ecto.UUID.t(),
          idea: Idea.t() | nil,
          posts: [Post.t()],
          first_at: DateTime.t() | nil
        }

  @scheduled_days 7
  @published_hours 24
  @failed_days 7

  @doc "The `needs_approval` posts in `scope`, grouped by idea and sorted (see the moduledoc)."
  @spec needs_you(term(), scope()) :: [group()]
  def needs_you(user, scope), do: user |> posts(scope, status: "needs_approval") |> group()

  @doc """
  Approved or scheduled posts going out in the next #{@scheduled_days} days
  (`scheduled_at` from `now`), not refused, grouped by idea, soonest first.
  """
  @spec scheduled(term(), scope(), DateTime.t()) :: [group()]
  def scheduled(user, scope, now \\ DateTime.utc_now()) do
    to = DateTime.add(now, @scheduled_days * 86_400, :second)

    user
    |> posts(scope, statuses: ~w(approved scheduled))
    |> Enum.filter(fn p ->
      is_nil(p.refused_reason) and match?(%DateTime{}, p.scheduled_at) and
        DateTime.compare(p.scheduled_at, now) != :lt and
        DateTime.compare(p.scheduled_at, to) == :lt
    end)
    |> group()
  end

  @doc """
  Approved posts whose publish was refused before the vendor (any age), then
  posts the vendor failed in the last #{@failed_days} days. Newest first.
  """
  @spec failed(term(), scope(), DateTime.t()) :: [Post.t()]
  def failed(user, scope, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@failed_days * 86_400, :second)
    refused = posts(user, scope, refused: true)
    failed = posts(user, scope, status: "failed", updated_from: since)

    (refused ++ failed)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&(&1.refused_at || &1.updated_at), {:desc, DateTime})
  end

  @doc "Posts published in the last #{@published_hours} hours, newest first."
  @spec published(term(), scope(), DateTime.t()) :: [Post.t()]
  def published(user, scope, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@published_hours * 3600, :second)

    user
    |> posts(scope, status: "published", updated_from: since)
    |> Enum.filter(&(DateTime.compare(published_at(&1), since) != :lt))
    |> Enum.sort_by(&published_at/1, {:desc, DateTime})
  end

  @doc "When a published post went out: `published_at`, else its last write."
  @spec published_at(Post.t()) :: DateTime.t()
  def published_at(%Post{published_at: %DateTime{} = at}), do: at
  def published_at(%Post{updated_at: at}), do: at

  @doc """
  Rendered clips waiting for review in `scope` (`ClipReviewFeed.pending_count/2`,
  summed over every visible profile for All brands).
  """
  @spec clips_waiting(term(), scope()) :: non_neg_integer()
  def clips_waiting(_user, {:profile, %Profile{} = p}),
    do: ClipReviewFeed.pending_count(p.org_id, p.id)

  def clips_waiting(_user, {:profile, nil}), do: 0

  def clips_waiting(user, :all) do
    user
    |> Social.list_profiles_for_user()
    |> Enum.map(&ClipReviewFeed.pending_count(&1.org_id, &1.id))
    |> Enum.sum()
  end

  @doc "Groups `posts` by idea (see the moduledoc), sorted by earliest time."
  @spec group([Post.t()]) :: [group()]
  def group(posts) do
    ideas = ideas_by_id(posts)

    posts
    |> Enum.group_by(&(&1.idea_id || &1.id))
    |> Enum.map(fn {key, members} ->
      members = Enum.sort_by(members, &{&1.inserted_at, &1.id}, &sort_key_le/2)

      %{
        key: key,
        idea: Map.get(ideas, key),
        posts: members,
        first_at: members |> Enum.map(& &1.scheduled_at) |> Enum.reject(&is_nil/1) |> min_at()
      }
    end)
    |> Enum.sort_by(&group_order/1, &order_le/2)
  end

  @doc "The accounts of `posts`, by id (archived ones included)."
  @spec accounts([Post.t()]) :: %{Ecto.UUID.t() => Account.t()}
  def accounts([]), do: %{}

  def accounts(posts) do
    ids = posts |> Enum.map(& &1.account_id) |> Enum.uniq()
    from(a in Account, where: a.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
  end

  @doc "The profiles of `accounts` (a list or the `accounts/1` map), by profile id."
  @spec profiles(map() | [Account.t()]) :: %{Ecto.UUID.t() => Profile.t()}
  def profiles(accounts) when is_map(accounts), do: accounts |> Map.values() |> profiles()
  def profiles([]), do: %{}

  def profiles(accounts) do
    ids = accounts |> Enum.map(& &1.profile_id) |> Enum.uniq()
    from(p in Profile, where: p.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp posts(user, :all, filters), do: Social.list_posts_for_profiles(user, :all, filters)
  defp posts(_user, {:profile, nil}, _filters), do: []

  defp posts(_user, {:profile, %Profile{} = profile}, filters) do
    profile.org_id
    |> Social.list_posts(Keyword.put(filters, :profile_id, profile.id))
    |> Enum.sort_by(&{&1.inserted_at, &1.id}, &sort_key_le/2)
  end

  defp ideas_by_id(posts) do
    case posts |> Enum.map(& &1.idea_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> %{}
      ids -> from(i in Idea, where: i.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
    end
  end

  defp min_at([]), do: nil
  defp min_at(times), do: Enum.min(times, DateTime)

  # Timed groups first (soonest first), then untimed; ties by oldest post.
  defp group_order(%{first_at: at, posts: [first | _]}),
    do: {if(at, do: 0, else: 1), at, first.inserted_at, first.id}

  defp order_le({ta, a, ia, ida}, {tb, b, ib, idb}) do
    cond do
      ta != tb -> ta < tb
      a && b && DateTime.compare(a, b) != :eq -> DateTime.compare(a, b) == :lt
      DateTime.compare(ia, ib) != :eq -> DateTime.compare(ia, ib) == :lt
      true -> ida <= idb
    end
  end

  defp sort_key_le({a, ida}, {b, idb}) do
    case DateTime.compare(a, b) do
      :lt -> true
      :gt -> false
      :eq -> ida <= idb
    end
  end
end
