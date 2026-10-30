defmodule Platform.Social.WeeklyNoteTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Social.{Idea, WeeklyNote, WeeklyNotes}
  @week ~D[2026-11-02]
  @at ~U[2026-10-28 15:00:00.000000Z]

  setup do
    org = org_id!()
    {profile, account} = social_account!(org, "linkedin")
    agent = pinned_agent!(org)
    profile = profile |> Ecto.Changeset.change(drafting_agent_id: agent.id) |> Repo.update!()
    %{org: org, profile: profile, account: account, agent: agent}
  end

  defp post(c, metrics, opts \\ []) do
    approved_post!(c.org, c.account)
    |> Ecto.Changeset.change(
      status: Keyword.get(opts, :status, "published"),
      published_at: Keyword.get(opts, :at, @at),
      metrics: metrics,
      metrics_synced_at: Keyword.get(opts, :synced_at, @at),
      idea_id: Keyword.get(opts, :idea_id)
    )
    |> Repo.update!()
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

  defp voice(text \\ "Lead with a question") do
    %{kind: "voice", text: "Questions worked", payload: %{text: text}}
  end

  defp submit(c, items, opts \\ []) do
    WeeklyNotes.submit(
      c.org,
      c.profile.id,
      Keyword.get(opts, :week, @week),
      Keyword.get(opts, :summary, "Questions worked this week."),
      items,
      Keyword.get(opts, :author, {:agent, c.agent.id})
    )
  end

  test "facts name the literal leader, preserve per-platform unknowns and stable ties", c do
    leader = idea(c, "Ask about the tradeoff")
    bottom = idea(c, "Release announcement")
    tie = idea(c, "Another announcement")
    unknown = idea(c, "No measurement yet")
    post(c, %{"likes" => 20, "views" => 100}, idea_id: leader.id)
    {:ok, youtube} = Platform.Social.create_account(c.org, c.profile, %{platform: "youtube"})
    post(%{c | account: youtube}, %{"likes" => 4}, idea_id: leader.id)
    for source <- [bottom, tie], do: post(c, %{"likes" => 2}, idea_id: source.id)
    post(c, %{}, idea_id: unknown.id)
    post(c, %{"likes" => 999}, synced_at: nil, idea_id: unknown.id)
    post(c, %{"likes" => 9999})
    facts = WeeklyNote.facts(c.profile, @week)
    assert hd(facts.top_ideas).title == "Ask about the tradeoff"
    assert hd(facts.top_ideas).engagement == 24
    assert hd(facts.top_ideas).platform_numbers["linkedin"].views == 100
    assert hd(facts.top_ideas).platform_numbers["youtube"].views == nil
    assert Enum.map(tl(facts.top_ideas), & &1.idea_id) == Enum.sort([bottom.id, tie.id])

    assert Enum.map(Enum.take(facts.bottom_ideas, 2), & &1.idea_id) ==
             Enum.sort([bottom.id, tie.id])

    assert facts.published_count == 7
    assert Enum.find(facts.results, &(&1.idea_id == unknown.id)).engagement == nil
    refute Enum.any?(facts.top_ideas, &(&1.idea_id == unknown.id))
    assert WeeklyNote.facts(c.profile, @week) == facts
  end

  test "top and bottom contain exactly three measured ideas with literal independent rankings",
       c do
    for {title, likes} <- [
          {"Best", 100},
          {"Second", 80},
          {"Third", 60},
          {"Fourth", 40},
          {"Fifth", 0}
        ] do
      source = idea(c, title)
      post(c, %{"likes" => likes}, idea_id: source.id)
    end

    unknown = idea(c, "Unknown")
    post(c, %{}, idea_id: unknown.id)
    facts = WeeklyNote.facts(c.profile, @week)
    assert Enum.map(facts.top_ideas, & &1.title) == ["Best", "Second", "Third"]
    assert Enum.map(facts.bottom_ideas, & &1.title) == ["Fifth", "Fourth", "Third"]
  end

  test "delivery Monday facts span 169-hour fall DST week, excluding following Monday", c do
    profile = c.profile |> Ecto.Changeset.change(timezone: "America/New_York") |> Repo.update!()
    account = c.account |> Ecto.Changeset.change(weekly_goal: 5) |> Repo.update!()
    c = %{c | profile: profile, account: account}

    for at <- [
          ~U[2026-10-26 04:00:00.000000Z],
          ~U[2026-11-01 05:30:00.000000Z],
          ~U[2026-11-01 06:30:00.000000Z],
          ~U[2026-11-02 04:59:59.999999Z]
        ],
        do: post(c, %{}, at: at)

    post(c, %{"likes" => 999}, at: ~U[2026-10-26 03:59:59.999999Z])
    post(c, %{"likes" => 999}, at: ~U[2026-11-02 05:00:00.000000Z])
    post(c, %{}, status: "draft")
    facts = WeeklyNote.facts(profile, @week)
    assert facts.start_at == ~U[2026-10-26 04:00:00Z]
    assert facts.end_at == ~U[2026-11-02 05:00:00Z]
    assert DateTime.diff(facts.end_at, facts.start_at, :hour) == 169
    assert facts.reporting_week_start == ~D[2026-10-26]
    assert facts.week_start == @week
    assert facts.published_count == 4
    assert [%{published: 4, goal: 5}] = facts.goal_progress
    assert facts.top_ideas == []
  end

  test "spring DST and local Monday differ from seven elapsed UTC days", c do
    profile = c.profile |> Ecto.Changeset.change(timezone: "America/Denver") |> Repo.update!()

    assert {~U[2026-03-02 07:00:00Z], ~U[2026-03-09 06:00:00Z]} =
             WeeklyNote.reporting_window(profile, ~D[2026-03-09])

    post(c, %{}, at: ~U[2026-03-02 06:59:59.999999Z])
    post(c, %{}, at: ~U[2026-03-02 07:00:00.000000Z])
    post(c, %{}, at: ~U[2026-03-09 05:59:59.999999Z])
    post(c, %{}, at: ~U[2026-03-09 06:00:00.000000Z])
    assert WeeklyNote.facts(profile, ~D[2026-03-09]).published_count == 2
    assert_raise ArgumentError, fn -> WeeklyNote.facts(profile, ~D[2026-03-10]) end
  end

  test "timing differences use ten own samples in eight weeks, comparing three-hour buckets", c do
    {:ok, account} =
      c.account
      |> Platform.Social.Account.schedule_changeset(%{
        posting_slots: [%{weekday: 3, time: "16:15"}]
      })
      |> Repo.update()

    c = %{c | account: account}
    for _ <- 1..9, do: post(c, %{"likes" => 4})
    {_, foreign_account} = social_account!(c.org, "x")
    for _ <- 1..12, do: post(%{c | account: foreign_account}, %{"likes" => 999})
    post(c, %{"likes" => 999}, at: ~U[2026-09-01 12:00:00.000000Z])
    post(c, %{"likes" => 999}, synced_at: nil)
    post(c, %{})
    assert WeeklyNote.facts(c.profile, @week).timing_differences == []
    post(c, %{"likes" => 10}, at: ~U[2026-10-27 14:00:00.000000Z])
    facts = WeeklyNote.facts(c.profile, @week)

    assert [%{account_id: id, weekday: 2, time: "12:00", sample_count: 10}] =
             facts.timing_differences

    assert id == account.id
  end

  test "recycle facts reuse measured all-history eligibility", c do
    source = idea(c, "Evergreen question")
    post(c, %{"likes" => 20}, idea_id: source.id, at: ~U[2026-09-01 12:00:00.000000Z])
    post(c, %{})

    assert [%{idea_id: id, title: "Evergreen question"}] =
             WeeklyNote.facts(c.profile, @week).recycle_candidates

    assert id == source.id
  end

  test "submission persists trustworthy authorship, stable item ids and JSONB decisions", c do
    post(c, %{})
    id = Ecto.UUID.generate()

    assert {:ok, note} =
             submit(c, [
               Map.put(voice(), :id, id),
               %{kind: "other", text: "Keep testing", payload: %{}}
             ])

    stored = Repo.get!(WeeklyNote, note.id)
    assert stored.author_kind == "agent" and stored.author_id == c.agent.id
    assert stored.org_id == c.org and stored.profile_id == c.profile.id
    assert stored.week_start == @week
    assert [first, second] = stored.items
    assert first.id == id and is_binary(second.id) and first.id != second.id
    assert first.payload == %{"text" => "Lead with a question"}
    assert first.decision == nil and first.decided_by_user_id == nil and first.decided_at == nil

    assert %{rows: [["array"]]} =
             Repo.query!("SELECT jsonb_typeof(items) FROM social_weekly_notes WHERE id = $1", [
               Ecto.UUID.dump!(note.id)
             ])

    assert [^stored] = WeeklyNotes.list(c.org, c.profile.id)
    assert WeeklyNotes.get(c.org, stored.id) == stored
    assert WeeklyNotes.get(org_id!(), stored.id) == nil
    assert WeeklyNotes.get(c.org, "malformed") == nil
    assert WeeklyNotes.list(org_id!(), c.profile.id) == []
    assert {:error, changeset} = submit(c, [voice()])
    assert "has already been taken" in errors_on(changeset).profile_id
  end

  test "submission rejects forged decisions, duplicate ids and invalid payloads without writing",
       c do
    post(c, %{})

    for key <- [:decision, :decided_by_user_id, :decided_at, :author_id, :author_kind] do
      assert {:error, :invalid_item_fields} = submit(c, [Map.put(voice(), key, nil)])
    end

    id = Ecto.UUID.generate()

    assert {:error, :duplicate_item_ids} =
             submit(c, [Map.put(voice(), :id, id), Map.put(voice(), :id, id)])

    for invalid <- [nil, "bad", 42, [nil], [%{}]] do
      assert {:error, _} = submit(c, invalid)
    end

    for invalid <- ["", String.duplicate("x", 281)] do
      assert {:error, :invalid_voice} = submit(c, [voice(invalid)])
    end

    for invalid <- [nil, "bad", ~D[2026-11-03]] do
      assert {:error, :invalid_week_start} = submit(c, [voice()], week: invalid)
    end

    assert {:error, changeset} = submit(c, [voice()], summary: String.duplicate("x", 2001))
    assert "should be at most 2000 character(s)" in errors_on(changeset).summary
    assert Repo.aggregate(WeeklyNote, :count) == 0
  end

  test "timing and recycle refs must belong to exact profile, even within same org", c do
    post(c, %{})
    {foreign, foreign_account} = social_account!(c.org, "x")
    foreign_idea = idea(%{c | profile: foreign}, "Foreign")

    timing = %{
      kind: "timing",
      text: "Try midday",
      payload: %{account_id: foreign_account.id, weekday: 2, time: "14:00"}
    }

    assert {:error, :invalid_timing} = submit(c, [timing])

    assert {:error, :invalid_recycle} =
             submit(c, [%{kind: "recycle", text: "Reuse", payload: %{idea_id: foreign_idea.id}}])

    for {day, time} <- [{0, "14:00"}, {8, "14:00"}, {2, "24:00"}, {2, "2:00"}, {2, "12:60"}] do
      invalid = put_in(timing.payload, %{account_id: c.account.id, weekday: day, time: time})
      assert {:error, _} = submit(c, [invalid])
    end

    assert Repo.aggregate(WeeklyNote, :count) == 0
    own = idea(c, "Own")
    valid = put_in(timing.payload.account_id, c.account.id)

    assert {:ok, note} =
             submit(c, [valid, %{kind: "recycle", text: "Reuse", payload: %{idea_id: own.id}}])

    assert length(note.items) == 2
    assert Repo.get!(Platform.Social.Account, c.account.id).posting_slots == []
    assert Repo.get!(Platform.Social.Profile, c.profile.id).voice.learnings == []
  end

  test "scope, real agent home org and active status constrain authorship; system has no agent id",
       c do
    post(c, %{})
    outsider = pinned_agent!(org_id!())

    assert {:error, :not_found} =
             WeeklyNotes.submit(
               org_id!(),
               c.profile.id,
               @week,
               "Summary",
               [voice()],
               {:agent, c.agent.id}
             )

    assert {:error, :invalid_author} = submit(c, [voice()], author: {:agent, outsider.id})

    assert {:error, :invalid_author} =
             submit(c, [voice()], author: {:agent, Ecto.UUID.generate()})

    c.agent |> Ecto.Changeset.change(status: "archived") |> Repo.update!()
    assert {:error, :invalid_author} = submit(c, [voice()])
    assert {:error, :invalid_author} = submit(c, [voice()], author: {:system, c.agent.id})
    c.profile |> Ecto.Changeset.change(drafting_agent_id: nil) |> Repo.update!()
    assert {:ok, note} = submit(c, [voice()], author: {:system, nil})
    assert note.author_kind == "system" and note.author_id == nil
  end

  test "no publications produces explicit empty facts and no note, even with old results", c do
    post(c, %{}, status: "draft")
    post(c, %{"likes" => 5}, at: ~U[2026-10-25 12:00:00.000000Z])

    assert %{published_count: 0, top_ideas: [], bottom_ideas: [], results: []} =
             WeeklyNote.facts(c.profile, @week)

    assert {:error, :no_published_posts} = submit(c, [voice()])
    assert Repo.aggregate(WeeklyNote, :count) == 0
  end
end
