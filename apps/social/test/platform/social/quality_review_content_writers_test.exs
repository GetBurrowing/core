defmodule Platform.Social.QualityReviewContentWritersTest do
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialApprovalFixtures
  import Platform.SocialFixtures, only: [media_file!: 2]

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ApprovalCard, Approvals, Post, QualityReview}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()

    {:ok, profile} =
      Social.update_profile(ctx.org_id, ctx.profile, %{quality_reviewer_user_ids: [ctx.n.id]})

    Map.merge(ctx, %{
      profile: profile,
      video: media_file!(ctx.org_id, "video/mp4"),
      png: media_file!(ctx.org_id, "image/png")
    })
  end

  test "generic YouTube title update invalidates the pass and retires the final card", c do
    {:ok, account} =
      Social.create_account(c.org_id, c.profile, %{
        platform: "youtube",
        status: "connected",
        handle: "@quality"
      })

    {passed, card} =
      passed!(c, account, %{title: "Original publishing title", media_file_ids: [c.video.id]})

    assert {:ok, edited} =
             Social.update_post(c.org_id, passed, %{title: "Revised publishing title"})

    assert edited.platform_options["title"] == "Revised publishing title"
    assert_returned(c, passed, edited, card)
  end

  test "platform options writer invalidates a pass on content sent to the platform", c do
    {passed, card} = passed!(c, c.a)

    assert {:ok, edited} =
             Social.set_platform_options(c.org_id, c.h1.id, passed.id, %{
               "first_comment" => "Added after quality review"
             })

    assert edited.platform_options == %{"first_comment" => "Added after quality review"}
    assert_returned(c, passed, edited, card)
  end

  test "cover writer invalidates the pass and retires the old final card", c do
    {passed, card} = passed!(c, c.a, %{media_file_ids: [c.video.id]})

    assert {:ok, edited} =
             Social.set_cover(c.org_id, c.h1.id, passed.id, %{cover_file_id: c.png.id})

    assert edited.cover_file_id == c.png.id
    assert_returned(c, passed, edited, card)
  end

  test "direct agent content writer invalidates a current pass", c do
    {passed, card} = passed!(c, c.a)

    assert {:ok, edited} =
             AgentDrafts.update_agent_draft(
               c.org_id,
               passed.id,
               %{"body" => "Agent changed the reviewed text"},
               agent_id: c.g.id
             )

    assert edited.body == "Agent changed the reviewed text"
    assert_returned(c, passed, edited, card)
  end

  test "agent future-time-only edit retains the pass and existing pending final card", c do
    {passed, card} = passed!(c, c.a)
    at = DateTime.add(passed.scheduled_at, 3600)

    assert {:ok, edited} =
             AgentDrafts.update_agent_draft(c.org_id, passed.id, %{"scheduled_at" => at},
               agent_id: c.g.id
             )

    assert edited.scheduled_at == at
    assert edited.status == "needs_approval"
    assert edited.quality_passed_by_user_id == passed.quality_passed_by_user_id
    assert edited.quality_passed_at == passed.quality_passed_at
    assert edited.quality_pass_fingerprint == passed.quality_pass_fingerprint
    assert QualityReview.valid_pass?(edited)
    assert Approvals.live_card(edited.id).id == card.id
    assert Repo.get!(ApprovalCard, card.id).state == "pending"
    assert edited.approved_at == nil
    assert Fake.calls() == []
  end

  test "invalid edits retain the reviewed content, pass and live final card", c do
    {:ok, youtube} =
      Social.create_account(c.org_id, c.profile, %{platform: "youtube", status: "connected"})

    {passed, card} = passed!(c, youtube, %{title: "Reviewed title", media_file_ids: [c.video.id]})
    before = Repo.get!(Post, passed.id)
    too_long = String.duplicate("x", 101)
    assert {:error, %Ecto.Changeset{}} = Social.update_post(c.org_id, passed, %{title: too_long})

    assert {:error, {:invalid_options, _}} =
             Social.set_platform_options(c.org_id, c.h1.id, passed.id, %{"title" => too_long})

    invalid_cover = media_file!(c.org_id, "application/pdf")

    assert {:error, %Ecto.Changeset{}} =
             Social.set_cover(c.org_id, c.h1.id, passed.id, %{cover_file_id: invalid_cover.id})

    assert Repo.get!(Post, passed.id) == before
    assert Approvals.live_card(passed.id).id == card.id
    assert Repo.get!(ApprovalCard, card.id).state == "pending"
    assert Fake.calls() == []
  end

  defp passed!(c, account, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          body: "Reviewed content",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600),
          status: "needs_approval"
        },
        attrs
      )

    assert {:ok, requested} = Social.create_post(c.org_id, account, attrs)
    assert requested.status == "quality_review"
    assert {:ok, passed} = Social.pass_quality_review(c.org_id, requested.id, c.n.id)
    assert QualityReview.valid_pass?(passed)
    {passed, Approvals.live_card(passed.id)}
  end

  defp assert_returned(c, passed, edited, card) do
    assert edited.status == "quality_review"
    assert edited.quality_passed_by_user_id == nil
    assert edited.quality_passed_at == nil
    assert edited.quality_pass_fingerprint == nil
    refute QualityReview.valid_pass?(edited)
    assert edited.scheduled_at == passed.scheduled_at
    assert edited.approved_at == nil
    assert edited.approved_by_user_id == nil
    assert edited.external_id == nil
    assert Repo.get!(ApprovalCard, card.id).state == "superseded"
    assert Approvals.live_card(edited.id) == nil

    refute Repo.exists?(
             from(i in Platform.Inbox.Item,
               where:
                 i.source_id == ^edited.id and i.kind == "social_post_approval" and
                   is_nil(i.dismissed_at)
             )
           )

    assert {:error, :already_decided} =
             Approvals.decide_approve(card.canvas_id, c.h1, Approvals.fingerprint(passed))

    assert Repo.get!(Post, edited.id).status == "quality_review"
    assert Fake.calls() == []
  end
end
