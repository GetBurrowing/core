defmodule Platform.Social.SlotsTest do
  @moduledoc """
  Social authoring 4/11 (task 01a16c4f-9041): posting slots as UTC instants.
  `Platform.Social.next_free_slot/2` and `slots_in_week/2` read slots in the
  PROFILE's timezone, across DST changes and midnight in either direction.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Post, Slots}

  setup do
    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Clock #{unique()}"})
    {:ok, account} = Social.create_account(org_id, profile, %{platform: "x", handle: "clock"})
    %{org_id: org_id, profile: profile, account: account, user: user!()}
  end

  defp with_tz(ctx, tz) do
    {:ok, profile} = Social.update_profile(ctx.org_id, ctx.profile, %{timezone: tz})
    profile
  end

  defp slots!(ctx, slots, goal \\ nil) do
    {:ok, account} =
      Social.update_account_schedule(ctx.org_id, ctx.account, %{
        posting_slots: slots,
        weekly_goal: goal
      })

    account
  end

  defp post!(ctx, at, status) do
    approved? = status in Post.approved_statuses()

    Repo.insert!(%Post{
      account_id: ctx.account.id,
      body: "Neutral copy",
      status: status,
      scheduled_at: %{at | microsecond: {0, 6}},
      approved_by_user_id: if(approved?, do: ctx.user.id),
      approved_at: if(approved?, do: DateTime.utc_now())
    })
  end

  describe "a Denver Monday 09:00 slot (done means)" do
    setup ctx do
      with_tz(ctx, "America/Denver")
      %{account: slots!(ctx, [%{weekday: 1, time: "09:00"}])}
    end

    test "after the 2026-11-01 change it resolves to 16:00Z, not 15:00Z", ctx do
      assert Social.next_free_slot(ctx.account, ~U[2026-11-01 12:00:00Z]) ==
               ~U[2026-11-02 16:00:00Z]

      # The week before, still on summer time, it is 15:00Z.
      assert Social.next_free_slot(ctx.account, ~U[2026-10-25 12:00:00Z]) ==
               ~U[2026-10-26 15:00:00Z]
    end

    test "with that slot taken, next_free returns the next slot", ctx do
      post!(ctx, ~U[2026-11-02 16:00:00Z], "scheduled")

      assert Social.next_free_slot(ctx.account, ~U[2026-11-01 12:00:00Z]) ==
               ~U[2026-11-09 16:00:00Z]
    end

    test "approved and published posts hold a slot; drafts and needs_approval do not", ctx do
      post!(ctx, ~U[2026-11-02 16:00:00Z], "draft")
      post!(ctx, ~U[2026-11-02 16:00:00Z], "needs_approval")

      assert Social.next_free_slot(ctx.account, ~U[2026-11-01 12:00:00Z]) ==
               ~U[2026-11-02 16:00:00Z]

      post!(ctx, ~U[2026-11-02 16:00:30Z], "approved")
      post!(ctx, ~U[2026-11-09 16:00:00Z], "published")

      assert Social.next_free_slot(ctx.account, ~U[2026-11-01 12:00:00Z]) ==
               ~U[2026-11-16 16:00:00Z]
    end

    test "another account's post does not take this account's slot", ctx do
      {:ok, other} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "linkedin"})
      post!(%{ctx | account: other}, ~U[2026-11-02 16:00:00Z], "scheduled")

      assert Social.next_free_slot(ctx.account, ~U[2026-11-01 12:00:00Z]) ==
               ~U[2026-11-02 16:00:00Z]
    end

    test "a slot exactly at `now` counts (at or after); a second later it does not", ctx do
      assert Social.next_free_slot(ctx.account, ~U[2026-11-02 16:00:00Z]) ==
               ~U[2026-11-02 16:00:00Z]

      assert Social.next_free_slot(ctx.account, ~U[2026-11-02 16:00:01Z]) ==
               ~U[2026-11-09 16:00:00Z]
    end
  end

  test "with no slots it returns nil", ctx do
    with_tz(ctx, "America/Denver")
    assert Social.next_free_slot(ctx.account, ~U[2026-11-01 12:00:00Z]) == nil
  end

  test "an archived account has no next slot", ctx do
    account = slots!(ctx, [%{weekday: 1, time: "09:00"}])
    {:ok, archived} = Social.archive_account(ctx.org_id, account)
    assert Social.next_free_slot(archived, ~U[2026-11-01 12:00:00Z]) == nil
  end

  test "every slot taken for the whole horizon returns nil", ctx do
    account = slots!(ctx, [%{weekday: 1, time: "09:00"}])
    start = ~U[2026-11-02 09:00:00Z]

    for week <- 0..53, do: post!(ctx, DateTime.add(start, week * 7 * 86_400, :second), "approved")

    assert Social.next_free_slot(account, ~U[2026-11-01 00:00:00Z]) == nil
  end

  describe "midnight wrap" do
    test "a Denver Monday 18:30 slot is Tuesday 00:30Z (local weekday wins)", ctx do
      with_tz(ctx, "America/Denver")
      account = slots!(ctx, [%{weekday: 1, time: "18:30"}])

      # Tuesday 00:00Z is still Monday 18:00 in Denver.
      assert Social.next_free_slot(account, ~U[2026-10-27 00:00:00Z]) ==
               ~U[2026-10-27 00:30:00Z]
    end

    test "a Tokyo Monday 07:00 slot is Sunday 22:00Z", ctx do
      with_tz(ctx, "Asia/Tokyo")
      account = slots!(ctx, [%{weekday: 1, time: "07:00"}])

      assert Social.next_free_slot(account, ~U[2026-10-25 12:00:00Z]) ==
               ~U[2026-10-25 22:00:00Z]
    end

    test "late on the local Sunday, a Monday 00:15 slot is the next day", ctx do
      with_tz(ctx, "America/Denver")
      account = slots!(ctx, [%{weekday: 1, time: "00:15"}, %{weekday: 7, time: "23:00"}])

      # Sunday 2026-10-25 23:30 MDT = Monday 05:30Z.
      assert Social.next_free_slot(account, ~U[2026-10-26 05:30:00Z]) ==
               ~U[2026-10-26 06:15:00Z]
    end

    test "after the last slot of the local week it wraps to next week's first", ctx do
      account = slots!(ctx, [%{weekday: 1, time: "09:00"}, %{weekday: 5, time: "17:00"}])

      # Saturday in UTC (the default timezone).
      assert Social.next_free_slot(account, ~U[2026-10-31 10:00:00Z]) ==
               ~U[2026-11-02 09:00:00Z]
    end
  end

  describe "DST edges" do
    test "a slot in the spring-forward gap resolves to the first instant after it", ctx do
      with_tz(ctx, "America/Denver")
      # 2026-03-08: 02:00 MST jumps to 03:00 MDT; 02:30 does not exist.
      account = slots!(ctx, [%{weekday: 7, time: "02:30"}])

      assert Social.next_free_slot(account, ~U[2026-03-07 12:00:00Z]) ==
               ~U[2026-03-08 09:00:00Z]
    end

    test "a slot in the fall-back overlap resolves to its first occurrence", ctx do
      with_tz(ctx, "America/Denver")
      # 2026-11-01: 01:30 happens at 07:30Z (MDT) and again at 08:30Z (MST).
      account = slots!(ctx, [%{weekday: 7, time: "01:30"}])

      assert Social.next_free_slot(account, ~U[2026-10-31 12:00:00Z]) ==
               ~U[2026-11-01 07:30:00Z]
    end
  end

  describe "slots_in_week/2" do
    test "lists each live account's slots in the local week, in UTC, with taken?", ctx do
      profile = with_tz(ctx, "America/Denver")
      account = slots!(ctx, [%{weekday: 1, time: "09:00"}, %{weekday: 3, time: "12:00"}])
      {:ok, archived} = Social.create_account(ctx.org_id, profile, %{platform: "linkedin"})

      {:ok, archived} =
        Social.update_account_schedule(ctx.org_id, archived, %{
          posting_slots: [%{weekday: 2, time: "10:00"}]
        })

      {:ok, _} = Social.archive_account(ctx.org_id, archived)
      post!(ctx, ~U[2026-11-04 19:00:00Z], "scheduled")

      # Any date in the week works (here the Wednesday of 2026-11-02's week).
      week = Social.slots_in_week(profile, ~D[2026-11-04])

      assert Enum.map(week, &{&1.account_id, &1.weekday, &1.time, &1.at, &1.taken?}) == [
               {account.id, 1, "09:00", ~U[2026-11-02 16:00:00Z], false},
               {account.id, 3, "12:00", ~U[2026-11-04 19:00:00Z], true}
             ]
    end

    test "the week across the change uses each day's own offset", ctx do
      profile = with_tz(ctx, "America/Denver")
      slots!(ctx, [%{weekday: 6, time: "09:00"}, %{weekday: 7, time: "09:00"}])

      assert Enum.map(Slots.slots_in_week(profile, ~D[2026-10-26]), & &1.at) == [
               ~U[2026-10-31 15:00:00Z],
               ~U[2026-11-01 16:00:00Z]
             ]
    end
  end

  test "the calendar clock places the same instants as slots_in_week/2", ctx do
    profile = with_tz(ctx, "America/Denver")

    account =
      slots!(ctx, [
        %{weekday: 6, time: "09:00"},
        %{weekday: 7, time: "01:30"},
        %{weekday: 1, time: "18:30"}
      ])

    for monday <- [~D[2026-10-26], ~D[2026-03-02], ~D[2026-03-09]] do
      # The clock draws in UTC, so its UTC week can take slots from the
      # neighbouring local weeks; gather those and compare on the UTC week.
      {from, to} = PlatformWeb.SocialCalendarClock.week_bounds(monday, "Etc/UTC")

      ours =
        [-7, 0, 7]
        |> Enum.flat_map(&Social.slots_in_week(profile, Date.add(monday, &1)))
        |> Enum.map(& &1.at)
        |> Enum.filter(&(DateTime.compare(&1, from) != :lt and DateTime.compare(&1, to) == :lt))
        |> Enum.sort(DateTime)

      clock =
        account
        |> PlatformWeb.SocialCalendarClock.slots_in_week("America/Denver", monday, "Etc/UTC")
        |> Enum.map(fn %{date: d, time: t} ->
          DateTime.new!(d, Time.from_iso8601!(t <> ":00"), "Etc/UTC")
        end)
        |> Enum.sort(DateTime)

      assert clock == ours
      assert ours != []
    end
  end

  describe "schedule changeset" do
    test "dedupes and sorts slots, and validates weekday, time and goal", ctx do
      account =
        slots!(
          ctx,
          [
            %{weekday: 5, time: "17:00"},
            %{weekday: 1, time: "09:00"},
            %{"weekday" => "5", "time" => "17:00"}
          ],
          3
        )

      assert Enum.map(account.posting_slots, &{&1.weekday, &1.time}) == [
               {1, "09:00"},
               {5, "17:00"}
             ]

      assert Repo.get!(Account, account.id).weekly_goal == 3

      for bad <- [
            %{weekday: 8, time: "09:00"},
            %{weekday: 1, time: "24:00"},
            %{weekday: 1, time: "9:00"}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Social.update_account_schedule(ctx.org_id, account, %{posting_slots: [bad]})
      end

      assert {:error, changeset} =
               Social.update_account_schedule(ctx.org_id, account, %{weekly_goal: 0})

      assert errors_on(changeset).weekly_goal != []
    end

    test "another org cannot write an account's schedule", ctx do
      assert {:error, :not_found} =
               Social.update_account_schedule(org_id!(), ctx.account, %{
                 posting_slots: [%{weekday: 1, time: "09:00"}]
               })
    end
  end
end
