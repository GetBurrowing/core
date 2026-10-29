defmodule Platform.Social.ClipLibrary do
  @moduledoc """
  What happened to an approved clip, per platform (Clip Studio 2/9, task
  01a16662). Read-only.

  ## Never rolled up

  `platform_status/2` describes ONE post, so a clip published on Instagram
  and failed on TikTok reports exactly that, entry by entry. `clip_state/2`
  is a separate one-word label for filtering (the studio prototype's
  `clipState`); it never replaces the entries.

  ## States

    * `queued`: waiting for the undo window (`publish_after` set), not sent,
      not refused. `draft` and `needs_approval` also read as queued.
    * `uploading`: claimed and in flight (approved, `publish_after` nil, not
      sent, not refused), or accepted by the vendor and processing
      (`scheduled` with no `scheduled_at`, or one already passed). The
      adapter reports no upload progress, so `pct` is always nil; it is
      never invented.
    * `scheduled`: `scheduled` with `scheduled_at` in the future (`at`).
    * `published`: `at` = `published_at`, `url` = `external_url`; `views`
      stays nil until analytics exist.
    * `failed`: status `failed`, or approved with a `refused_reason` (the
      refusal's sentence is the `error`); `attempts` = `publish_attempts`.

  Every failed entry carries `reconnect: %{account_id, platform}` for its
  OWN account, which a UI hands to the existing `connect_account` flow.

  ## The library (`list/3`)

  Every clip of the org's visible profiles that reached review (its
  `review_status` is set: in review, rejected or approved), newest
  `rendered_at` first. Candidate, rendering and render-failed clips are not
  listed. Each item is `%{clip, state, platforms}`: `state` is
  `clip_state/2`, and `platforms` holds one `platform_status/2` entry per
  post, never rolled up.

  Filters (string keys; any other key, or a value outside its set, is
  `{:error, :invalid_filter}`):

    * `"show"`: a profile id. An unknown or other-org id simply matches
      nothing.
    * `"episode"`: the clip's `episode_code`.
    * `"date"`: `today` (the current UTC date), `this_week` (1 to 6 days
      before) or `older` (7 days or more), on `rendered_at` in UTC.
    * `"platform"`: a post on an account of that platform, or a pending
      clip with it in `clip.platforms`.
    * `"status"`: one of #{inspect(["In review", "Rejected", "Failed", "Scheduled", "Publishing", "Published"])}, matched against the
      clip's `clip_state/2` label.
    * `"q"`: case-insensitive match on title and caption, either of which
      may be nil (privacy mode = local). There is no transcript excerpt
      column on `social_clips`, so q does not search the transcript.

  `counts` has, for each of show, episode, date, platform and status, a map
  of option to count over the list with every OTHER active filter (and q)
  applied, as the prototype's `drawMenu` does: each count equals the
  `total` that selecting that option would give.

  ## Phase-2 analytics hook (spec only; NOT built, `views` stays nil)

  From https://zernio.com/openapi.json, read 2026-10-22:

    * `GET /v1/analytics?postId=<Zernio post id or external id>`: one
      post's status, publishedAt and analytics {impressions, reach, likes,
      comments, shares, saves, clicks, views, follows, igReelsAvgWatchTime
      ms, igReelsVideoViewTotalTime ms, reelsSkipRate, completionRate,
      profileViews}, plus platformAnalytics[] {platform, platformPostId,
      accountId, platformPostUrl, syncStatus, analytics{..., engagementRate,
      lastUpdated}}. May answer 202 (sync pending) or 424.
    * `GET /v1/analytics/delta?cursor=`: the recommended sync, a cursor feed
      of changed snapshots {postId, accountId, profileId, platform,
      platformPostId, publishedAt, syncedAt, isDeleted, metrics{impressions,
      reach, likes, comments, shares, saves, sends, clicks, views, follows,
      igReelsAvgWatchTime, igReelsVideoViewTotalTime, reposts,
      reelsSkipRate, completionRate, profileViews, websiteClicks,
      impressionSources, audienceTypes, audienceCountries}}.
    * `GET /v1/analytics/post-timeline?postId=`: daily rows per platform
      (adds replays and retentionCurve); needs the Analytics add-on.
    * `GET /v1/analytics/youtube/video-retention?videoId=<platformPostId>&accountId=`:
      the retention curve and durationSeconds.
    * Join: `social_posts.external_id` = Zernio postId, and
      `social_posts.platform_post_id` = platformPostId. The asset is
      `social_posts.clip_id`.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Clip, Post, Profile}

  @filter_keys ~w(show episode date platform status q)
  @menu_keys ~w(show episode date platform status)
  @dates ~w(today this_week older)
  @clip_states ["In review", "Rejected", "Failed", "Scheduled", "Publishing", "Published"]

  @type state :: :queued | :uploading | :scheduled | :published | :failed

  @type entry :: %{
          post_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          platform: String.t() | nil,
          state: state(),
          pct: nil,
          at: DateTime.t() | nil,
          url: String.t() | nil,
          views: nil,
          error: String.t() | nil,
          attempts: non_neg_integer(),
          reconnect: %{account_id: Ecto.UUID.t(), platform: String.t() | nil} | nil
        }

  @doc """
  One post's per-platform status as of `now`. The account's platform is
  read from a preloaded `:account` when present, else from the database.
  """
  @spec platform_status(Post.t(), DateTime.t()) :: entry()
  def platform_status(%Post{} = post, now \\ DateTime.utc_now()) do
    platform = platform(post)
    {state, at, url, error} = state(post, now)

    %{
      post_id: post.id,
      account_id: post.account_id,
      platform: platform,
      state: state,
      pct: nil,
      at: at,
      url: url,
      views: nil,
      error: error,
      attempts: post.publish_attempts || 0,
      reconnect: if(state == :failed, do: %{account_id: post.account_id, platform: platform})
    }
  end

  defp state(%Post{status: status} = post, _now) when status in ~w(draft needs_approval),
    do: {:queued, post.publish_after, nil, nil}

  defp state(%Post{status: "approved", refused_reason: reason} = post, _now)
       when is_binary(reason),
       do: {:failed, post.refused_at, nil, post.error}

  defp state(%Post{status: "approved", external_id: nil, publish_after: %DateTime{} = at}, _now),
    do: {:queued, at, nil, nil}

  defp state(%Post{status: "approved"}, _now), do: {:uploading, nil, nil, nil}

  defp state(%Post{status: "scheduled", scheduled_at: %DateTime{} = at}, now) do
    if DateTime.compare(at, now) == :gt,
      do: {:scheduled, at, nil, nil},
      else: {:uploading, nil, nil, nil}
  end

  defp state(%Post{status: "scheduled"}, _now), do: {:uploading, nil, nil, nil}

  defp state(%Post{status: "published"} = post, _now),
    do: {:published, post.published_at, post.external_url, nil}

  defp state(%Post{status: "failed"} = post, _now),
    do: {:failed, post.updated_at, nil, post.error}

  defp platform(%Post{account: %Account{platform: platform}}), do: platform

  defp platform(%Post{account_id: account_id}),
    do: Repo.one(from(a in Account, where: a.id == ^account_id, select: a.platform))

  @doc """
  The clip's one-word library state, in the prototype's order:

    * review pending (or never reviewed): `"In review"`
    * rejected: `"Rejected"`
    * approved: `"Failed"` if any post failed, else `"Scheduled"` if any is
      scheduled, else `"Publishing"` if any is queued or uploading, else
      `"Published"`.

  `entries` are `platform_status/2` entries or posts; omitted, the clip's
  posts are read.
  """
  @spec clip_state(Clip.t(), [entry() | Post.t()] | nil) :: String.t()
  def clip_state(clip, entries \\ nil)

  def clip_state(%Clip{review_status: "rejected"}, _entries), do: "Rejected"

  def clip_state(%Clip{review_status: "approved"} = clip, entries) do
    states = clip |> entries(entries) |> Enum.map(& &1.state)

    cond do
      :failed in states -> "Failed"
      :scheduled in states -> "Scheduled"
      Enum.any?(states, &(&1 in [:queued, :uploading])) -> "Publishing"
      true -> "Published"
    end
  end

  def clip_state(%Clip{}, _entries), do: "In review"

  @doc "The `platform_status/2` entry of every post of `clip`, oldest first."
  @spec clip_status(Clip.t(), DateTime.t()) :: [entry()]
  def clip_status(%Clip{id: clip_id}, now \\ DateTime.utc_now()) do
    from(p in Post,
      where: p.clip_id == ^clip_id,
      order_by: [asc: p.inserted_at, asc: p.id],
      preload: [:account]
    )
    |> Repo.all()
    |> Enum.map(&platform_status(&1, now))
  end

  defp entries(clip, nil), do: clip_status(clip)

  defp entries(_clip, entries),
    do:
      Enum.map(entries, fn
        %Post{} = post -> platform_status(post)
        entry -> entry
      end)

  # ── Library ──────────────────────────────────────────────────────────

  @type item :: %{clip: Clip.t(), state: String.t(), platforms: [entry()]}

  @doc """
  The library: `%{items: [item], total, counts}` for `org_id` (or a scope
  `Platform.Social.visible_orgs/1` accepts), or `{:error, :invalid_filter}`.
  See the moduledoc for the filters and counts. `opts` takes `:now`.
  """
  @spec list(term(), map(), keyword()) ::
          %{items: [item()], total: non_neg_integer(), counts: map()}
          | {:error, :invalid_filter}
  def list(org_id, filters \\ %{}, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, filters} <- validate(filters) do
      rows = org_id |> base_query(filters["q"]) |> Repo.all() |> items(now)
      active = Map.delete(filters, "q")
      items = Enum.filter(rows, &matches?(&1, active, now))

      %{items: items, total: length(items), counts: counts(rows, active, now)}
    end
  end

  defp base_query(scope, q) do
    query =
      from(c in Clip,
        join: p in Profile,
        on: p.id == c.profile_id,
        where: not is_nil(c.review_status) and is_nil(c.removed_at),
        order_by: [desc_nulls_last: c.rendered_at, desc: c.id]
      )

    query =
      case Social.visible_orgs(scope) do
        :all -> query
        org_ids -> from([c, p] in query, where: p.org_id in ^org_ids)
      end

    case q do
      nil ->
        query

      q ->
        pattern = "%" <> escape_like(q) <> "%"
        from(c in query, where: ilike(c.title, ^pattern) or ilike(c.caption, ^pattern))
    end
  end

  defp escape_like(q), do: String.replace(q, ["\\", "%", "_"], &("\\" <> &1))

  defp items(clips, now) do
    ids = Enum.map(clips, & &1.id)

    posts =
      from(p in Post,
        where: p.clip_id in ^ids,
        order_by: [asc: p.inserted_at, asc: p.id],
        preload: [:account]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.clip_id)

    Enum.map(clips, fn clip ->
      entries = posts |> Map.get(clip.id, []) |> Enum.map(&platform_status(&1, now))
      %{clip: clip, state: clip_state(clip, entries), platforms: entries}
    end)
  end

  defp matches?(item, filters, now),
    do: Enum.all?(filters, fn {key, value} -> match?(item, key, value, now) end)

  defp match?(%{clip: clip}, "show", value, _now), do: clip.profile_id == value
  defp match?(%{clip: clip}, "episode", value, _now), do: clip.episode_code == value
  defp match?(%{clip: clip}, "date", value, now), do: date_bucket(clip.rendered_at, now) == value
  defp match?(%{state: state}, "status", value, _now), do: state == value

  defp match?(%{clip: clip, platforms: entries}, "platform", value, _now) do
    Enum.any?(entries, &(&1.platform == value)) or
      (clip.review_status == "pending" and value in (clip.platforms || []))
  end

  defp date_bucket(nil, _now), do: nil

  defp date_bucket(%DateTime{} = at, now) do
    case Date.diff(DateTime.to_date(now), DateTime.to_date(at)) do
      0 -> "today"
      days when days in 1..6 -> "this_week"
      days when days >= 7 -> "older"
      _future -> nil
    end
  end

  defp counts(rows, active, now) do
    Map.new(@menu_keys, fn key ->
      others = Map.delete(active, key)
      base = Enum.filter(rows, &matches?(&1, others, now))

      {key,
       Map.new(options(key, rows), fn option ->
         {option, Enum.count(base, &match?(&1, key, option, now))}
       end)}
    end)
  end

  defp options("show", rows), do: rows |> Enum.map(& &1.clip.profile_id) |> Enum.uniq()

  defp options("episode", rows),
    do: rows |> Enum.map(& &1.clip.episode_code) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp options("date", _rows), do: @dates
  defp options("platform", _rows), do: Account.platforms()
  defp options("status", _rows), do: @clip_states

  defp validate(filters) when is_map(filters) do
    filters
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      cond do
        key not in @filter_keys -> {:halt, {:error, :invalid_filter}}
        value in [nil, ""] -> {:cont, {:ok, acc}}
        true -> validate_value(key, value, acc)
      end
    end)
  end

  defp validate(_filters), do: {:error, :invalid_filter}

  defp validate_value("show", value, acc) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:cont, {:ok, Map.put(acc, "show", id)}}
      :error -> {:halt, {:error, :invalid_filter}}
    end
  end

  defp validate_value(key, value, acc) when is_binary(value) do
    if valid_value?(key, value),
      do: {:cont, {:ok, Map.put(acc, key, value)}},
      else: {:halt, {:error, :invalid_filter}}
  end

  defp validate_value(_key, _value, _acc), do: {:halt, {:error, :invalid_filter}}

  defp valid_value?("date", value), do: value in @dates
  defp valid_value?("platform", value), do: value in Account.platforms()
  defp valid_value?("status", value), do: value in @clip_states
  defp valid_value?(key, _value) when key in ~w(episode q), do: true
end
