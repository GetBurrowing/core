defmodule Platform.Social.ResultsTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Social.{Idea, Results}
  @now ~U[2026-10-29 18:00:00.000000Z]

  setup do
    org = org_id!()
    {profile, account} = social_account!(org, "linkedin")
    %{org: org, profile: profile, account: account}
  end

  defp post(c, metrics, opts \\ []) do
    approved_post!(c.org, c.account)
    |> Ecto.Changeset.change(
      status: Keyword.get(opts, :status, "published"),
      published_at: Keyword.get(opts, :at, @now),
      scheduled_at: Keyword.get(opts, :scheduled_at),
      metrics: metrics,
      metrics_synced_at: Keyword.get(opts, :synced_at, @now),
      idea_id: Keyword.get(opts, :idea_id),
      external_url: "https://example.com/post"
    )
    |> Repo.update!()
  end

  test "three platform versions sum and rate correctly inside explicit profile scope", c do
    idea =
      Repo.insert!(%Idea{
        org_id: c.org,
        profile_id: c.profile.id,
        title: "An idea",
        source_kind: "human",
        created_by_user_id: user!().id
      })

    {:ok, ig} = Platform.Social.create_account(c.org, c.profile, %{platform: "instagram"})
    {:ok, yt} = Platform.Social.create_account(c.org, c.profile, %{platform: "youtube"})

    post(
      c,
      %{
        "views" => 100,
        "likes" => 10,
        "comments" => 2,
        "shares" => 3,
        "saves" => 5,
        "reach" => 200
      },
      idea_id: idea.id
    )

    post(%{c | account: ig}, %{"views" => 200, "likes" => 4, "reach" => 0}, idea_id: idea.id)
    post(%{c | account: yt}, %{"views" => 300, "likes" => 6}, idea_id: idea.id)
    {_, outside} = social_account!(c.org, "x")
    post(%{c | account: outside}, %{"likes" => 9999})
    [row] = Results.by_idea([c.profile], 30, now: @now)
    assert row.key == "idea:#{idea.id}"
    assert row.title == "An idea"
    assert row.brand == c.profile.name
    assert row.engagement == 30
    assert row.metrics == %{views: 600, likes: 20, comments: 2, shares: 3, saves: 5, reach: 200}
    assert length(row.versions) == 3
    li = Enum.find(row.versions, &(&1.platform == "linkedin"))
    assert li.engagement_rate == 0.1
    assert li.external_url == "https://example.com/post"
    assert Enum.find(row.versions, &(&1.platform == "instagram")).engagement_rate == nil
    assert Enum.find(row.versions, &(&1.platform == "youtube")).engagement_rate == nil
  end

  test "unknown, empty, missing keys, zero, prior snapshots and nil-idea isolation", c do
    missing = post(c, %{"likes" => 99}, synced_at: nil)
    empty = post(c, %{})
    zero = post(c, %{"likes" => 0, "reach" => 20})
    prior = post(c, %{"likes" => 4}, synced_at: DateTime.add(@now, -1, :day))
    rows = Results.by_idea([c.profile], 7, now: @now)
    assert length(rows) == 4
    assert Enum.map(rows, & &1.engagement) == [4, 0, nil, nil]
    unknown = Enum.find(rows, &(&1.key == "post:#{missing.id}"))
    assert unknown.metrics.likes == nil
    assert hd(unknown.versions).data_state == :no_data
    assert Enum.find(rows, &(&1.key == "post:#{empty.id}")).metrics.views == nil
    measured = Enum.find(rows, &(&1.key == "post:#{zero.id}")) |> Map.fetch!(:versions) |> hd()
    assert measured.engagement == 0
    assert measured.engagement_rate == 0.0
    assert measured.metrics.views == nil
    assert measured.data_state == :measured
    assert hd(rows).key == "post:#{prior.id}"
    assert Results.by_idea([], 7, now: @now) == []
    assert_raise FunctionClauseError, fn -> Results.by_idea([c.profile.id], 7) end
  end

  test "UTC windows include exact start and exclude older, future and unpublished posts", c do
    for days <- [7, 30, 90] do
      post(c, %{"likes" => days}, at: DateTime.add(@now, -days, :day))
      post(c, %{"likes" => 999}, at: DateTime.add(@now, -days * 86400 - 1, :second))
    end

    post(c, %{"likes" => 9999}, at: DateTime.add(@now, 1, :second))
    post(c, %{"likes" => 9999}, status: "draft")
    assert length(Results.by_idea([c.profile], 7, now: @now)) == 1
    assert length(Results.by_idea([c.profile], 30, now: @now)) == 3
    assert length(Results.by_idea([c.profile], 90, now: @now)) == 5
    assert_raise FunctionClauseError, fn -> Results.by_idea([c.profile], 8) end
  end

  test "engagement ties sort by stable group key", c do
    a = post(c, %{"likes" => 10})
    b = post(c, %{"likes" => 10})

    assert Enum.map(Results.by_idea([c.profile], 7, now: @now), & &1.key) ==
             Enum.sort(["post:#{a.id}", "post:#{b.id}"])
  end

  test "9/10 gate excludes other accounts, unsynced and old posts; mean differs from total", c do
    c.profile |> Ecto.Changeset.change(timezone: "America/Denver") |> Repo.update!()
    for _ <- 1..9, do: post(c, %{"likes" => 10}, at: ~U[2026-10-29 15:00:00.000000Z])
    {_, other} = social_account!(c.org, "x")
    for _ <- 1..10, do: post(%{c | account: other}, %{"likes" => 1000})
    post(c, %{"likes" => 100}, at: DateTime.add(@now, -57, :day))
    post(c, %{"likes" => 100}, synced_at: nil)
    assert Results.best_times_count(c.account, now: @now) == 9
    assert Results.best_times(c.account, now: @now) == nil
    post(c, %{"likes" => 30}, at: ~U[2026-10-28 14:59:59.000000Z])
    result = Results.best_times(c.account, now: @now)
    assert result.count == 10
    assert result.timezone == "America/Denver"

    assert result.buckets == [
             %{weekday: 3, hour: 6, engagement: 30, post_count: 1, mean_engagement: 30.0},
             %{weekday: 4, hour: 9, engagement: 90, post_count: 9, mean_engagement: 10.0}
           ]

    post(c, %{"likes" => 0})
    assert Results.best_times_count(c.account, now: @now) == 11
  end

  test "DST repeated hour and UTC-to-local weekday buckets", c do
    c.profile |> Ecto.Changeset.change(timezone: "America/New_York") |> Repo.update!()
    for _ <- 1..5, do: post(c, %{"likes" => 2}, at: ~U[2026-11-01 05:30:00.000000Z])
    for _ <- 1..5, do: post(c, %{"likes" => 4}, at: ~U[2026-11-01 06:30:00.000000Z])
    post(c, %{"likes" => 7}, at: ~U[2026-11-02 00:30:00.000000Z])
    result = Results.best_times(c.account, now: ~U[2026-11-02 12:00:00.000000Z])

    assert result.buckets == [
             %{weekday: 7, hour: 0, engagement: 30, post_count: 10, mean_engagement: 3.0},
             %{weekday: 7, hour: 18, engagement: 7, post_count: 1, mean_engagement: 7.0}
           ]
  end

  test "local Monday week spans DST; goal five, three publications, schedule excluded", c do
    assert Results.weekly_progress(c.account, now: @now) == nil
    c.profile |> Ecto.Changeset.change(timezone: "America/New_York") |> Repo.update!()
    account = c.account |> Ecto.Changeset.change(weekly_goal: 5) |> Repo.update!()
    c = %{c | account: account}

    for at <- [
          ~U[2026-10-26 04:00:00.000000Z],
          ~U[2026-11-01 05:30:00.000000Z],
          ~U[2026-11-01 06:30:00.000000Z]
        ],
        do: post(c, %{}, at: at)

    post(c, %{}, at: ~U[2026-10-26 03:59:59.000000Z])
    post(c, %{}, at: ~U[2026-11-02 05:00:00.000000Z])
    post(c, %{}, status: "scheduled", at: nil, scheduled_at: ~U[2026-11-01 12:00:00.000000Z])
    progress = Results.weekly_progress(account, now: ~U[2026-11-01 20:00:00.000000Z])
    assert progress.published == 3
    assert progress.goal == 5
    assert progress.week_start == ~U[2026-10-26 04:00:00Z]
    assert progress.week_end == ~U[2026-11-02 05:00:00Z]
  end

  test "all-brands aggregation preserves brand and partial measurements; exact eight-week sample",
       c do
    {profile, account} = social_account!(c.org, "x")
    other = post(%{c | account: account}, %{"views" => 12, "reach" => 20})
    own = post(c, %{"likes" => 2})
    rows = Results.by_idea([c.profile, profile], 90, now: @now)
    assert Enum.map(rows, & &1.key) == ["post:#{own.id}", "post:#{other.id}"]
    unknown_engagement = List.last(rows)
    assert unknown_engagement.brand == profile.name
    assert unknown_engagement.metrics.views == 12
    assert unknown_engagement.engagement == nil
    assert hd(unknown_engagement.versions).engagement_rate == nil
    post(c, %{"likes" => 3}, at: DateTime.add(@now, -56, :day))
    post(c, %{"likes" => 9}, at: DateTime.add(@now, -56 * 86400 - 1, :second))
    post(c, %{"likes" => 9}, at: DateTime.add(@now, 1, :second))
    post(c, %{}, at: @now)
    post(c, %{"likes" => 9}, status: "draft")
    assert Results.best_times_count(c.account, now: @now) == 2
    assert Results.best_times_count(c.account, weeks: 7, now: @now) == 1
  end
end
