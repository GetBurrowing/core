defmodule Platform.Social.QueueFeedTest do
  @moduledoc """
  Social authoring 5/11 (task 01a16c50): what the Queue reads
  (`QueueFeed`), the next-slot boundary (`NextSlot`), and the agent's
  `schedule_reason`. `async: false`: the Fake publisher's call log is global.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{NextSlot, Post, QueueFeed, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()
    {:ok, x} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@show_x"})
    Map.merge(ctx, %{x: x, agent_ctx: %{agent_id: ctx.g.id}})
  end

  defp call(tool, args, ctx), do: ToolArguments.dispatch(tool, args, ctx.agent_ctx)

  defp idea!(ctx, title) do
    {:ok, %{idea: idea}} =
      call("social_idea_create", %{"profile_id" => ctx.profile.id, "title" => title}, ctx)

    idea
  end

  defp drafts!(ctx, idea, accounts, attrs \\ %{}) do
    {:ok, %{posts: posts}} =
      call(
        "social_draft_create",
        Map.merge(
          %{
            "profile_id" => ctx.profile.id,
            "account_ids" => Enum.map(accounts, & &1.id),
            "body" => "Out now"
          },
          if(idea, do: Map.put(attrs, "idea_id", idea.id), else: attrs)
        ),
        ctx
      )

    posts
  end

  defp iso(dt), do: DateTime.to_iso8601(dt)

  describe "needs_you/2" do
    test "groups by idea, a post with no idea is its own group, earliest time first, untimed last",
         ctx do
      now = DateTime.utc_now()
      late = idea!(ctx, "Late")
      early = idea!(ctx, "Early")
      untimed = idea!(ctx, "Untimed")

      drafts!(ctx, late, [ctx.a, ctx.x], %{"scheduled_at" => iso(DateTime.add(now, 3, :day))})
      drafts!(ctx, early, [ctx.a], %{"scheduled_at" => iso(DateTime.add(now, 2, :day))})
      # The other version of "early" is the group's earliest.
      drafts!(ctx, early, [ctx.x], %{"scheduled_at" => iso(DateTime.add(now, 1, :day))})
      drafts!(ctx, untimed, [ctx.a, ctx.x])

      [%{id: lone_id}] =
        drafts!(ctx, nil, [ctx.a], %{"scheduled_at" => iso(DateTime.add(now, 5, :day))})

      groups = QueueFeed.needs_you(ctx.h1, {:profile, ctx.profile})

      assert Enum.map(groups, & &1.key) == [early.id, late.id, lone_id, untimed.id]
      assert Enum.map(groups, &length(&1.posts)) == [2, 2, 1, 2]
      assert [%{idea: %{title: "Early"}} | _] = groups
      assert Enum.find(groups, &(&1.key == lone_id)).idea == nil

      # All brands reads the same through list_posts_for_profiles/3.
      assert Enum.map(QueueFeed.needs_you(ctx.h1, :all), & &1.key) ==
               Enum.map(groups, & &1.key)
    end

    test "reads nothing outside the user's orgs", ctx do
      other = approval_fixture()
      pending_post!(other, other.a)
      assert QueueFeed.needs_you(ctx.h1, :all) == []
    end
  end

  describe "NextSlot (4/11's posting slots)" do
    test "is the account's next free slot in the profile's timezone; no slots is nil", ctx do
      [%{id: id}] = drafts!(ctx, nil, [ctx.a])
      post = Repo.get!(Post, id)
      now = ~U[2026-11-01 12:00:00.000000Z]

      assert NextSlot.next_free(ctx.profile, post, now) == nil

      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{timezone: "America/Denver"})

      {:ok, _} =
        Social.update_account_schedule(ctx.org_id, ctx.a, %{
          posting_slots: [%{weekday: 1, time: "09:00"}]
        })

      # Monday 09:00 Denver after the 2026-11-01 change is 16:00Z.
      assert NextSlot.next_free(profile, post, now) == ~U[2026-11-02 16:00:00.000000Z]

      # Another scheduled post on the same account holds that slot.
      {:ok, held} = Social.create_post(ctx.org_id, ctx.a, %{body: "held"})

      Repo.update_all(from(p in Post, where: p.id == ^held.id),
        set: [
          status: "scheduled",
          scheduled_at: ~U[2026-11-02 16:00:00.000000Z],
          approved_by_user_id: ctx.h1.id,
          approved_at: now
        ]
      )

      assert NextSlot.next_free(profile, post, now) == ~U[2026-11-09 16:00:00.000000Z]

      # Another profile's call never answers for this post.
      assert NextSlot.next_free(%{profile | id: Ecto.UUID.generate()}, post, now) == nil
    end
  end

  describe "schedule_reason" do
    test "the agent sets it on create and update, and social_post_list returns it", ctx do
      [%{id: id, schedule_reason: "Mornings do best."}] =
        drafts!(ctx, nil, [ctx.a], %{"schedule_reason" => "Mornings do best."})

      assert {:ok, %{post: %{schedule_reason: "Evenings now."}}} =
               call(
                 "social_draft_update",
                 %{"post_id" => id, "schedule_reason" => "Evenings now."},
                 ctx
               )

      assert Repo.get!(Post, id).schedule_reason == "Evenings now."
    end

    test "more than 280 characters is refused", ctx do
      assert {:error, _} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "account_ids" => [ctx.a.id],
                   "body" => "x",
                   "schedule_reason" => String.duplicate("a", 281)
                 },
                 ctx
               )

      assert Repo.aggregate(Post, :count) == 0
    end
  end
end
