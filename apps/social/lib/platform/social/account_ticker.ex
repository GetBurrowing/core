defmodule Platform.Social.AccountTicker do
  @moduledoc "Dated per-account observations and the authorized ticker read model; unknowns never become zero."
  import Ecto.Query
  alias Platform.{Repo, Social}
  alias Platform.Social.{Account, FollowerSnapshot, FollowerSyncState, Post, Profile, Results}
  alias Platform.Social.Analytics.SyncState

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
