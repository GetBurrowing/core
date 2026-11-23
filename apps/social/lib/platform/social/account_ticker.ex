defmodule Platform.Social.AccountTicker do
  @moduledoc "Dated per-account observations and the authorized ticker read model; unknowns never become zero."
  import Ecto.Query
  alias Platform.{Repo, Social}
  alias Platform.Social.{Account, FollowerSnapshot, FollowerSyncState, Post, Profile, Results}

  alias Platform.Social.Analytics.{
    Publication,
    PublicationCoverage,
    Publications,
    PublicationSyncState,
    SyncState
  }

  @doc "Persist a validated page for a trusted current account; the sync caller holds its profile/account locks."
  def record(%Account{} = account, %{data: data}, now) do
    profile = Repo.get!(Profile, account.profile_id)
    platform = if account.platform == "x", do: "twitter", else: account.platform

    valid? =
      Enum.all?(data, fn row ->
        row.account_id == account.provider_account_ref and
          row.profile_id == profile.provider_profile_ref and
          row.platform == platform and match?(%Date{}, row.date) and
          (is_nil(row.followers) or
             (is_integer(row.followers) and row.followers in 0..9_223_372_036_854_775_807))
      end)

    if valid? do
      entries =
        for row <- data,
            not is_nil(row.followers),
            do: %{
              id: Platform.Types.UUIDv7.generate(),
              account_id: account.id,
              provider_account_ref: account.provider_account_ref,
              date: row.date,
              followers: row.followers,
              observed_at: now
            }

      {count, _} =
        Repo.insert_all(FollowerSnapshot, entries,
          conflict_target: [:account_id, :provider_account_ref, :date],
          on_conflict: {:replace, [:followers, :observed_at]}
        )

      {:ok, count}
    else
      {:error, :identity_mismatch}
    end
  end

  @doc "Read only accounts in freshly authorized requested profiles, without aggregate audience totals."
  def rows(user, profile_ids, opts \\ []) do
    user = fresh_user(user)
    profiles = if user, do: Social.list_profiles_for_user(user), else: []
    profiles = Enum.filter(profiles, &(&1.id in profile_ids))
    accounts = Social.list_accounts_for_profiles(user, Enum.map(profiles, & &1.id))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ids = Enum.map(accounts, & &1.id)

    publication_profiles =
      for profile <- profiles,
          match?(%Platform.Accounts.User{archived_at: nil}, user),
          Social.Studio.require_social_use(user.id, profile) == :ok,
          into: %{},
          do: {profile.id, profile}

    publication_ids =
      for a <- accounts,
          a.platform == "youtube" and a.status == "connected",
          Platform.Social.Analytics.AccountScope.zernio_account?(a),
          Map.has_key?(publication_profiles, a.profile_id),
          do: a.id

    publication_states =
      Repo.all(from(s in PublicationSyncState, where: s.account_id in ^publication_ids))
      |> Enum.group_by(& &1.account_id)

    snapshots =
      Repo.all(
        from(s in FollowerSnapshot,
          where: s.account_id in ^ids and s.date <= ^DateTime.to_date(now)
        )
      )
      |> Enum.group_by(& &1.account_id)

    states =
      Repo.all(from(s in FollowerSyncState, where: s.account_id in ^ids))
      |> Map.new(&{&1.account_id, &1})

    org_ids = profiles |> Enum.map(& &1.org_id) |> Enum.uniq()

    syncs =
      Repo.all(from(s in SyncState, where: s.org_id in ^org_ids)) |> Map.new(&{&1.org_id, &1})

    versions = Results.by_idea(profiles, 7, now: now) |> Enum.flat_map(& &1.versions)
    post_ids = Enum.map(versions, & &1.id)

    synced =
      Repo.all(from(p in Post, where: p.id in ^post_ids, select: {p.id, p.metrics_synced_at}))
      |> Map.new()

    versions = Enum.group_by(versions, & &1.account_id)
    brands = Map.new(profiles, &{&1.id, &1})

    accounts
    |> Enum.map(fn account ->
      profile = Map.fetch!(brands, account.profile_id)

      points =
        Map.get(snapshots, account.id, [])
        |> Enum.filter(&(&1.provider_account_ref == account.provider_account_ref))

      state =
        case states[account.id] do
          %{provider_account_ref: ref} = state when ref == account.provider_account_ref -> state
          _ -> nil
        end

      %{
        account: account,
        profile: profile,
        followers: followers(account, points),
        follower_target: if(account.platform != "linkedin", do: account.follower_target),
        follower_state: state,
        views: views(Map.get(versions, account.id, []), synced),
        latest_video:
          if(account.id in publication_ids,
            do: latest_video(account, profile, Map.get(publication_states, account.id, []), now)
          ),
        views_failed?:
          not is_nil(syncs[profile.org_id]) and
            syncs[profile.org_id].post_refresh_error not in [nil, "pending"],
        views_deferred?:
          not is_nil(syncs[profile.org_id]) and not is_nil(syncs[profile.org_id].retry_at),
        weekly_progress: Results.weekly_progress(account, now: now)
      }
    end)
    |> Enum.sort_by(
      &{&1.profile.name, &1.account.platform, &1.account.handle || "", &1.account.id}
    )
  end

  defp latest_video(account, profile, states, now) do
    binding = %{
      org_id: profile.org_id,
      profile_id: profile.id,
      account_id: account.id,
      provider_account_ref: account.provider_account_ref,
      provider_profile_ref: profile.provider_profile_ref,
      platform: "youtube"
    }

    video = Publications.latest(binding, now: now)
    # Native identity is checked again at the presentation boundary, including
    # cache rows written by an older binary or manually repaired by an operator.
    video =
      if video && is_binary(video.native_id) &&
           Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, video.native_id),
         do: video

    states =
      Enum.filter(
        states,
        &(&1.provider_account_ref == account.provider_account_ref and
            &1.provider_profile_ref == profile.provider_profile_ref)
      )

    discovery = project_publication_state(Enum.find(states, &(&1.kind == "discovery")))
    refresh = project_publication_state(Enum.find(states, &(&1.kind == "refresh")))
    {discovery, search_incomplete?, newer_possible?} = discovery_coverage(discovery, video)

    refresh_failed? =
      not is_nil(refresh.last_error) and
        refresh.last_error not in ["incomplete_observation", "coverage_repaired"] and
        video_in_window?(video, refresh.from_date, refresh.to_date)

    %{
      video: video,
      checked_ranges: discovery.checked_ranges,
      checked_from: discovery.checked_from,
      checked_to: discovery.checked_to,
      discovery: discovery,
      refresh: refresh,
      search_incomplete: search_incomplete?,
      newer_possible: newer_possible?,
      coverage_unavailable: discovery.coverage_unavailable,
      figures_stale:
        not is_nil(video) and
          (video.source_stale or video.ambiguous_count > 0 or
             video.sync_status in ["pending", "unavailable"] or refresh_failed?),
      response_set_aside: not is_nil(video) and video.ambiguous_count > 0,
      selection_uncertain: newer_not_listed?(binding, video, now),
      history_incomplete: search_incomplete?,
      history_exhausted: discovery.history_exhausted,
      last_error: discovery.last_error || refresh.last_error,
      fetched_at: video && video.fetched_at
    }
  end

  defp project_publication_state(state) do
    defaults = %{
      checked_ranges: [],
      incomplete_ranges: [],
      coverage_repaired_at: nil,
      checked_from: nil,
      checked_to: nil,
      from_date: nil,
      to_date: nil,
      completed_at: nil,
      cursor: nil,
      scan_started_at: nil,
      last_error: nil,
      attempted_at: nil,
      history_exhausted: false
    }

    value = if state, do: Map.merge(defaults, Map.take(state, Map.keys(defaults))), else: defaults
    checked = PublicationCoverage.normalize(value.checked_ranges)
    incomplete = PublicationCoverage.normalize(value.incomplete_ranges)
    unavailable? = not is_list(checked) or not is_list(incomplete)

    value
    |> Map.put(:checked_ranges, if(not unavailable?, do: checked, else: []))
    |> Map.put(:incomplete_ranges, if(not unavailable?, do: incomplete, else: []))
    |> Map.put(:coverage_unavailable, unavailable?)
  end

  defp discovery_coverage(%{coverage_unavailable: true} = discovery, _video),
    do: {discovery, true, false}

  defp discovery_coverage(discovery, video) do
    # Per-page listed_from/listed_to are not completed scan coverage. Only the
    # durable checked intervals may establish dates checked, with gaps retained.
    ends =
      Enum.map(
        discovery.checked_ranges ++ discovery.incomplete_ranges,
        &Date.from_iso8601!(&1["to"])
      )

    ends = if discovery.to_date, do: [discovery.to_date | ends], else: ends
    frontier = if ends != [], do: Enum.max_by(ends, &Date.to_gregorian_days/1)

    first =
      cond do
        video -> DateTime.to_date(video.published_at)
        discovery.from_date -> discovery.from_date
        discovery.checked_ranges != [] -> Date.from_iso8601!(hd(discovery.checked_ranges)["from"])
        true -> nil
      end

    gaps =
      if first && frontier && Date.compare(first, frontier) != :gt,
        do: PublicationCoverage.missing(discovery.checked_ranges, first, frontier),
        else: []

    incomplete = PublicationCoverage.normalize(discovery.incomplete_ranges ++ gaps)

    incomplete? =
      discovery.checked_ranges == [] or incomplete != [] or
        (not is_nil(video) and
           not PublicationCoverage.covers?(discovery.checked_ranges, first, first))

    newer? =
      not is_nil(video) and
        Enum.any?(incomplete, fn interval ->
          Date.compare(Date.from_iso8601!(interval["to"]), DateTime.to_date(video.published_at)) ==
            :gt
        end)

    {Map.put(discovery, :incomplete_ranges, incomplete), incomplete?, newer?}
  end

  defp video_in_window?(%{published_at: %DateTime{} = published}, %Date{} = first, %Date{} = last) do
    day = DateTime.to_date(published)
    Date.compare(day, first) != :lt and Date.compare(day, last) != :gt
  end

  defp video_in_window?(_, _, _), do: false

  defp newer_not_listed?(_, nil, _), do: false

  defp newer_not_listed?(binding, video, now) do
    Repo.exists?(
      from(p in Publication,
        where: p.account_id == ^binding.account_id and p.profile_id == ^binding.profile_id,
        where:
          p.provider_account_ref == ^binding.provider_account_ref and
            p.provider_profile_ref == ^binding.provider_profile_ref,
        where:
          p.platform == "youtube" and p.not_listed and p.published_at > ^video.published_at and
            p.published_at <= ^now
      )
    )
  end

  defp fresh_user(%{id: id}) do
    if Platform.UUID.valid?(id) do
      case Platform.Accounts.get_user(id) do
        %{archived_at: nil} = user -> user
        _ -> nil
      end
    end
  end

  defp fresh_user(_), do: nil

  defp followers(%{platform: "linkedin"}, _), do: nil
  defp followers(_, []), do: %{value: nil, date: nil, change: nil, previous_date: nil}

  defp followers(_, points) do
    latest = Enum.max_by(points, &Date.to_gregorian_days(&1.date))
    previous_date = Date.add(latest.date, -7)
    previous = Enum.find(points, &(&1.date == previous_date))

    %{
      value: latest.followers,
      date: latest.date,
      change: if(previous, do: latest.followers - previous.followers),
      previous_date: previous_date
    }
  end

  defp views(versions, synced) do
    values = for version <- versions, is_number(version.metrics.views), do: version.metrics.views

    dates =
      for version <- versions,
          is_number(version.metrics.views),
          date = synced[version.id],
          not is_nil(date),
          do: date

    %{
      value: if(values != [], do: Enum.sum(values)),
      posts: length(versions),
      measured: length(values),
      synced_at: if(dates != [], do: Enum.min_by(dates, &DateTime.to_unix(&1, :microsecond)))
    }
  end
end
