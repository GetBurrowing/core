defmodule Platform.Social.Results do
  @moduledoc """
  Measured results for explicitly authorized social profiles. Callers resolve
  authorization before supplying Profile/Account structs; this module never
  discovers additional profiles. Unknown measurements stay unknown.
  """
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Idea, IdeaNotes, Ideas, Post, Profile}

  @metrics ~w(views likes comments shares saves reach)a
  @engagement ~w(likes comments shares saves)a

  @doc "Published versions grouped by idea within an elapsed UTC day window."
  def by_idea(profiles, period, opts \\ []) when period in [7, 30, 90] do
    ids = Enum.map(profiles, fn %Profile{id: id} -> id end)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    from(p in Post,
      join: a in assoc(p, :account),
      where: a.profile_id in ^ids,
      where: p.status == "published" and p.published_at >= ^DateTime.add(now, -period, :day),
      where: p.published_at <= ^now,
      preload: [:idea, account: :profile]
    )
    |> Repo.all()
    |> Enum.group_by(fn p -> if p.idea_id, do: "idea:#{p.idea_id}", else: "post:#{p.id}" end)
    |> Enum.map(fn {key, posts} ->
      versions =
        posts
        |> Enum.sort_by(&{DateTime.to_unix(&1.published_at, :microsecond), &1.id})
        |> Enum.map(&version/1)

      first = hd(posts)
      profile = first.account.profile
      metrics = Map.new(@metrics, &{&1, sum_known(Enum.map(versions, fn v -> v.metrics[&1] end))})

      %{
        key: key,
        idea_id: first.idea_id,
        profile_id: profile.id,
        brand: profile.name,
        title: if(first.idea, do: first.idea.title, else: first.body),
        versions: versions,
        metrics: metrics,
        engagement: sum_known(Enum.map(versions, & &1.engagement))
      }
    end)
    |> Enum.sort_by(&{-(Map.get(&1, :engagement) || -1), &1.key})
  end

  @doc """
  All-history measured idea cohort, ranked before eligibility filtering. Take
  ceil(20% of measured groups), then exclude archived sources, sources whose
  latest publication is less than 30 elapsed days old, and parents with a child.
  Ineligible leaders are not replaced. Standalone posts never enter the cohort.
  """
  def recycle_candidates(profiles, opts \\ []) do
    ids = Enum.map(profiles, fn %Profile{id: id} -> id end)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    groups =
      from(p in Post,
        join: i in assoc(p, :idea),
        where: i.profile_id in ^ids and p.status == "published" and p.published_at <= ^now,
        preload: [:idea, account: :profile]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.idea_id)
      |> Enum.flat_map(fn {id, posts} ->
        case sum_known(Enum.map(posts, &engagement/1)) do
          nil ->
            []

          total ->
            latest =
              Enum.max_by(posts, &DateTime.to_unix(&1.published_at, :microsecond)).published_at

            [
              %{
                idea_id: id,
                title: hd(posts).idea.title,
                profile_id: hd(posts).idea.profile_id,
                engagement: total,
                published_at: latest,
                idea: hd(posts).idea
              }
            ]
        end
      end)
      |> Enum.sort_by(&{-&1.engagement, &1.idea_id})

    top = Enum.take(groups, div(length(groups) + 4, 5))
    top_ids = Enum.map(top, & &1.idea_id)

    parents =
      Repo.all(
        from(i in Idea,
          where: i.recycled_from_idea_id in ^top_ids,
          select: i.recycled_from_idea_id
        )
      )
      |> MapSet.new()

    cutoff = DateTime.add(now, -30, :day)

    Enum.filter(top, fn row ->
      is_nil(row.idea.archived_at) and DateTime.compare(row.published_at, cutoff) != :gt and
        not MapSet.member?(parents, row.idea_id)
    end)
    |> Enum.map(&Map.delete(&1, :idea))
  end

  @doc """
  Creates a fresh Inbox idea and reference notes; no posts are copied.
  `profiles: authorized_profiles` selects the same cohort shown by the caller's
  brand filter. Every supplied Profile is freshly re-read through scope; an
  inaccessible/malformed cohort or a source outside it is not_found. Without
  options the cohort is all profiles visible through scope (All brands).
  """
  def recycle(scope, idea_id, user_id, opts \\ []) do
    with %Idea{} = source <- Ideas.get(scope, idea_id) || {:error, :not_found} do
      Repo.transaction(fn ->
        # Serialize requests for the same parent, then re-read authorization and eligibility.
        unless Repo.one(from(i in Idea, where: i.id == ^source.id, lock: "FOR UPDATE")),
          do: Repo.rollback(:not_found)

        with %Idea{} = source <- Ideas.get(scope, source.id) || {:error, :not_found},
             %Profile{} = profile <-
               Social.get_profile(scope, source.profile_id) || {:error, :not_found},
             :ok <- Social.approver_check(profile.org_id, profile, user_id),
             {:ok, profiles} <- recycle_cohort(scope, profile, opts),
             true <-
               Enum.any?(recycle_candidates(profiles), &(&1.idea_id == source.id)) ||
                 {:error, :not_eligible},
             {:ok, child} <-
               Ideas.create(
                 scope,
                 profile.id,
                 %{title: source.title, brief: source.brief, source_kind: "human"},
                 {:user, user_id},
                 broadcast: false
               ),
             {:ok, child} <-
               child
               |> Ecto.Changeset.change(recycled_from_idea_id: source.id)
               |> Ecto.Changeset.unique_constraint(:recycled_from_idea_id)
               |> Ecto.Changeset.foreign_key_constraint(:recycled_from_idea_id)
               |> Repo.update() do
          source
          |> Ideas.posts()
          |> Enum.filter(&(&1.status == "published"))
          |> Repo.preload(:account)
          |> Enum.each(fn post ->
            case IdeaNotes.add(scope, child.id, {:human, user_id}, reference_note(post),
                   broadcast: false
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

          child
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, child} ->
          Ideas.broadcast_changed(child.profile_id)
          {:ok, child}

        error ->
          error
      end
    end
  end

  defp recycle_cohort(scope, source_profile, opts) do
    profiles = Keyword.get_lazy(opts, :profiles, fn -> Social.list_profiles(scope) end)

    if is_list(profiles) do
      fresh =
        Enum.map(profiles, fn
          %Profile{id: id} -> Social.get_profile(scope, id)
          _ -> nil
        end)

      if Enum.all?(fresh, &match?(%Profile{}, &1)) and
           Enum.any?(fresh, &(&1.id == source_profile.id)),
         do: {:ok, Enum.uniq_by(fresh, & &1.id)},
         else: {:error, :not_found}
    else
      {:error, :not_found}
    end
  end

  defp reference_note(post) do
    header =
      "Original published version (reference only)\nPlatform: #{post.account.platform}\nPublished: #{DateTime.to_iso8601(post.published_at)}\nPost: #{post.id}\nLive URL: #{post.external_url || "unavailable"}\n\n"

    # Bound the whole note, including metadata, to IdeaNotes' 4000-character limit.
    String.slice(header <> (post.body || ""), 0, 4000)
  end

  @doc "Account-only 3-hour buckets, or nil until ten usable measured posts."
  def best_times(%Account{} = account, opts \\ []) do
    sample = time_sample(account, opts)

    if sample.count >= 10 do
      buckets =
        sample.posts
        |> Enum.group_by(fn p ->
          local = DateTime.shift_zone!(p.published_at, sample.timezone)
          {Date.day_of_week(DateTime.to_date(local)), div(local.hour, 3) * 3}
        end)
        |> Enum.map(fn {{weekday, hour}, posts} ->
          total = Enum.sum(Enum.map(posts, &engagement/1))

          %{
            weekday: weekday,
            hour: hour,
            engagement: total,
            post_count: length(posts),
            mean_engagement: total / length(posts)
          }
        end)
        |> Enum.sort_by(&{&1.weekday, &1.hour})

      %{account_id: account.id, timezone: sample.timezone, count: sample.count, buckets: buckets}
    end
  end

  @doc "The exact usable sample count used by best_times/2, including below ten."
  def best_times_count(%Account{} = account, opts \\ []), do: time_sample(account, opts).count

  @doc "Published progress for the profile-local Monday week; nil without a goal."
  def weekly_progress(%Account{weekly_goal: nil}, _opts), do: nil

  def weekly_progress(%Account{} = account, opts) do
    profile = Repo.preload(account, :profile).profile
    now = Keyword.get(opts, :now, DateTime.utc_now())
    today = now |> DateTime.shift_zone!(profile.timezone) |> DateTime.to_date()
    monday = Date.add(today, 1 - Date.day_of_week(today))
    start = local_midnight(monday, profile.timezone)
    finish = local_midnight(Date.add(monday, 7), profile.timezone)

    count =
      Repo.aggregate(
        from(p in Post,
          where:
            p.account_id == ^account.id and
              p.status == "published" and p.published_at >= ^start and p.published_at < ^finish
        ),
        :count
      )

    %{
      account_id: account.id,
      published: count,
      goal: account.weekly_goal,
      week_start: start,
      week_end: finish
    }
  end

  def weekly_progress(account), do: weekly_progress(account, [])

  defp time_sample(account, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    weeks = Keyword.get(opts, :weeks, 8)
    profile = Repo.preload(account, :profile).profile

    posts =
      Repo.all(
        from(p in Post,
          where:
            p.account_id == ^account.id and
              p.status == "published" and p.published_at >= ^DateTime.add(now, -weeks * 7, :day) and
              p.published_at <= ^now and not is_nil(p.metrics_synced_at)
        )
      )
      |> Enum.filter(&(not is_nil(engagement(&1))))

    %{posts: posts, count: length(posts), timezone: profile.timezone}
  end

  defp version(post) do
    metrics = Map.new(@metrics, &{&1, measured(post, &1)})
    engagement = engagement(post)

    %{
      id: post.id,
      account_id: post.account_id,
      platform: post.account.platform,
      account: post.account.handle,
      published_at: post.published_at,
      external_url: post.external_url,
      metrics: metrics,
      engagement: engagement,
      engagement_rate:
        if(
          is_number(metrics.reach) and metrics.reach > 0 and
            is_number(engagement),
          do: engagement / metrics.reach,
          else: nil
        ),
      data_state:
        if(Enum.any?(metrics, fn {_, v} -> is_number(v) end), do: :measured, else: :no_data)
    }
  end

  defp engagement(post), do: sum_known(Enum.map(@engagement, &measured(post, &1)))
  defp measured(%Post{metrics_synced_at: nil}, _key), do: nil

  defp measured(post, key) do
    value = Map.get(post.metrics || %{}, Atom.to_string(key))
    if is_number(value) and value >= 0, do: value, else: nil
  end

  defp sum_known(values) do
    case Enum.filter(values, &is_number/1) do
      [] -> nil
      known -> Enum.sum(known)
    end
  end

  defp local_midnight(date, timezone) do
    case DateTime.new(date, ~T[00:00:00], timezone) do
      {:ok, value} -> DateTime.shift_zone!(value, "Etc/UTC")
      {:ambiguous, first, _} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
    end
  end
end
