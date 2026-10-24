defmodule Platform.Social.IdeasTest do
  @moduledoc """
  Social authoring 2/11 (task 01a16c4e): ideas as a record, the derived
  stage, the agent-vs-human change log, revise-with-note, and the agent
  tools for them. Agent paths go through `ToolArguments.dispatch/3`, the door
  both federation transports use. `async: false`: the Fake publisher's call
  log is global.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Chat.Message
  alias Platform.Federation.ToolArguments
  alias Platform.Social
  alias Platform.Social.{Approvals, Idea, Ideas, Post, PostEvent, PostEvents, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()

    {:ok, x} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@show_x"})

    {:ok, ig} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram", handle: "@show_ig"})

    Map.merge(ctx, %{x: x, ig: ig, agent_ctx: %{agent_id: ctx.g.id}})
  end

  defp call(tool, args, agent_ctx), do: ToolArguments.dispatch(tool, args, agent_ctx)

  defp create_idea!(ctx, title \\ "Episode 12 launch") do
    {:ok, %{idea: idea}} =
      call(
        "social_idea_create",
        %{"profile_id" => ctx.profile.id, "title" => title, "brief" => "Announce it"},
        ctx.agent_ctx
      )

    idea
  end

  defp three_drafts!(ctx, idea) do
    {:ok, %{posts: posts, count: 3}} =
      call(
        "social_draft_create",
        %{
          "profile_id" => ctx.profile.id,
          "idea_id" => idea.id,
          "account_ids" => [ctx.a.id, ctx.x.id, ctx.ig.id],
          "body" => "Episode 12 is out",
          "status" => "draft"
        },
        ctx.agent_ctx
      )

    posts
  end

  defp list_idea(ctx, idea_id) do
    {:ok, %{ideas: ideas}} =
      call("social_idea_list", %{"profile_id" => ctx.profile.id}, ctx.agent_ctx)

    Enum.find(ideas, &(&1.id == idea_id))
  end

  defp submit!(ctx, post_id) do
    {:ok, %{post: post}} =
      call(
        "social_draft_update",
        %{"post_id" => post_id, "status" => "needs_approval"},
        ctx.agent_ctx
      )

    post
  end

  defp events(post_id), do: PostEvents.list_for_post(post_id)

  describe "an agent's idea and its drafts" do
    test "three drafts (LinkedIn, X, Instagram) share the idea; one submitted is in_review",
         ctx do
      idea = create_idea!(ctx)
      assert idea.stage == "inbox"
      assert idea.source_kind == "agent"
      assert Repo.get!(Idea, idea.id).created_by_agent_id == ctx.g.id

      posts = three_drafts!(ctx, idea)
      assert Enum.all?(posts, &(&1.idea_id == idea.id))
      assert list_idea(ctx, idea.id).stage == "drafting"

      submit!(ctx, hd(posts).id)

      listed = list_idea(ctx, idea.id)
      assert listed.stage == "in_review"
      assert length(listed.posts) == 3

      assert [%{action: "created", actor_kind: "agent"}, %{action: "submitted"}] =
               Enum.find(listed.posts, &(&1.id == hd(posts).id)).events
    end

    test "social_post_list returns idea_id and each post's events", ctx do
      idea = create_idea!(ctx)
      [p | _] = three_drafts!(ctx, idea)

      {:ok, %{posts: listed}} =
        call("social_post_list", %{"profile_id" => ctx.profile.id}, ctx.agent_ctx)

      row = Enum.find(listed, &(&1.id == p.id))
      assert row.idea_id == idea.id
      assert [%{action: "created", actor_kind: "agent", actor_id: actor}] = row.events
      assert actor == ctx.g.id
    end

    test "an agent edit writes edited with the body before and after", ctx do
      [p | _] = three_drafts!(ctx, create_idea!(ctx))

      {:ok, _} =
        call(
          "social_draft_update",
          %{"post_id" => p.id, "body" => "Episode 12 is live"},
          ctx.agent_ctx
        )

      assert %PostEvent{actor_kind: "agent", actor_id: actor} =
               edit =
               Enum.find(events(p.id), &(&1.action == "edited"))

      assert actor == ctx.g.id
      assert edit.body_before == p.body
      assert edit.body_after =~ "Episode 12 is live"
    end
  end

  describe "idea_id on a draft" do
    test "another org's idea is not_found, exactly like a missing id", ctx do
      org_b = org_id!()

      {:ok, profile_b} =
        Social.create_profile(org_b, %{name: "Other show", space_id: channel!(org_b).id})

      {:ok, other} =
        Ideas.create({:tenant, org_b}, profile_b.id, %{title: "Theirs"}, {:user, user!().id})

      pinned = %{agent_id: pinned_agent!(ctx.org_id).id}
      args = %{"profile_id" => ctx.profile.id, "account_ids" => [ctx.a.id], "body" => "x"}

      assert {:error, %{code: :not_found} = e1} =
               call("social_draft_create", Map.put(args, "idea_id", other.id), pinned)

      assert {:error, %{code: :not_found} = e2} =
               call("social_draft_create", Map.put(args, "idea_id", Ecto.UUID.generate()), pinned)

      assert e1 == e2

      assert {:error, :not_found} =
               Social.AgentDrafts.create_agent_drafts(
                 {:tenant, ctx.org_id},
                 ctx.profile.id,
                 Map.put(args, "idea_id", other.id)
               )
    end

    test "another profile's idea is idea_profile_mismatch and writes nothing", ctx do
      {:ok, profile_2} =
        Social.create_profile(ctx.org_id, %{name: "Second show #{unique()}"})

      {:ok, other} =
        Ideas.create(ctx.org_id, profile_2.id, %{title: "Second"}, {:user, ctx.h1.id})

      before = Repo.aggregate(Post, :count)

      assert {:error, %{code: :idea_profile_mismatch}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "idea_id" => other.id,
                   "account_ids" => [ctx.a.id],
                   "body" => "x"
                 },
                 ctx.agent_ctx
               )

      assert Repo.aggregate(Post, :count) == before
    end
  end

  describe "human decisions write the change log" do
    test "approving one post writes approved with actor_kind human", ctx do
      [p | _] = three_drafts!(ctx, create_idea!(ctx))
      submit!(ctx, p.id)
      card = live_card!(Repo.get!(Post, p.id))
      fp = Approvals.card_view(card.id, {:user, ctx.h1.id}).fingerprint

      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h1, fp)

      assert %PostEvent{actor_kind: "human", actor_id: actor} =
               Enum.find(events(p.id), &(&1.action == "approved"))

      assert actor == ctx.h1.id
      # The Fake schedules; the vendor's outcome is the system's entry.
      refute Enum.any?(events(p.id), &(&1.action == "published"))

      assert {:ok, %Post{status: "published"}} =
               Social.Publishing.apply_outcome(Repo.get!(Post, p.id), %{
                 kind: :published,
                 external_url: "https://example.com/p/1"
               })

      assert Enum.any?(events(p.id), &(&1.action == "published" and &1.actor_kind == "system"))
    end

    test "a human edit then approve logs edited (human, before/after) then approved", ctx do
      [p | _] = three_drafts!(ctx, create_idea!(ctx))
      submit!(ctx, p.id)
      card = live_card!(Repo.get!(Post, p.id))
      fp = Approvals.card_view(card.id, {:user, ctx.h1.id}).fingerprint

      assert {:ok, _} = Approvals.decide_edit(card.canvas_id, ctx.h1, %{body: "Tighter"}, fp)
      fp = Approvals.card_view(card.id, {:user, ctx.h1.id}).fingerprint
      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h1, fp)

      human = Enum.filter(events(p.id), &(&1.actor_kind == "human"))
      assert Enum.map(human, & &1.action) == ["edited", "approved"]
      assert hd(human).body_after == "Tighter"
      assert hd(human).body_before == p.body
    end

    test "a rejection writes rejected with the reason as the note", ctx do
      [p | _] = three_drafts!(ctx, create_idea!(ctx))
      submit!(ctx, p.id)
      card = live_card!(Repo.get!(Post, p.id))

      assert {:ok, _} = Approvals.decide_reject(card.canvas_id, ctx.h1, "Off brand")

      assert %PostEvent{actor_kind: "human", note: "Off brand"} =
               Enum.find(events(p.id), &(&1.action == "rejected"))
    end
  end

  describe "request_revision/4" do
    setup ctx do
      idea = create_idea!(ctx)
      [p | _] = three_drafts!(ctx, idea)
      submit!(ctx, p.id)
      Map.merge(ctx, %{idea: idea, post: Repo.get!(Post, p.id)})
    end

    defp revision_messages(space_id) do
      Repo.all(
        from(m in Message,
          where: m.space_id == ^space_id and fragment("? \\? 'social_revision'", m.metadata)
        )
      )
    end

    test "a non-approver, an agent and a blank note are refused, writing nothing", ctx do
      assert {:error, :not_an_approver} =
               Ideas.request_revision(ctx.org_id, ctx.post.id, ctx.n.id, "Shorter")

      assert {:error, :not_a_human} =
               Ideas.request_revision(ctx.org_id, ctx.post.id, ctx.g.id, "Shorter")

      assert {:error, :note_required} =
               Ideas.request_revision(ctx.org_id, ctx.post.id, ctx.h1.id, "  ")

      assert {:error, :note_too_long} =
               Ideas.request_revision(
                 ctx.org_id,
                 ctx.post.id,
                 ctx.h1.id,
                 String.duplicate("a", 2_001)
               )

      assert {:error, :not_found} =
               Ideas.request_revision(org_id!(), ctx.post.id, ctx.h1.id, "Shorter")

      refute Enum.any?(events(ctx.post.id), &(&1.action == "revision_requested"))
      assert revision_messages(ctx.space.id) == []
      assert list_idea(ctx, ctx.idea.id).open_revisions == []
    end

    test "an approver's note reaches the tool and a message names the agent", ctx do
      assert {:ok, %{post: post, message: message}} =
               Ideas.request_revision(ctx.org_id, ctx.post.id, ctx.h1.id, " Make it shorter ")

      assert post.status == "needs_approval"
      assert Repo.get!(Post, ctx.post.id).status == "needs_approval"

      assert [%{post_id: post_id, note: "Make it shorter", requested_by_user_id: by}] =
               list_idea(ctx, ctx.idea.id).open_revisions

      assert {post_id, by} == {ctx.post.id, ctx.h1.id}

      assert [%Message{id: id, content: content}] = revision_messages(ctx.space.id)
      assert id == message.id
      assert content =~ "@[#{ctx.g.name}]"
      assert content =~ "Make it shorter"

      card = live_card!(post)
      assert Approvals.card_view(card.id, {:user, ctx.h1.id}).status.text == "Revision asked"

      # The agent's revision closes the note; the card is back to waiting.
      {:ok, _} =
        call("social_draft_update", %{"post_id" => post.id, "body" => "Short"}, ctx.agent_ctx)

      assert list_idea(ctx, ctx.idea.id).open_revisions == []
      assert Approvals.card_view(card.id, {:user, ctx.h1.id}).status.text == "Needs approval"
    end

    test "a post not waiting for approval is refused", ctx do
      [_, draft | _] = Ideas.posts(Repo.get!(Idea, ctx.idea.id))

      assert {:error, :not_needs_approval} =
               Ideas.request_revision(ctx.org_id, draft.id, ctx.h1.id, "Shorter")
    end
  end

  describe "stage/1" do
    defp posts(statuses), do: Enum.map(statuses, &%Post{status: &1})

    test "is derived from the posts" do
      assert Ideas.stage([]) == "inbox"
      assert Ideas.stage(posts(~w(draft draft))) == "drafting"
      assert Ideas.stage(posts(~w(draft needs_approval published))) == "in_review"
      assert Ideas.stage(posts(~w(approved published draft))) == "scheduled"
      assert Ideas.stage(posts(~w(scheduled failed))) == "scheduled"
      assert Ideas.stage(posts(~w(published failed))) == "live"
      assert Ideas.stage(posts(~w(failed failed))) == "failed"
      assert Ideas.stage(posts(~w(draft failed))) == "drafting"
    end
  end

  describe "ideas are org-scoped" do
    test "get/list/archive see nothing of another org", ctx do
      idea = create_idea!(ctx)
      other = {:tenant, org_id!()}

      assert Ideas.get(other, idea.id) == nil
      assert Ideas.list(other, ctx.profile.id) == []
      assert {:error, :not_found} = Ideas.archive(other, idea.id)

      assert {:ok, %Idea{archived_at: %DateTime{}}} = Ideas.archive(ctx.org_id, idea.id)
      assert Ideas.list(ctx.org_id, ctx.profile.id) == []
      assert [_] = Ideas.list(ctx.org_id, ctx.profile.id, archived: true)

      assert {:error, %{code: :idea_archived}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "idea_id" => idea.id,
                   "account_ids" => [ctx.a.id],
                   "body" => "x"
                 },
                 ctx.agent_ctx
               )
    end

    test "a ref outside the profile's org is refused", ctx do
      task = task!(org_id!())

      assert {:error, %{code: :invalid_argument, errors: %{task_id: _}}} =
               call(
                 "social_idea_create",
                 %{"profile_id" => ctx.profile.id, "title" => "T", "task_id" => task.id},
                 ctx.agent_ctx
               )
    end
  end
end
