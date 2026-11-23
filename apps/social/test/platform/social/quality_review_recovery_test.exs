defmodule Platform.Social.QualityReviewRecoveryTest do
  use Platform.DataCase, async: false

  import Platform.SocialApprovalFixtures
  import Platform.SocialFixtures, only: [user!: 0, member!: 2]

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Post, PostEvent}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    c = approval_fixture()

    {:ok, profile} =
      Social.update_profile(c.org_id, c.profile, %{quality_reviewer_user_ids: [c.n.id]})

    Map.put(c, :profile, profile)
  end

  test "existing final approver can send a quality post back with a note, without gaining edit or pass",
       c do
    post = requested!(c)

    assert {:error, :not_a_quality_reviewer} =
             Social.edit_quality_review(c.org_id, post.id, c.h1.id, %{body: "Not my stage"})

    assert {:error, :not_a_quality_reviewer} =
             Social.pass_quality_review(c.org_id, post.id, c.h1.id)

    assert {:ok, draft} =
             Social.send_back_quality_review(c.org_id, post.id, c.h1.id, "Please fix the edit")

    assert_draft_recovery(post, draft)
    assert draft.rejection_reason == "Please fix the edit"
  end

  test "last reviewer removal still lets the current final approver recover the stranded quality post",
       c do
    post = requested!(c)
    {:ok, _profile} = Social.update_profile(c.org_id, c.profile, %{quality_reviewer_user_ids: []})
    before = effects(post)

    assert {:error, _} =
             Social.send_back_quality_review(c.org_id, post.id, c.n.id, "No longer authorized")

    assert effects(post) == before

    assert {:error, :note_required} =
             Social.send_back_quality_review(c.org_id, post.id, c.h1.id, " ")

    assert effects(post) == before

    assert {:ok, draft} =
             Social.send_back_quality_review(c.org_id, post.id, c.h1.id, "Return for preparation")

    assert_draft_recovery(post, draft)
  end

  test "an owned account retains its final-owner boundary while its quality reviewer may still send back",
       c do
    {:ok, account} = Social.set_account_owner(c.org_id, c.a, c.h1.id)
    c = %{c | a: account}
    post = requested!(c)
    before = effects(post)

    assert {:error, :not_the_owner} =
             Social.send_back_quality_review(c.org_id, post.id, c.h2.id, "Not mine")

    assert effects(post) == before

    assert {:ok, draft} =
             Social.send_back_quality_review(c.org_id, post.id, c.h1.id, "Owner requests an edit")

    assert_draft_recovery(post, draft)

    another = requested!(c)

    assert {:ok, draft} =
             Social.send_back_quality_review(
               c.org_id,
               another.id,
               c.n.id,
               "Reviewer requests an edit"
             )

    assert_draft_recovery(another, draft)
  end

  test "an unrelated org member cannot recover a quality post or change any effects", c do
    outsider = user!()
    member!(outsider, c.org_id)
    post = requested!(c)
    before = effects(post)

    assert {:error, _} =
             Social.send_back_quality_review(c.org_id, post.id, outsider.id, "Unauthorized")

    assert effects(post) == before
  end

  test "unfinished, final-rejected and quality-sent-back drafts retain distinct stored markers",
       c do
    {:ok, unfinished} = Social.create_post(c.org_id, c.a, %{body: "Unfinished preparation"})

    reject = fn post, note ->
      {:ok, passed} = Social.pass_quality_review(c.org_id, post.id, c.n.id)
      card = Social.Approvals.live_card(passed.id)
      {:ok, %{post: rejected}} = Social.Approvals.decide_reject(card.canvas_id, c.h1, note)
      rejected
    end

    final_rejected = reject.(requested!(c), "Final go/no-go: no")
    earlier_rejected = reject.(requested!(c), "An earlier final rejection")

    {:ok, resubmitted} =
      Social.edit_draft(c.org_id, earlier_rejected.id, c.h1.id, %{body: "Revised preparation"},
        submit: true
      )

    assert resubmitted.status == "quality_review"
    assert %DateTime{} = resubmitted.rejected_at

    {:ok, sent_back} =
      Social.send_back_quality_review(
        c.org_id,
        resubmitted.id,
        c.n.id,
        "Quality revision still needed"
      )

    assert unfinished.status == "draft" and is_nil(unfinished.rejected_at) and
             is_nil(unfinished.rejection_reason)

    assert final_rejected.status == "draft"
    assert %DateTime{} = final_rejected.rejected_at
    assert final_rejected.rejection_reason == "Final go/no-go: no"
    assert sent_back.status == "draft" and is_nil(sent_back.rejected_at)
    assert sent_back.rejection_reason == "Quality revision still needed"
    assert List.last(Social.PostEvents.list_for_post(final_rejected.id)).action == "rejected"
    assert List.last(Social.PostEvents.list_for_post(sent_back.id)).action == "revision_requested"
    assert Fake.calls() == []
  end

  defp requested!(c) do
    assert {:ok, post} =
             Social.create_post(c.org_id, c.a, %{
               body: "Needs review",
               status: "needs_approval",
               scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert post.status == "quality_review"
    post
  end

  defp effects(post),
    do:
      {Repo.get!(Post, post.id), Repo.aggregate(ApprovalCard, :count),
       Repo.aggregate(PostEvent, :count), Repo.aggregate(Platform.Inbox.Item, :count),
       Fake.calls()}

  defp assert_draft_recovery(before, draft) do
    assert draft.status == "draft"
    assert draft.body == before.body
    assert draft.scheduled_at == before.scheduled_at
    assert draft.approved_at == nil
    assert draft.approved_by_user_id == nil
    assert draft.quality_passed_at == nil
    assert draft.quality_passed_by_user_id == nil
    assert draft.quality_pass_fingerprint == nil
    assert draft.rejected_at == nil
    assert draft.external_id == nil
    assert draft.publish_attempts == 0
    assert Fake.calls() == []
  end
end
