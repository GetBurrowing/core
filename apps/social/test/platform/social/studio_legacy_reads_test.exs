defmodule Platform.Social.StudioLegacyReadsTest do
  @moduledoc """
  Social Studio: every legacy list that feeds a screen, a card or
  a tool result filters to `flow = 'legacy'`. One test per list: a Studio post
  or clip never appears, and a legacy one still does.

  Where a Studio row could not otherwise reach the list's status (`published`,
  `failed`) the boundary CHECK is dropped for that test, so the FILTER is what
  keeps the row out, not the CHECK. Not async: the Fake publisher and the
  dropped CHECK are global to the test's transaction.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Social

  alias Platform.Social.{
    Account,
    ClipClosingVideo,
    ClipLibrary,
    ClipReviewFeed,
    Composer,
    Health,
    Idea,
    Ideas,
    Post,
    QueueFeed,
    Slots
  }

  alias PlatformWeb.SocialCalendar
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    now = DateTime.utc_now()
    %{w: w, now: now, ctx: %{agent_id: w.agent.id}}
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()
  defp group_ids(groups), do: groups |> Enum.flat_map(& &1.posts) |> ids()

  # A legacy post on `account` in `status`, with the columns that status needs.
  defp legacy!(w, account, status, set \\ []) do
    {:ok, post} = Social.create_post(w.org_id, account, %{body: "legacy #{unique()}"})
    approved? = status in ~w(approved scheduled published)

    base =
      [status: status] ++
        if(approved?,
          do: [approved_by_user_id: w.approver.id, approved_at: DateTime.utc_now()],
          else: []
        )

    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: base ++ set)
    Repo.get!(Post, post.id)
  end

  defp studio!(w, account, status, set \\ []) do
    w |> studio_post!(account, status) |> force!(set)
  end

  defp in_days(now, days), do: DateTime.add(now, days * 86_400, :second)

  defp tool(name, args, ctx), do: ToolArguments.dispatch(name, args, ctx)

  # ── post lists ───────────────────────────────────────────────────────

  describe "Social.list_posts/2 (the base of the queue, calendar, tools and task bridge)" do
    test "never returns a Studio post, under any filter; legacy rows still come back", %{w: w} do
      legacy = legacy!(w, w.x, "needs_approval")
      studio = studio!(w, w.tiktok, "needs_approval")

      assert ids(Social.list_posts(w.org_id)) == [legacy.id]
      assert ids(Social.list_posts(w.org_id, profile_id: w.profile.id)) == [legacy.id]
      assert ids(Social.list_posts(w.org_id, status: "needs_approval")) == [legacy.id]
      assert ids(Social.list_posts(w.org_id, account_id: w.tiktok.id)) == []
      assert ids(Social.list_posts(w.org_id, profile_ids: [w.profile.id])) == [legacy.id]
      refute studio.id in ids(Social.list_posts(w.org_id, statuses: Post.studio_statuses()))
    end

    test "the task filter (task bridge) skips a Studio post that carries a task", %{w: w} do
      task = task!(w.org_id)
      legacy = legacy!(w, w.x, "draft", task_id: task.id)
      studio!(w, w.tiktok, "needs_approval", task_id: task.id)

      assert ids(Social.list_posts(w.org_id, task_id: task.id)) == [legacy.id]
    end

    test "the Studio flow is reachable only by asking for it", %{w: w} do
      legacy = legacy!(w, w.x, "needs_approval")
      studio = studio!(w, w.tiktok, "needs_approval")

      assert ids(Social.list_posts(w.org_id, flow: "studio")) == [studio.id]
      assert ids(Social.list_posts(w.org_id, flow: "legacy")) == [legacy.id]
    end
  end

  describe "Social.list_posts_for_profiles/3 (All brands)" do
    test "never returns a Studio post", %{w: w} do
      legacy = legacy!(w, w.x, "needs_approval")
      studio!(w, w.tiktok, "needs_approval")

      assert ids(Social.list_posts_for_profiles(w.approver, :all)) == [legacy.id]
    end
  end

  describe "Social.needs_approval_counts/1 (the nav badge)" do
    test "counts only legacy needs_approval posts", %{w: w} do
      legacy!(w, w.x, "needs_approval")
      studio!(w, w.tiktok, "needs_approval")
      studio!(w, w.tiktok, "needs_approval")

      assert Social.needs_approval_counts([w.profile.id]) == %{w.profile.id => 1}
    end
  end

  describe "QueueFeed" do
    test "needs_you lists a legacy post and never a Studio one, per profile and All brands", %{
      w: w
    } do
      legacy = legacy!(w, w.x, "needs_approval")
      studio = studio!(w, w.tiktok, "needs_approval")

      for scope <- [{:profile, w.profile}, :all] do
        groups = QueueFeed.needs_you(w.approver, scope)
        assert group_ids(groups) == [legacy.id]
        refute studio.id in group_ids(groups)
      end
    end

    test "scheduled lists a legacy approved post and never an approved or planned Studio one",
         %{w: w, now: now} do
      legacy = legacy!(w, w.x, "approved", scheduled_at: in_days(now, 1))
      approved = studio!(w, w.tiktok, "approved", scheduled_at: in_days(now, 1))
      planned = studio!(w, w.tiktok, "planned", scheduled_at: in_days(now, 2))

      for scope <- [{:profile, w.profile}, :all] do
        found = group_ids(QueueFeed.scheduled(w.approver, scope, now))
        assert found == [legacy.id]
        refute approved.id in found or planned.id in found
      end
    end

    test "failed (refused before the vendor, and vendor-failed) never lists a Studio post", %{
      w: w,
      now: now
    } do
      drop_boundary_check!()

      refused = legacy!(w, w.x, "approved", refused_reason: "media_rejected", refused_at: now)
      failed = legacy!(w, w.x, "failed", error: "boom")

      studio_refused =
        studio!(w, w.tiktok, "approved", refused_reason: "media_rejected", refused_at: now)

      studio_failed = w |> studio!(w.tiktok, "approved") |> forge_sent!("failed", nil)

      for scope <- [{:profile, w.profile}, :all] do
        found = ids(QueueFeed.failed(w.approver, scope, now))
        assert found == Enum.sort([refused.id, failed.id])
        refute studio_refused.id in found or studio_failed.id in found
      end
    end

    test "published never lists a Studio post", %{w: w, now: now} do
      drop_boundary_check!()

      legacy = legacy!(w, w.x, "published", published_at: now)
      studio = w |> studio!(w.tiktok, "approved") |> forge_sent!("published")
      Repo.update_all(from(p in Post, where: p.id == ^studio.id), set: [published_at: now])

      for scope <- [{:profile, w.profile}, :all] do
        found = ids(QueueFeed.published(w.approver, scope, now))
        assert found == [legacy.id]
      end
    end
  end

  describe "the Calendar tab" do
    test "items/5 and items_for_user/5 place a legacy post and never a Studio one", %{
      w: w,
      now: now
    } do
      zone = "Etc/UTC"
      monday = SocialCalendar.week_start(Date.utc_today())
      at = DateTime.new!(Date.add(monday, 2), ~T[10:00:00.000000], "Etc/UTC")

      legacy = legacy!(w, w.x, "approved", scheduled_at: at)
      studio = studio!(w, w.tiktok, "approved", scheduled_at: at)
      studio_waiting = studio!(w, w.tiktok, "needs_approval", scheduled_at: at)
      _ = now

      accounts = Repo.all(from(a in Account, where: a.profile_id == ^w.profile.id))

      for items <- [
            SocialCalendar.items(w.profile, accounts, monday, zone),
            SocialCalendar.items_for_user(w.approver, accounts, monday, zone)
          ] do
        found = Enum.map(items, & &1.post.id)
        assert legacy.id in found
        refute studio.id in found or studio_waiting.id in found
      end
    end
  end

  describe "agent tool results" do
    test "social_post_list returns a legacy post and never a Studio one", %{w: w, ctx: ctx} do
      legacy = legacy!(w, w.x, "needs_approval")
      studio = studio!(w, w.tiktok, "needs_approval")

      assert {:ok, %{posts: posts, total: total}} =
               tool("social_post_list", %{"profile_id" => w.profile.id}, ctx)

      assert Enum.map(posts, & &1.id) == [legacy.id]
      assert total == 1
      refute studio.id in Enum.map(posts, & &1.id)
    end

    test "social_idea_list derives the stage from legacy posts only", %{w: w, ctx: ctx} do
      idea = idea!(w)
      studio!(w, w.tiktok, "needs_approval", idea_id: idea.id)

      assert {:ok, %{ideas: [row]}} =
               tool("social_idea_list", %{"profile_id" => w.profile.id}, ctx)

      assert row.id == idea.id
      assert row.posts == []

      legacy = legacy!(w, w.x, "needs_approval", idea_id: idea.id)

      assert {:ok, %{ideas: [row]}} =
               tool("social_idea_list", %{"profile_id" => w.profile.id}, ctx)

      assert Enum.map(row.posts, & &1.id) == [legacy.id]
    end

    test "social_clip_list returns a legacy clip and never a Studio one", %{w: w, ctx: ctx} do
      legacy = pending_clip!(w)
      studio = w |> pending_clip!() |> make_studio_clip!()

      assert {:ok, %{clips: clips}} =
               tool("social_clip_list", %{"profile_id" => w.profile.id}, ctx)

      assert Enum.map(clips, & &1.id) == [legacy.id]
      refute studio.id in Enum.map(clips, & &1.id)
    end
  end

  describe "ideas" do
    test "Ideas.posts/1 and posts_by_idea/1 (idea cards and board) skip Studio posts", %{w: w} do
      idea = idea!(w)
      legacy = legacy!(w, w.x, "needs_approval", idea_id: idea.id)
      studio!(w, w.tiktok, "needs_approval", idea_id: idea.id)

      assert ids(Ideas.posts(idea)) == [legacy.id]
      assert ids(Map.fetch!(Ideas.posts_by_idea([idea.id]), idea.id)) == [legacy.id]
    end
  end

  describe "Connections health" do
    test "an approved Studio post with a refusal never counts as a failure", %{w: w, now: now} do
      legacy = legacy!(w, w.x, "approved", refused_reason: "media_rejected", refused_at: now)

      studio =
        studio!(w, w.tiktok, "approved", refused_reason: "media_rejected", refused_at: now)

      facts = Health.facts([w.x, w.tiktok], now)
      assert Enum.map(facts[w.x.id].failures, & &1.id) == [legacy.id]
      assert facts[w.tiktok.id].failures == []
      refute studio.id in Enum.map(facts[w.tiktok.id].failures, & &1.id)
    end
  end

  describe "composer repeat check and slot picker" do
    test "recent_bodies reads legacy posts only", %{w: w} do
      legacy = legacy!(w, w.x, "draft")
      studio!(w, w.tiktok, "needs_approval", body: "STUDIO-ONLY-BODY")

      assert Composer.recent_bodies(w.profile) == [legacy.body]
    end

    test "next_free ignores a Studio post sitting on a slot", %{w: w, now: now} do
      {:ok, account} =
        Social.update_account_schedule(w.org_id, w.x, %{
          posting_slots: [%{weekday: Date.day_of_week(now), time: "23:59"}]
        })

      slot = Slots.next_free(account, now)
      assert %DateTime{} = slot
      usec_slot = %{slot | microsecond: {0, 6}}

      # A Studio approved post (scheduled_at carried over) sits on the slot...
      studio!(w, account, "approved", scheduled_at: usec_slot)
      assert Slots.next_free(account, now) == slot

      # ... a legacy one takes it.
      legacy!(w, account, "approved", scheduled_at: usec_slot)
      assert Slots.next_free(account, now) != slot
    end
  end

  # ── clip lists ───────────────────────────────────────────────────────

  describe "clip lists" do
    test "Social.list_clips/2 (tool, composer and closing-video loaders) skips Studio clips", %{
      w: w
    } do
      legacy = pending_clip!(w)
      studio = w |> pending_clip!() |> make_studio_clip!()

      assert ids(Social.list_clips(w.org_id)) == [legacy.id]
      assert ids(Social.list_clips(w.org_id, profile_id: w.profile.id)) == [legacy.id]
      assert ids(Social.list_clips(w.org_id, flow: "studio")) == [studio.id]
    end

    test "the review queue and its counts skip Studio clips", %{w: w} do
      legacy = pending_clip!(w)
      studio = w |> pending_clip!() |> make_studio_clip!()

      assert ids(ClipReviewFeed.review_queue(w.org_id, w.profile.id)) == [legacy.id]
      assert ClipReviewFeed.pending_count(w.org_id, w.profile.id) == 1
      assert QueueFeed.clips_waiting(w.approver, {:profile, w.profile}) == 1
      assert QueueFeed.clips_waiting(w.approver, :all) == 1
      refute studio.id in ids(ClipReviewFeed.review_queue(w.org_id, w.profile.id))
    end

    test "the render strip skips jobs of Studio clips", %{w: w} do
      legacy = pending_clip!(w)
      studio = w |> pending_clip!() |> make_studio_clip!()
      legacy_job = open_job!(w, legacy)
      _studio_job = open_job!(w, studio)

      assert [row] = ClipReviewFeed.rendering(w.org_id, w.profile.id)
      assert row.id == legacy_job.id
    end

    test "the clip library skips Studio clips", %{w: w, now: now} do
      legacy = pending_clip!(w)
      studio = w |> pending_clip!() |> make_studio_clip!()

      %{items: items, total: total} = ClipLibrary.list(w.org_id, %{}, now: now)
      assert Enum.map(items, & &1.clip.id) == [legacy.id]
      assert total == 1
      refute studio.id in Enum.map(items, & &1.clip.id)
    end

    test "the closing-video review list skips Studio clips", %{w: w} do
      legacy = pending_clip!(w)
      studio = w |> pending_clip!() |> make_studio_clip!()

      clip_ids =
        w.profile |> ClipClosingVideo.review_renders() |> Enum.map(fn {c, _r} -> c.id end)

      assert legacy.id in clip_ids
      refute studio.id in clip_ids
    end
  end

  # ── fixtures local to this file ──────────────────────────────────────

  defp idea!(w) do
    Repo.insert!(%Idea{
      org_id: w.org_id,
      profile_id: w.profile.id,
      title: "Idea #{unique()}",
      source_kind: "human"
    })
  end

  defp open_job!(w, clip) do
    Repo.insert!(%Platform.Social.ClipJob{
      profile_id: w.profile.id,
      clip_id: clip.id,
      kind: "rerender",
      status: "queued",
      payload: %{}
    })
  end
end
