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

  defp idea(c, title) do
    Repo.insert!(%Idea{
      org_id: c.org,
      profile_id: c.profile.id,
      title: title,
      source_kind: "human",
      created_by_user_id: user!().id
    })
  end

  test "all-history cohort rounds up before eligibility; no replacement or standalone groups",
       c do
    old = DateTime.add(@now, -120, :day)

    leaders =
      for n <- 1..6 do
        source = idea(c, "Idea #{n}")
        post(c, %{"likes" => 100 - n}, idea_id: source.id, at: old)
        source
      end

    post(c, %{"likes" => 9999}, at: old)
    unknown = idea(c, "Unknown")
    post(c, %{}, idea_id: unknown.id, at: old)
    [first, second | _] = leaders

    assert Enum.map(Results.recycle_candidates([c.profile], now: @now), & &1.idea_id) == [
             first.id,
             second.id
           ]

    post(c, %{"likes" => 0}, idea_id: first.id, at: DateTime.add(@now, -30 * 86400 + 1, :second))

    assert Enum.map(Results.recycle_candidates([c.profile], now: @now), & &1.idea_id) == [
             second.id
           ]

    second |> Ecto.Changeset.change(archived_at: @now) |> Repo.update!()
    assert Results.recycle_candidates([c.profile], now: @now) == []
    assert Results.recycle_candidates([], now: @now) == []
  end

  test "exact 30day boundary and stable tie ranking includes measured zero", c do
    first = idea(c, "First")
    second = idea(c, "Second")
    post(c, %{"likes" => 0}, idea_id: first.id, at: DateTime.add(@now, -30, :day))
    post(c, %{"likes" => 0}, idea_id: second.id, at: DateTime.add(@now, -30, :day))

    assert Enum.map(Results.recycle_candidates([c.profile], now: @now), & &1.idea_id) == [
             min(first.id, second.id)
           ]
  end

  test "recycle creates human Inbox child, bounded reference notes, no posts or source refs", c do
    source =
      idea(c, "Recycle me")
      |> Ecto.Changeset.change(source_kind: "url", source_url: "https://example.com/original")
      |> Repo.update!()

    original =
      post(c, %{"likes" => 20},
        idea_id: source.id,
        at: DateTime.add(DateTime.utc_now(), -31, :day)
      )

    original =
      original |> Ecto.Changeset.change(body: String.duplicate("body ", 1500)) |> Repo.update!()

    user = make_approver!(c.org, c.profile, user!())
    count = Repo.aggregate(Platform.Social.Post, :count)
    Phoenix.PubSub.subscribe(Platform.PubSub, Platform.Social.Ideas.posts_topic(c.profile.id))
    assert {:ok, child} = Results.recycle(c.org, source.id, user.id)
    assert child.recycled_from_idea_id == source.id
    assert child.created_by_user_id == user.id and child.created_by_agent_id == nil
    assert child.source_kind == "human"
    assert child.profile_id == source.profile_id and child.org_id == source.org_id
    assert child.source_url == nil and child.clip_id == nil
    assert Platform.Social.Ideas.stage([]) == "inbox"
    assert Platform.Social.Ideas.posts(child) == []
    assert Repo.aggregate(Platform.Social.Post, :count) == count
    assert Repo.get!(Platform.Social.Post, original.id) == original
    assert Repo.get!(Idea, source.id) == source
    [note] = Platform.Social.IdeaNotes.list(child.id)
    assert note.author_kind == "human" and note.author_id == user.id
    assert String.length(note.body) == 4000

    for text <- [
          "reference only",
          "linkedin",
          original.id,
          original.external_url,
          DateTime.to_iso8601(original.published_at)
        ],
        do: assert(note.body =~ text)

    assert_receive {:social_ideas_changed, _}
    refute_receive {:social_ideas_changed, _}, 30
    assert Results.recycle_candidates([c.profile]) == []
    assert {:error, :not_eligible} = Results.recycle(c.org, source.id, user.id)

    assert Repo.aggregate(from(i in Idea, where: i.recycled_from_idea_id == ^source.id), :count) ==
             1

    refute_receive {:social_ideas_changed, _}, 30
  end

  test "malformed/cross-org ids and nonapprovers write nothing; parent is never cast", c do
    source = idea(c, "Scoped")
    post(c, %{"likes" => 5}, idea_id: source.id, at: DateTime.add(DateTime.utc_now(), -31, :day))
    user = make_approver!(c.org, c.profile, user!())
    count = Repo.aggregate(Idea, :count)
    assert {:error, :not_found} = Results.recycle(org_id!(), source.id, user.id)
    assert {:error, :not_found} = Results.recycle(c.org, "broken", user.id)
    assert {:error, :not_an_approver} = Results.recycle(c.org, source.id, user!().id)
    assert Repo.aggregate(Idea, :count) == count

    {:ok, ordinary} =
      Platform.Social.Ideas.create(
        c.org,
        c.profile.id,
        %{title: "Injected parent", recycled_from_idea_id: source.id},
        {:user, user.id}
      )

    assert ordinary.recycled_from_idea_id == nil
  end

  test "recycle rechecks displayed cross-brand cohort and rejects forged scope", c do
    {other_profile, other_account} = social_account!(c.org, "x")
    old = DateTime.add(DateTime.utc_now(), -31, :day)

    own =
      for score <- [100, 90, 80, 70, 60, 50] do
        source = idea(c, "Score #{score}")
        post(c, %{"likes" => score}, idea_id: source.id, at: old)
        source
      end

    for score <- 1..5 do
      source = idea(%{c | profile: other_profile}, "Other #{score}")
      post(%{c | account: other_account}, %{"likes" => score}, idea_id: source.id, at: old)
    end

    target = Enum.at(own, 2)
    profiles = [c.profile, other_profile]

    assert Enum.map(Results.recycle_candidates(profiles), & &1.idea_id) ==
             Enum.map(Enum.take(own, 3), & &1.id)

    user = make_approver!(c.org, c.profile, user!())

    assert {:error, :not_eligible} =
             Results.recycle(c.org, target.id, user.id, profiles: [c.profile])

    {foreign, _} = social_account!(org_id!(), "youtube")

    assert {:error, :not_found} =
             Results.recycle(c.org, target.id, user.id, profiles: profiles ++ [foreign])

    assert {:error, :not_found} =
             Results.recycle(c.org, target.id, user.id, profiles: [other_profile])

    assert {:error, :not_found} =
             Results.recycle(c.org, target.id, user.id, profiles: [c.profile.id])

    assert Repo.aggregate(from(i in Idea, where: i.recycled_from_idea_id == ^target.id), :count) ==
             0

    assert {:ok, child} = Results.recycle(c.org, target.id, user.id, profiles: profiles)
    assert child.recycled_from_idea_id == target.id
    # A separate candidate exercises the /3 All brands default.
    assert {:ok, _} = Results.recycle(c.org, hd(own).id, user.id)
  end

  defp unboxed(fun) do
    Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end) |> Task.await(30_000)
  end

  defp committed_recycle_world do
    w =
      unboxed(fn ->
        org = org_id!()
        {profile, account} = social_account!(org, "linkedin")
        user = make_approver!(org, profile, user!())
        c = %{org: org, profile: profile, account: account}

        {:ok, source} =
          Platform.Social.Ideas.create(
            org,
            profile.id,
            %{title: "Concurrent #{unique()}"},
            {:user, user.id}
          )

        # Real independent PostgreSQL connections need committed fixtures.
        at = DateTime.add(DateTime.utc_now(), -31, :day)

        for n <- 1..2 do
          Repo.insert!(%Platform.Social.Post{
            account_id: account.id,
            idea_id: source.id,
            status: "published",
            approved_by_user_id: user.id,
            approved_at: at,
            body: "Original #{n}",
            published_at: at,
            metrics_synced_at: at,
            metrics: %{"likes" => 10}
          })
        end

        Map.merge(c, %{source: source, user: user})
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(i in Idea, where: i.recycled_from_idea_id == ^w.source.id))
        Repo.delete_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id))
        Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^w.profile.space_id))
        Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^w.user.id))
        Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^w.org))
      end)
    end)

    w
  end

  test "independent concurrent requests yield one child and one note per original version" do
    w = committed_recycle_world()
    parent = self()

    holder =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from(i in Idea, where: i.id == ^w.source.id, lock: "FOR UPDATE"))
            send(parent, :source_locked)

            receive do
              :release -> :ok
            after
              5000 -> raise "lock barrier timeout"
            end
          end)
        end)
      end)

    assert_receive :source_locked, 5000

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Results.recycle(w.org, w.source.id, w.user.id)
            end
          end)
        end)
      end

    for _ <- 1..2 do
      assert_receive {:ready, pid}, 5000
      send(pid, :go)
    end

    # Both requests reach a real row lock held on a third connection.
    for task <- tasks, do: assert(Task.yield(task, 100) == nil)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)
    results = Enum.map(tasks, &Task.await(&1, 10000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_eligible})) == 1

    unboxed(fn ->
      [child] = Repo.all(from(i in Idea, where: i.recycled_from_idea_id == ^w.source.id))
      assert length(Platform.Social.IdeaNotes.list(child.id)) == 2

      assert Repo.aggregate(
               from(p in Platform.Social.Post, where: p.account_id == ^w.account.id),
               :count
             ) == 2

      # The index protects all writers, independently of Results' row lock.
      changeset =
        %Idea{org_id: w.org, profile_id: w.profile.id, recycled_from_idea_id: w.source.id}
        |> Idea.changeset(%{title: "Duplicate", source_kind: "human"}, {:user, w.user.id})

      assert {:error, invalid} = Repo.insert(changeset)
      assert "has already been taken" in errors_on(invalid).recycled_from_idea_id
    end)
  end

  test "note insertion failure rolls back child and all notes without broadcasting" do
    w = committed_recycle_world()
    Phoenix.PubSub.subscribe(Platform.PubSub, Platform.Social.Ideas.posts_topic(w.profile.id))
    # A real DB failure after the child exists verifies atomic rollback.
    unboxed(fn ->
      Repo.query!(
        "CREATE FUNCTION results_test_note_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.author_id = '#{w.user.id}'::uuid AND position('Original 2' in NEW.body) > 0 THEN RAISE EXCEPTION 'results note failure'; END IF; RETURN NEW; END $$"
      )

      Repo.query!(
        "CREATE TRIGGER results_test_note_failure BEFORE INSERT ON social_idea_notes FOR EACH ROW EXECUTE FUNCTION results_test_note_failure()"
      )
    end)

    try do
      unboxed(fn ->
        assert_raise Postgrex.Error, ~r/results note failure/, fn ->
          Results.recycle(w.org, w.source.id, w.user.id)
        end

        assert Repo.aggregate(
                 from(i in Idea, where: i.recycled_from_idea_id == ^w.source.id),
                 :count
               ) == 0

        assert Results.recycle_candidates([w.profile]) != []
      end)

      refute_receive {:social_ideas_changed, _}, 50
    after
      unboxed(fn ->
        Repo.query!("DROP TRIGGER results_test_note_failure ON social_idea_notes")
        Repo.query!("DROP FUNCTION results_test_note_failure()")
      end)
    end
  end
end
