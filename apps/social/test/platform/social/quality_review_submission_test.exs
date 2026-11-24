defmodule Platform.Social.QualityReviewSubmissionTest do
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ApprovalCard, Composer, Post, PostEvent}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture() |> with_ideas_runtime()

    profile =
      Repo.update!(Ecto.Changeset.change(ctx.profile, quality_reviewer_user_ids: [ctx.n.id]))

    Map.put(ctx, :profile, profile)
  end

  test "agent submission enters quality review, while an explicit draft stays draft", ctx do
    for {requested, expected} <- [
          {nil, "quality_review"},
          {"needs_approval", "quality_review"},
          {"quality_review", "quality_review"},
          {"draft", "draft"}
        ] do
      attrs = agent_attrs(ctx)
      attrs = if requested, do: Map.put(attrs, "status", requested), else: attrs
      assert {:ok, [post]} = AgentDrafts.create_agent_drafts(ctx.org_id, ctx.profile.id, attrs)
      assert post.status == expected
      assert is_nil(post.approved_at)
      refute Repo.exists?(from(c in ApprovalCard, where: c.post_id == ^post.id))
    end

    assert Fake.calls() == []
  end

  test "agent may submit and edit quality review but cannot withdraw it or enter final review",
       ctx do
    assert {:ok, [draft]} =
             AgentDrafts.create_agent_drafts(
               ctx.org_id,
               ctx.profile.id,
               Map.put(agent_attrs(ctx), "status", "draft")
             )

    assert {:ok, submitted} =
             AgentDrafts.update_agent_draft(ctx.org_id, draft.id, %{"status" => "needs_approval"})

    assert submitted.status == "quality_review"

    assert {:ok, edited} =
             AgentDrafts.update_agent_draft(ctx.org_id, draft.id, %{"body" => "Improved copy"})

    assert edited.status == "quality_review"

    for status <- ["draft", "needs_approval"] do
      result = AgentDrafts.update_agent_draft(ctx.org_id, draft.id, %{"status" => status})

      if status == "draft",
        do: assert(result == {:error, :status_not_allowed}),
        else: assert(match?({:ok, %{status: "quality_review"}}, result))

      assert Repo.get!(Post, draft.id).status == "quality_review"
    end

    assert Repo.aggregate(
             from(e in PostEvent, where: e.post_id == ^draft.id and e.action == "submitted"),
             :count
           ) == 1

    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  test "quality reviewer can compose drafts and submit without final approval", ctx do
    compose = %{
      idea: %{title: "A quality-reviewed idea"},
      drafts: [
        %{
          account_id: ctx.a.id,
          text: "Ready for review",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
        }
      ]
    }

    assert {:ok, %{posts: [draft]}} = Composer.save_drafts(ctx.profile, ctx.n.id, compose)
    assert draft.status == "draft"
    assert {:ok, result} = Composer.send(ctx.profile, ctx.n.id, compose)
    assert [post] = result.quality_review
    assert post.status == "quality_review"
    assert result.approved == []
    assert result.waiting_owner == []
    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  test "send and approve on a gated profile submits to quality review without an approval attempt",
       ctx do
    compose = %{
      idea: %{title: "Quality first"},
      drafts: [
        %{
          account_id: ctx.a.id,
          text: "Review this",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
        }
      ]
    }

    assert Composer.approvable_account_ids(ctx.profile, [ctx.a], ctx.h1.id) == []
    assert {:ok, result} = Composer.send(ctx.profile, ctx.h1.id, compose, approve: true)
    assert [%{status: "quality_review"}] = result.quality_review
    assert result.approved == []
    assert result.not_approved == []
    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  test "agent post list filters quality review through the tool boundary", ctx do
    assert {:ok, [post]} =
             AgentDrafts.create_agent_drafts(ctx.org_id, ctx.profile.id, agent_attrs(ctx))

    assert {:ok, result} =
             Platform.Federation.ToolArguments.dispatch(
               "social_post_list",
               %{"profile_id" => ctx.profile.id, "status" => "quality_review"},
               ctx.agent_ctx
             )

    assert [%{id: id, status: "quality_review"}] = result.posts
    assert id == post.id
  end

  test "agent cannot forge quality pass metadata on create or update", ctx do
    assert {:ok, [draft]} =
             AgentDrafts.create_agent_drafts(
               ctx.org_id,
               ctx.profile.id,
               Map.put(agent_attrs(ctx), "status", "draft")
             )

    for {field, value} <- [
          {"quality_passed_by_user_id", ctx.n.id},
          {"quality_passed_at", DateTime.utc_now()},
          {"quality_pass_fingerprint", "forged"}
        ] do
      assert {:error, :field_not_allowed, [^field]} =
               AgentDrafts.create_agent_drafts(
                 ctx.org_id,
                 ctx.profile.id,
                 Map.put(agent_attrs(ctx), field, value)
               )

      assert {:error, :field_not_allowed, [^field]} =
               AgentDrafts.update_agent_draft(ctx.org_id, draft.id, %{field => value})

      assert Repo.get!(Post, draft.id).status == "draft"
    end

    assert Repo.aggregate(Post, :count) == 1
    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  test "incomplete composer version can request quality review before the pass check", ctx do
    {:ok, youtube} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube", handle: "@review"})

    compose = %{
      idea: %{title: "Needs editing"},
      drafts: [%{account_id: youtube.id, text: "", title: nil}]
    }

    assert {:ok, %{quality_review: [%{status: "quality_review"}]}} =
             Composer.send(ctx.profile, ctx.n.id, compose)

    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  test "an ungated brand cannot be put into quality review by an agent", ctx do
    profile = Repo.update!(Ecto.Changeset.change(ctx.profile, quality_reviewer_user_ids: []))

    assert {:error, :status_not_allowed} =
             AgentDrafts.create_agent_drafts(
               ctx.org_id,
               profile.id,
               Map.put(agent_attrs(ctx), "status", "quality_review")
             )

    assert {:ok, [draft]} =
             AgentDrafts.create_agent_drafts(
               ctx.org_id,
               profile.id,
               Map.put(agent_attrs(ctx), "status", "draft")
             )

    assert {:error, :status_not_allowed} =
             AgentDrafts.update_agent_draft(ctx.org_id, draft.id, %{"status" => "quality_review"})

    assert Repo.get!(Post, draft.id).status == "draft"
    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  test "removed quality reviewer cannot submit from an old composer profile", ctx do
    stale_profile = ctx.profile
    Repo.update!(Ecto.Changeset.change(ctx.profile, quality_reviewer_user_ids: [ctx.h2.id]))

    compose = %{
      idea: %{title: "Stale request"},
      drafts: [%{account_id: ctx.a.id, text: "Review this"}]
    }

    assert {:error, _} = Composer.send(stale_profile, ctx.n.id, compose)
    assert {:error, _} = Composer.save_drafts(stale_profile, ctx.n.id, compose)
    assert Repo.aggregate(Post, :count) == 0
    assert Fake.calls() == []
  end

  test "a quality request with no caption preserves blank text despite an automatic home link",
       ctx do
    {:ok, profile} =
      Social.update_profile(ctx.org_id, ctx.profile, %{home_url: "https://example.org"})

    attrs = agent_attrs(ctx) |> Map.delete("body")
    assert {:ok, [post]} = AgentDrafts.create_agent_drafts(ctx.org_id, profile.id, attrs)
    assert post.status == "quality_review"
    assert post.body == nil
    assert post.link_url == "https://example.org"
    before = Repo.get!(Post, post.id)

    assert {:error, {:incomplete_post, ["Add the post text."]}} =
             Social.pass_quality_review(ctx.org_id, post.id, ctx.n.id)

    assert Repo.get!(Post, post.id) == before
    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  defp agent_attrs(ctx),
    do: %{
      "account_ids" => [ctx.a.id],
      "body" => "Review me",
      "scheduled_at" => DateTime.add(DateTime.utc_now(), 3600)
    }
end
