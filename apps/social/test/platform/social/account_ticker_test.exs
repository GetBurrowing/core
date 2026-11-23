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

  defp publication!(w, account, attrs \\ %{}) do
    struct!(
      Social.Analytics.Publication,
      Map.merge(
        %{
          account_id: account.id,
          profile_id: w.profile.id,
          provider_account_ref: account.provider_account_ref,
          provider_profile_ref: w.profile.provider_profile_ref,
          platform: "youtube",
          native_id: "abcdefghijk",
          published_at: ~U[2026-10-01 12:00:00.000000Z],
          vendor_synced_at: @now,
          fetched_at: @now,
          last_listed_at: @now,
          listed_from: ~D[2026-10-01],
          listed_to: ~D[2026-10-30],
          is_owner: true,
          sync_status: "synced",
          metrics: %{"views" => 0}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "latest account-associated publication survives seven days, permits null flags and requires project access" do
    w = Platform.SocialStudioFixtures.studio_world!()

    profile =
      Repo.update!(Ecto.Changeset.change(w.profile, provider_profile_ref: "publication-profile"))

    w = %{w | profile: profile}

    {:ok, a} =
      Social.create_account(w.org_id, profile, %{
        platform: "youtube",
        provider: "zernio",
        provider_account_ref: "publication-account",
        status: "connected"
      })

    video = publication!(w, a)

    row =
      Enum.find(AccountTicker.rows(w.approver, [profile.id], now: @now), &(&1.account.id == a.id))

    assert row.latest_video.video.id == video.id
    assert row.latest_video.video.metrics["views"] == 0

    newer =
      publication!(w, a, %{
        native_id: "ZYXWVUTSRQP",
        published_at: ~U[2026-11-20 12:00:00.000000Z],
        listed_from: ~D[2026-11-20],
        listed_to: ~D[2026-11-20],
        is_owner: nil,
        is_ad: nil,
        metrics: %{"views" => 66}
      })

    row =
      Enum.find(AccountTicker.rows(w.approver, [profile.id], now: @now), &(&1.account.id == a.id))

    assert row.latest_video.video.id == newer.id
    assert row.latest_video.video.metrics["views"] == 66
    assert row.latest_video.history_incomplete
    assert row.latest_video.checked_from == nil
    assert row.latest_video.checked_to == nil

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, w.approver.id},
               permission: "social.use",
               resource: {:project, w.project.id}
             })

    row =
      Enum.find(AccountTicker.rows(w.approver, [profile.id], now: @now), &(&1.account.id == a.id))

    assert row.latest_video == nil
    assert row.views.posts == 0
  end

  test "projectless legacy accounts retain existing ticker without publication projection", %{
    w: w,
    account: a
  } do
    publication!(w, a)
    assert own_row(w, a).latest_video == nil
    assert own_row(w, a).followers.value == nil
  end

  defp publication_world! do
    w = Platform.SocialStudioFixtures.studio_world!()

    profile =
      Repo.update!(Ecto.Changeset.change(w.profile, provider_profile_ref: "range-profile"))

    {:ok, a} =
      Social.create_account(w.org_id, profile, %{
        platform: "youtube",
        provider: "zernio",
        provider_account_ref: "range-account",
        status: "connected"
      })

    {%{w | profile: profile}, a}
  end

  defp range(first, last), do: %{"from" => first, "to" => last}

  defp publication_state!(w, a, kind, attrs) do
    struct!(
      Social.Analytics.PublicationSyncState,
      Map.merge(
        %{
          account_id: a.id,
          kind: kind,
          provider_account_ref: a.provider_account_ref,
          provider_profile_ref: w.profile.provider_profile_ref
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp latest_projection(w, a),
    do:
      Enum.find(
        AccountTicker.rows(w.approver, [w.profile.id], now: @now),
        &(&1.account.id == a.id)
      ).latest_video

  test "an older cached video cannot inherit completeness from a newer checked window" do
    {w, a} = publication_world!()
    publication!(w, a)
    checked = [range("2026-11-01", "2026-11-21")]

    publication_state!(w, a, "discovery", %{
      checked_ranges: checked,
      from_date: ~D[2026-11-01],
      to_date: ~D[2026-11-21],
      completed_at: @now
    })

    projection = latest_projection(w, a)
    assert projection.checked_ranges == checked
    assert projection.search_incomplete
    assert projection.newer_possible
    refute projection.figures_stale
  end

  test "failed historical discovery does not stale a successfully refreshed video's figures" do
    {w, a} = publication_world!()
    publication!(w, a, %{published_at: ~U[2026-11-20 12:00:00.000000Z]})
    checked = [range("2026-11-01", "2026-11-21")]
    unfinished = [range("2026-10-01", "2026-10-30")]

    publication_state!(w, a, "discovery", %{
      checked_ranges: checked,
      incomplete_ranges: unfinished,
      from_date: ~D[2026-10-01],
      to_date: ~D[2026-10-30],
      last_error: "refresh_failed",
      attempted_at: @now
    })

    publication_state!(w, a, "refresh", %{
      checked_ranges: [range("2026-11-20", "2026-11-20")],
      from_date: ~D[2026-11-20],
      to_date: ~D[2026-11-20],
      completed_at: @now
    })

    projection = latest_projection(w, a)
    assert projection.search_incomplete
    refute projection.newer_possible
    refute projection.figures_stale
    assert projection.discovery.incomplete_ranges == unfinished
    assert projection.discovery.last_error == "refresh_failed"
    assert projection.refresh.last_error == nil
  end

  test "refresh pagination alone does not turn completed discovery into an incomplete search" do
    {w, a} = publication_world!()
    publication!(w, a, %{published_at: ~U[2026-11-20 12:00:00.000000Z]})
    checked = [range("2026-11-01", "2026-11-21")]

    publication_state!(w, a, "discovery", %{
      checked_ranges: checked,
      from_date: ~D[2026-11-01],
      to_date: ~D[2026-11-21],
      completed_at: @now
    })

    publication_state!(w, a, "refresh", %{
      incomplete_ranges: [range("2026-11-20", "2026-11-20")],
      from_date: ~D[2026-11-20],
      to_date: ~D[2026-11-20],
      cursor: "opaque"
    })

    projection = latest_projection(w, a)
    refute projection.search_incomplete
    refute projection.newer_possible
    refute projection.figures_stale
    assert projection.refresh.cursor == "opaque"
  end

  test "checked ranges keep gaps and only a failed refresh covering this video stales figures" do
    {w, a} = publication_world!()
    publication!(w, a, %{published_at: ~U[2026-11-04 12:00:00.000000Z]})
    checked = [range("2026-11-01", "2026-11-05"), range("2026-11-10", "2026-11-21")]

    publication_state!(w, a, "discovery", %{
      checked_ranges: checked,
      from_date: ~D[2026-11-10],
      to_date: ~D[2026-11-21],
      completed_at: @now
    })

    state =
      publication_state!(w, a, "refresh", %{
        from_date: ~D[2026-11-20],
        to_date: ~D[2026-11-20],
        last_error: "refresh_failed",
        attempted_at: @now
      })

    projection = latest_projection(w, a)
    assert projection.checked_ranges == checked
    assert projection.search_incomplete
    assert projection.newer_possible
    refute projection.figures_stale
    Repo.update!(Ecto.Changeset.change(state, from_date: ~D[2026-11-04], to_date: ~D[2026-11-04]))
    assert latest_projection(w, a).figures_stale

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Platform.Social.Analytics.PublicationSyncState, state.id),
        last_error: "coverage_repaired"
      )
    )

    refute latest_projection(w, a).figures_stale
  end

  test "a demoted newer observation qualifies fallback selection without inventing a date gap" do
    {w, a} = publication_world!()
    fallback = publication!(w, a, %{published_at: ~U[2026-11-19 12:00:00.000000Z]})

    publication!(w, a, %{
      native_id: "ZYXWVUTSRQP",
      published_at: ~U[2026-11-20 12:00:00.000000Z]
    })

    binding = %{
      org_id: w.org_id,
      profile_id: w.profile.id,
      account_id: a.id,
      platform: "youtube",
      provider_account_ref: a.provider_account_ref,
      provider_profile_ref: w.profile.provider_profile_ref
    }

    query = %{kind: "refresh", from_date: ~D[2026-11-20], to_date: ~D[2026-11-20], cursor: nil}

    assert {:ok, _} =
             Platform.Social.Analytics.Publications.apply_page(
               binding,
               query,
               %{data: [], has_more: false, next_cursor: nil, stale: false, missing_ids: []},
               @now
             )

    assert Repo.get_by!(Platform.Social.Analytics.Publication, native_id: "ZYXWVUTSRQP").not_listed

    publication_state!(w, a, "discovery", %{
      checked_ranges: [range("2026-11-01", "2026-11-21")],
      from_date: ~D[2026-11-01],
      to_date: ~D[2026-11-21],
      completed_at: @now
    })

    projection = latest_projection(w, a)
    assert projection.video.id == fallback.id
    assert projection.selection_uncertain
    refute projection.search_incomplete
    refute projection.newer_possible
  end

  test "malformed persisted coverage cannot silently become a complete empty history" do
    {w, a} = publication_world!()
    publication!(w, a)

    publication_state!(w, a, "discovery", %{
      checked_ranges: [%{"from" => "broken", "to" => "2026-11-21"}],
      from_date: ~D[2026-11-01],
      to_date: ~D[2026-11-21],
      completed_at: @now
    })

    projection = latest_projection(w, a)
    assert projection.search_incomplete
    assert projection.coverage_unavailable
    assert projection.checked_ranges == []
    assert projection.discovery.incomplete_ranges == []
    refute projection.newer_possible
  end
end
