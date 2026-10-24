defmodule Platform.Social.ApprovalsTest do
  @moduledoc """
  The approval context (Social 3/7 stage 2), against real users and agents
  rows and the Fake publisher. `async: false`: the Fake's call log is a
  global table, and the race cases run concurrent processes on the shared
  sandbox connection.

  Every refusal asserts the post row, the card row and `Fake.calls(:publish)`
  are unchanged: a refusal that still wrote or published is the defect.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Inbox.Item
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ApprovalCard, Approvals, Post, Profile, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    approval_fixture()
  end

  defp items(user, post) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user.id and i.source_id == ^post.id and i.kind == "social_post_approval"
      )
    )
  end

  defp live_items(user, post), do: Enum.filter(items(user, post), &is_nil(&1.dismissed_at))

  defp shown(card, user), do: Approvals.card_view(card.id, {:user, user.id}).fingerprint

  defp assert_untouched(post, card, before_post, before_card) do
    assert row_snapshot(post) == before_post
    assert card_snapshot(card) == before_card
    assert Fake.calls(:publish) == []
  end

  describe "fan-out when a post needs approval" do
    test "one pointer row per approver, none for N, no preview in the inbox", ctx do
      file = media_file!(ctx.org_id, "image/png")
      {post, card} = pending_post!(ctx, ctx.a, %{media_file_ids: [file.id]})

      for user <- [ctx.h1, ctx.h2] do
        assert [item] = items(user, post)
        assert item.title == "Post for #{ctx.profile.name} needs your approval"
        assert item.body == "LINKEDIN · not scheduled"
        refute item.title =~ "Episode 12"
        refute (item.body || "") =~ "Episode 12"

        for text <- [item.title, item.body, item.url] do
          refute text =~ file.id
          refute text =~ "/files/"
        end

        # Social authoring 5/11: the row (and its push) opens the Queue on
        # this post's idea, where the same decide_* run.
        assert item.url ==
                 "/m/social?profile=#{ctx.profile.id}&tab=queue&idea=#{post.id}"

        assert item.url == Approvals.queue_url(post, ctx.profile)
        refute item.url =~ card.message_id
      end

      assert items(ctx.n, post) == []
    end

    test "the canvas document holds only a social_post_card node with card_id and rev", ctx do
      {_post, card} = pending_post!(ctx, ctx.a)
      canvas = Platform.Chat.get_canvas(card.canvas_id)

      assert %{"type" => "social_post_card", "props" => props, "children" => []} =
               canvas.document["root"]

      assert props == %{"card_id" => card.id, "rev" => 1}
      refute inspect(canvas.document) =~ "Episode 12"
      assert card.card_digest == Approvals.digest(canvas.document)
    end

    test "an agent re-edit re-renders the live card instead of posting a second", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      scope = {:tenant, ctx.org_id}

      assert {:ok, _} = AgentDrafts.update_agent_draft(scope, post.id, %{"body" => "Take two"})

      assert [only] = Repo.all(from(c in ApprovalCard, where: c.post_id == ^post.id))
      assert only.id == card.id
      assert only.card_digest != card.card_digest
      assert length(items(ctx.h1, post)) == 1
    end

    test "no channel: needs_approval is refused on every path and the row is unchanged", ctx do
      {:ok, bare} = Social.create_profile(ctx.org_id, %{name: "No channel"})
      {:ok, acct} = Social.create_account(ctx.org_id, bare, %{platform: "x"})

      assert {:error, :profile_has_no_channel} =
               Social.create_post(ctx.org_id, acct, %{body: "x", status: "needs_approval"})

      {:ok, draft} = Social.create_post(ctx.org_id, acct, %{body: "x"})

      assert {:error, :profile_has_no_channel} =
               Social.update_post(ctx.org_id, draft, %{status: "needs_approval"})

      assert Repo.get!(Post, draft.id).status == "draft"

      scope = {:tenant, ctx.org_id}

      assert {:error, :profile_has_no_channel} =
               AgentDrafts.create_agent_drafts(scope, bare.id, %{
                 "account_ids" => [acct.id],
                 "body" => "x"
               })

      assert {:error, :profile_has_no_channel} =
               AgentDrafts.update_agent_draft(scope, draft.id, %{"status" => "needs_approval"})

      assert Repo.get!(Post, draft.id).status == "draft"
      assert Repo.aggregate(from(p in Post, where: p.account_id == ^acct.id), :count) == 1
    end

    test "an approver who cannot see the channel gets no row and is not added to it" do
      ctx = approval_fixture(space_attrs: %{kind: "group"})
      outsider = named_user!("Olga Outside")
      member!(outsider, ctx.org_id)
      make_approver!(ctx.org_id, ctx.profile, outsider)
      profile = Repo.get!(Profile, ctx.profile.id)

      # Inserted without the hook, so this call's own return is observed.
      post = Repo.insert!(%Post{account_id: ctx.a.id, body: "x", status: "needs_approval"})

      assert {:ok, %{unreachable_approvers: [id]}} = Approvals.request_approval(post)
      assert id == outsider.id
      assert items(outsider, post) == []
      assert length(items(ctx.h1, post)) == 1
      refute Platform.Chat.participant?(ctx.space.id, outsider.id)
      assert outsider.id in profile.approver_user_ids
    end
  end

  describe "decide_approve" do
    test "the happy path publishes once through the Fake and resolves every approver", ctx do
      {post, card} = pending_post!(ctx, ctx.a)

      assert {:ok, %{post: published}} =
               Approvals.decide_approve(card.canvas_id, ctx.h1, shown(card, ctx.h1))

      assert published.status == "scheduled"
      assert published.approved_by_user_id == ctx.h1.id
      assert %DateTime{} = published.approved_at
      assert published.external_id == "fake_" <> post.id
      assert [{:publish, [_account, request], _}] = Fake.calls(:publish)
      assert request.body == post.body

      decided = Repo.get!(ApprovalCard, card.id)

      assert {decided.state, decided.decision, decided.decided_by_user_id} ==
               {"decided", "approve", ctx.h1.id}

      assert live_items(ctx.h1, post) == []
      assert live_items(ctx.h2, post) == []

      view = Approvals.card_view(card.id, {:user, ctx.h2.id})
      assert view.status.text =~ "Approved by Hana One"
      assert view.actions == []
    end

    test "a second decision is already_decided and never publishes twice", ctx do
      {_post, card} = pending_post!(ctx, ctx.a)
      fp = shown(card, ctx.h1)
      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h1, fp)
      assert {:error, :already_decided} = Approvals.decide_approve(card.canvas_id, ctx.h2, fp)
      assert {:error, :already_decided} = Approvals.decide_reject(card.canvas_id, ctx.h2, "no")
      assert length(Fake.calls(:publish)) == 1
    end

    test "two processes racing on one card: exactly one :ok, one :already_decided, one publish",
         ctx do
      {post, card} = pending_post!(ctx, ctx.a)

      results =
        [ctx.h1, ctx.h2]
        |> Enum.map(fn user ->
          Task.async(fn -> Approvals.decide_approve(card.canvas_id, user) end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_decided})) == 1
      assert length(Fake.calls(:publish)) == 1
      assert Repo.get!(Post, post.id).approved_by_user_id in [ctx.h1.id, ctx.h2.id]
    end

    test "an agent edit committed while a human's approve is pending is refused as :post_changed",
         ctx do
      # The approval race the 4/7 reviewer proved: the human was shown one
      # text; an agent rewrote it under the row lock while the click was in
      # flight. Two processes: the editor holds its transaction open, the
      # approver starts and must wait, then sees the new row.
      {post, card} = pending_post!(ctx, ctx.a)
      fp = shown(card, ctx.h1)
      parent = self()

      editor =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(p in Post, where: p.id == ^post.id, lock: "FOR UPDATE"))

            Repo.update_all(from(p in Post, where: p.id == ^post.id),
              set: [body: "Agent rewrote this after the human looked"]
            )

            send(parent, :editing)

            receive do
              :commit -> :ok
            after
              5_000 -> :ok
            end
          end)
        end)

      assert_receive :editing, 5_000
      approver = Task.async(fn -> Approvals.decide_approve(card.canvas_id, ctx.h1, fp) end)
      assert Task.yield(approver, 300) == nil
      send(editor.pid, :commit)
      Task.await(editor)

      assert {:error, :post_changed} = Task.await(approver, 15_000)
      assert Fake.calls(:publish) == []
      row = Repo.get!(Post, post.id)
      assert row.status == "needs_approval"
      assert row.approved_by_user_id == nil
      assert Repo.get!(ApprovalCard, card.id).state == "pending"
    end

    test "an agent edit through AgentDrafts before the click is :post_changed too", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      fp = shown(card, ctx.h1)

      {:ok, _} =
        AgentDrafts.update_agent_draft({:tenant, ctx.org_id}, post.id, %{"body" => "Rewritten"})

      assert {:error, :post_changed} = Approvals.decide_approve(card.canvas_id, ctx.h1, fp)
      assert Fake.calls(:publish) == []
      assert Repo.get!(Post, post.id).status == "needs_approval"

      # Re-rendered, the human sees the new text and can approve it.
      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h1, shown(card, ctx.h1))
    end

    test "an agent is refused :not_a_human, even when wrongly on the list", ctx do
      Repo.update_all(from(p in Profile, where: p.id == ^ctx.profile.id),
        set: [approver_user_ids: [ctx.h1.id, ctx.h2.id, ctx.g.id]]
      )

      {post, card} = pending_post!(ctx, ctx.a)
      {bp, bc} = {row_snapshot(post), card_snapshot(card)}

      assert {:error, :not_a_human} = Approvals.decide_approve(card.canvas_id, ctx.g)
      assert {:error, cs} = Social.approve_post(ctx.org_id, post, ctx.g.id)
      assert errors_on(cs)[:approved_by_user_id] == ["must be a human user"]
      assert_untouched(post, card, bp, bc)

      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h1)
    end

    test "a human not on the list is refused :not_an_approver", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      {bp, bc} = {row_snapshot(post), card_snapshot(card)}

      assert {:error, :not_an_approver} = Approvals.decide_approve(card.canvas_id, ctx.n)
      assert {:error, :not_an_approver} = Social.approve_post(ctx.org_id, post, ctx.n.id)
      assert_untouched(post, card, bp, bc)
    end

    test "an archived approver is refused :approver_archived", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      {:ok, _} = Platform.Accounts.archive_user(ctx.h1)
      {bp, bc} = {row_snapshot(post), card_snapshot(card)}

      assert {:error, :approver_archived} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert {:error, :approver_archived} = Social.approve_post(ctx.org_id, post, ctx.h1.id)
      assert_untouched(post, card, bp, bc)

      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h2)
    end

    test "an approver whose org membership was removed is refused :approver_no_access", ctx do
      {post, card} = pending_post!(ctx, ctx.a)

      Repo.delete_all(
        from(m in Platform.Tenancy.OrgMembership,
          where: m.user_id == ^ctx.h1.id and m.org_id == ^ctx.org_id
        )
      )

      {bp, bc} = {row_snapshot(post), card_snapshot(card)}
      assert {:error, :approver_no_access} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert {:error, :approver_no_access} = Social.approve_post(ctx.org_id, post, ctx.h1.id)
      assert_untouched(post, card, bp, bc)
    end

    test "a draft_only account is refused :draft_only and never publishes", ctx do
      {post, card} = pending_post!(ctx, ctx.d)
      {bp, bc} = {row_snapshot(post), card_snapshot(card)}

      assert {:error, :draft_only} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert_untouched(post, card, bp, bc)
      assert Approvals.card_view(card.id, {:user, ctx.h1.id}).actions == [:copy, :edit, :reject]
    end

    test "an agent's canvas_patch of the real card makes it :card_changed", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      canvas = Platform.Chat.get_canvas(card.canvas_id)

      assert {:ok, _} =
               Platform.Chat.patch_canvas({:agent, ctx.g.id}, canvas, [
                 {:set_props, "root", %{"rev" => 99}}
               ])

      {bp, bc} = {row_snapshot(post), card_snapshot(card)}
      assert {:error, :card_changed} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert_untouched(post, card, bp, bc)
    end

    test "a lookalike canvas pointing at a real card_id is :not_a_social_card", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      agent_participant = Platform.Chat.get_agent_participant(ctx.space.id, ctx.g.id)

      {:ok, lookalike, _msg} =
        Platform.Chat.create_canvas_with_message(ctx.space.id, agent_participant.id, %{
          title: "Post approval",
          document: Approvals.card_document(card.id, 1)
        })

      {bp, bc} = {row_snapshot(post), card_snapshot(card)}
      assert {:error, :not_a_social_card} = Approvals.decide_approve(lookalike.id, ctx.h1)
      assert_untouched(post, card, bp, bc)
    end
  end

  describe "decide_reject and decide_edit" do
    test "reject keeps the reason, leaves the post a draft, dismisses every row", ctx do
      {post, card} = pending_post!(ctx, ctx.a)

      assert {:error, :reason_required} = Approvals.decide_reject(card.canvas_id, ctx.h1, "  ")
      assert Repo.get!(ApprovalCard, card.id).state == "pending"

      assert {:ok, %{post: rejected}} =
               Approvals.decide_reject(card.canvas_id, ctx.h1, "Too salesy, cut the last line")

      assert rejected.status == "draft"
      assert rejected.rejection_reason == "Too salesy, cut the last line"
      assert %DateTime{} = rejected.rejected_at
      assert rejected.approved_by_user_id == nil
      assert Post.rejected?(rejected)
      assert live_items(ctx.h1, post) == []
      assert live_items(ctx.h2, post) == []
      assert Fake.calls(:publish) == []

      assert {:error, :already_decided} = Approvals.decide_approve(card.canvas_id, ctx.h2)

      assert Approvals.card_view(card.id, {:user, ctx.h2.id}).status.text ==
               "Rejected by Hana One: Too salesy, cut the last line"
    end

    test "edit changes only the body, stays needs_approval, stamps edited_by, keeps the rows",
         ctx do
      {post, card} = pending_post!(ctx, ctx.a)

      assert {:ok, %{post: edited}} =
               Approvals.decide_edit(
                 card.canvas_id,
                 ctx.h2,
                 %{body: "Shorter"},
                 shown(card, ctx.h2)
               )

      assert edited.body == "Shorter"
      assert edited.status == "needs_approval"
      card_row = Repo.get!(ApprovalCard, card.id)
      assert card_row.state == "pending"
      assert card_row.edited_by_user_id == ctx.h2.id
      assert length(live_items(ctx.h1, post)) == 1
      assert Approvals.card_view(card.id, {:user, ctx.h1.id}).edited_by == "Hugo Two"

      assert {:error, :not_an_approver} =
               Approvals.decide_edit(card.canvas_id, ctx.n, %{body: "N edits"})

      assert Repo.get!(Post, post.id).body == "Shorter"
    end
  end

  describe "card_view" do
    test "approvers see the preview; N and G see the status line only", ctx do
      file = media_file!(ctx.org_id, "image/png")
      {_post, card} = pending_post!(ctx, ctx.a, %{media_file_ids: [file.id]})

      approver = Approvals.card_view(card.id, {:user, ctx.h1.id})
      assert approver.role == :approver
      assert approver.body =~ "Episode 12"
      assert [%{id: id}] = approver.media
      assert id == file.id
      assert approver.actions == [:approve, :edit, :reject]
      assert approver.char_limit == 3000
      assert approver.status.text == "Needs approval"

      for viewer <- [{:user, ctx.n.id}, {:agent, ctx.g.id}, nil] do
        view = Approvals.card_view(card.id, viewer)
        assert view.role == :viewer
        refute Map.has_key?(view, :body)
        refute Map.has_key?(view, :media)
        refute Map.has_key?(view, :actions)
        refute Map.has_key?(view, :fingerprint)
        assert view.status.text == "Needs approval"
      end
    end
  end

  describe "a refused publish on the card (task 01a165f1, stage 3)" do
    defp refused_card!(ctx, kind, attrs \\ []) do
      {post, card} = pending_post!(ctx, ctx.a)

      set =
        Keyword.merge(
          [
            status: "approved",
            approved_by_user_id: ctx.h1.id,
            approved_at: DateTime.utc_now(),
            refused_reason: kind,
            refused_at: DateTime.utc_now(),
            error: "The media sentence."
          ],
          attrs
        )

      Repo.update_all(from(p in Post, where: p.id == ^post.id), set: set)
      card
    end

    test "status_line names the refusal before the approved clause", ctx do
      card = refused_card!(ctx, "media_rejected")
      view = Approvals.card_view(card.id, {:user, ctx.h1.id})
      assert view.status == %{tone: :error, dot: :error, text: "Not published"}

      card = refused_card!(ctx, "rate_limited", retry_after: DateTime.add(DateTime.utc_now(), 60))
      view = Approvals.card_view(card.id, {:user, ctx.h1.id})
      assert view.status == %{tone: :warning, dot: :warning, text: "Waiting to retry"}
    end

    test "card_view carries the refusal for everyone and the action for the approver only",
         ctx do
      card = refused_card!(ctx, "media_rejected")

      approver = Approvals.card_view(card.id, {:user, ctx.h1.id})

      assert %{kind: :media_rejected, label: "Not published", reason: "The media sentence."} =
               approver.refusal

      assert approver.refusal.action.kind == :retry_publish

      for viewer <- [{:user, ctx.n.id}, {:agent, ctx.g.id}, nil] do
        view = Approvals.card_view(card.id, viewer)
        assert view.role == :viewer
        assert view.refusal.reason == "The media sentence."
        assert view.refusal.action == nil
      end
    end

    test "Open settings is for an org admin approver only", ctx do
      card = refused_card!(ctx, "publisher_not_configured")
      assert Approvals.card_view(card.id, {:user, ctx.h1.id}).refusal.action == nil

      Repo.update_all(
        from(m in Platform.Tenancy.OrgMembership,
          where: m.user_id == ^ctx.h1.id and m.org_id == ^ctx.org_id
        ),
        set: [role: "admin"]
      )

      assert %{kind: :open_settings, label: "Open settings"} =
               Approvals.card_view(card.id, {:user, ctx.h1.id}).refusal.action
    end

    test "rate_limited: Publish now disabled before retry_after, enabled after", ctx do
      card =
        refused_card!(ctx, "rate_limited", retry_after: DateTime.add(DateTime.utc_now(), 600))

      action = Approvals.card_view(card.id, {:user, ctx.h1.id}).refusal.action
      assert {action.kind, action.disabled?} == {:publish_now, true}

      card = refused_card!(ctx, "rate_limited", retry_after: DateTime.add(DateTime.utc_now(), -5))
      action = Approvals.card_view(card.id, {:user, ctx.h1.id}).refusal.action
      assert {action.kind, action.disabled?} == {:publish_now, false}
    end

    test "refusal_copy never shows a raw atom" do
      ctx = %{platform_label: "Instagram", error: nil, retry_after: ~U[2026-10-22 14:05:00Z]}

      assert Approvals.refusal_copy(:rate_limited, ctx) ==
               "Instagram's posting limit is reached. This post goes out at 14:05."

      assert Approvals.refusal_copy(:account_archived, ctx) ==
               "The Instagram account is disconnected."

      assert Approvals.refusal_copy(:media_rejected, ctx) ==
               "Instagram won't accept this post's media."
    end
  end
end
