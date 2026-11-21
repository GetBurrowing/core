defmodule Platform.Social.AccountTickerTest do
  use Platform.DataCase, async: false
  import Platform.SocialApprovalFixtures
  alias Platform.Social
  alias Platform.Social.{Account, AccountTicker, FollowerSnapshot, Post}
  @now ~U[2026-11-21 12:00:00.000000Z]

  setup do
    w = approval_fixture()
    profile = Repo.update!(Ecto.Changeset.change(w.profile, provider_profile_ref: "profile-A"))

    {:ok, account} =
      Social.create_account(w.org_id, profile, %{
        platform: "youtube",
        handle: "@example",
        provider: "zernio",
        provider_account_ref: "account-A",
        status: "connected"
      })

    %{w: %{w | profile: profile}, account: account}
  end

  defp page(entries, overrides \\ %{}) do
    rows =
      Enum.map(entries, fn {date, value} ->
        %{
          date: date,
          followers: value,
          account_id: "account-A",
          profile_id: "profile-A",
          platform: "youtube"
        }
      end)

    Map.merge(%{data: rows, stale: false, stale_since: nil}, overrides)
  end

  defp own_row(w, a),
    do: Enum.find(AccountTicker.rows(w.h1, [w.profile.id], now: @now), &(&1.account.id == a.id))

  test "daily revisions replace one dated value and foreign rows cannot be attached", %{
    w: w,
    account: a
  } do
    assert {:ok, 2} =
             AccountTicker.record(a, page([{~D[2026-11-13], 93}, {~D[2026-11-20], 97}]), @now)

    assert {:ok, 1} = AccountTicker.record(a, page([{~D[2026-11-20], 99}]), @now)
    assert Repo.aggregate(FollowerSnapshot, :count) == 2

    assert own_row(w, a).followers == %{
             value: 99,
             date: ~D[2026-11-20],
             change: 6,
             previous_date: ~D[2026-11-13]
           }

    bad = page([{~D[2026-11-20], 999}])
    bad = %{bad | data: [%{hd(bad.data) | profile_id: "other-profile"}]}
    assert {:error, :identity_mismatch} = AccountTicker.record(a, bad, @now)
    assert own_row(w, a).followers.value == 99
  end

  test "comparison uses latest observed date minus exactly seven days, never a neighbour", %{
    w: w,
    account: a
  } do
    assert {:ok, 3} =
             AccountTicker.record(
               a,
               page([{~D[2026-11-12], 10}, {~D[2026-11-14], 20}, {~D[2026-11-20], 97}]),
               @now
             )

    assert own_row(w, a).followers == %{
             value: 97,
             date: ~D[2026-11-20],
             change: nil,
             previous_date: ~D[2026-11-13]
           }
  end

  test "zero is observed while null is unavailable and cannot replace a good observation", %{
    w: w,
    account: a
  } do
    assert own_row(w, a).followers.value == nil

    assert {:ok, 1} =
             AccountTicker.record(a, page([{~D[2026-11-20], 0}, {~D[2026-11-21], nil}]), @now)

    assert own_row(w, a).followers.value == 0
    assert own_row(w, a).followers.date == ~D[2026-11-20]
    assert {:ok, 0} = AccountTicker.record(a, page([{~D[2026-11-20], nil}]), @now)
    assert own_row(w, a).followers.value == 0
  end

  test "a reconnected vendor identity cannot borrow the previous audience history", %{
    w: w,
    account: a
  } do
    assert {:ok, 1} = AccountTicker.record(a, page([{~D[2026-11-20], 97}]), @now)
    changed = Repo.update!(Ecto.Changeset.change(a, provider_account_ref: "account-B"))
    assert own_row(w, changed).followers.value == nil
  end

  test "LinkedIn has no follower value or target and invisible profiles produce no rows", %{
    w: w,
    account: a
  } do
    rows = AccountTicker.rows(w.h1, [w.profile.id], now: @now)
    linkedin = Enum.find(rows, &(&1.account.id == w.a.id))
    assert linkedin.followers == nil
    assert linkedin.follower_target == nil
    foreign = approval_fixture()
    assert AccountTicker.rows(foreign.h1, [w.profile.id], now: @now) == []
    assert AccountTicker.rows(nil, [w.profile.id], now: @now) == []
    assert own_row(w, a).account.id == a.id
  end

  defp published(w, a, at, views, synced \\ @now) do
    {:ok, post} = Social.create_post(w.org_id, a, %{body: "Measured post"})

    Repo.update!(
      Ecto.Changeset.change(post,
        status: "published",
        approved_at: at,
        approved_by_user_id: w.h1.id,
        published_at: at,
        metrics_synced_at: synced,
        metrics: if(is_nil(views), do: %{}, else: %{"views" => views})
      )
    )
  end

  test "views use the Results seven-day post cohort, keep partial data and isolate accounts", %{
    w: w,
    account: a
  } do
    published(w, a, ~U[2026-11-20 12:00:00.000000Z], 10)
    published(w, a, ~U[2026-11-19 12:00:00.000000Z], nil, nil)
    published(w, a, ~U[2026-11-13 12:00:00.000000Z], 999)
    published(w, w.a, ~U[2026-11-20 12:00:00.000000Z], 888)
    assert own_row(w, a).views == %{value: 10, posts: 2, measured: 1, synced_at: @now}
    assert own_row(w, w.d).views == %{value: nil, posts: 0, measured: 0, synced_at: nil}
    assert Repo.aggregate(Post, :count) == 4
  end

  test "views freshness is the oldest contributing measurement, not the latest", %{
    w: w,
    account: a
  } do
    older = DateTime.add(@now, -7200)
    published(w, a, DateTime.add(@now, -86400), 10, older)
    published(w, a, DateTime.add(@now, -3600), 20, @now)
    assert own_row(w, a).views == %{value: 30, posts: 2, measured: 2, synced_at: older}
  end

  test "per-account follower target is optional, positive and excludes LinkedIn", %{
    w: w,
    account: a
  } do
    assert Account.schedule_changeset(a, %{follower_target: 100}).valid?
    refute Account.schedule_changeset(a, %{follower_target: 0}).valid?
    refute Account.schedule_changeset(a, %{follower_target: -1}).valid?
    refute Account.schedule_changeset(a, %{follower_target: 2_147_483_648}).valid?
    refute Account.schedule_changeset(w.a, %{follower_target: 100}).valid?
    assert {:ok, a} = Social.update_account_schedule(w.org_id, a, %{follower_target: 100})
    assert own_row(w, a).follower_target == 100
    assert {:ok, a} = Social.update_account_schedule(w.org_id, a, %{follower_target: nil})
    assert own_row(w, a).follower_target == nil
  end

  test "a shared follower retry deadline is not a failed post-analytics refresh", %{
    w: w,
    account: a
  } do
    published(w, a, ~U[2026-11-20 12:00:00.000000Z], 10)
    Repo.insert!(%Social.Analytics.SyncState{org_id: w.org_id, retry_at: DateTime.add(@now, 60)})
    refute own_row(w, a).views_failed?
  end
end
