defmodule Platform.Social.QualityReviewTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  import Platform.SocialApprovalFixtures
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Approvals, Post, PostEvent, QualityReview}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()

    {:ok, profile} =
      Social.update_profile(ctx.org_id, ctx.profile, %{quality_reviewer_user_ids: [ctx.n.id]})

    Map.put(ctx, :profile, profile)
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

  defp requested!(ctx, attrs \\ %{}) do
    {:ok, post} =
      Social.create_post(
        ctx.org_id,
        ctx.a,
        Map.merge(
          %{body: "Quality-reviewed text", scheduled_at: future(), status: "needs_approval"},
          attrs
        )
      )

    assert post.status == "quality_review"
    post
  end

  defp final_items(post) do
    Repo.all(
      from(i in Platform.Inbox.Item,
        where: i.source_id == ^post.id and i.kind == "social_post_approval"
      )
    )
  end

  defp effects(post) do
    {Repo.get!(Post, post.id), Repo.aggregate(ApprovalCard, :count),
     Repo.aggregate(Platform.Inbox.Item, :count), Repo.aggregate(PostEvent, :count),
     Fake.calls(:publish)}
  end

  test "quality membership never grants final approval authority", c do
    assert :ok = Social.quality_reviewer_check(c.org_id, c.profile, c.n.id)

    assert {:error, :not_an_approver} =
             Social.post_approver_check(c.org_id, c.profile, c.a, c.n.id)

    assert :ok = Social.post_preparer_check(c.org_id, c.profile, c.a, c.n.id)

    assert {:error, :not_a_quality_reviewer} =
             Social.quality_reviewer_check(c.org_id, c.profile, c.h1.id)

    assert {:error, :not_a_human} = Social.quality_reviewer_check(c.org_id, c.profile, c.g.id)
  end

  test "explicit submission requests quality review without notifying final approvers", c do
    post = requested!(c)
    assert is_nil(Approvals.live_card(post.id))
    assert final_items(post) == []
    assert Repo.get!(Post, post.id).approved_by_user_id == nil
    assert Fake.calls(:publish) == []

    assert Repo.exists?(
             from(i in Platform.Inbox.Item,
               where: i.source_id == ^post.id and i.user_id == ^c.n.id
             )
           )
  end

  test "save draft remains separate, and a quality reviewer can submit it", c do
    {:ok, post} = Social.create_post(c.org_id, c.a, %{body: "Saved"})
    assert post.status == "draft"

    assert {:ok, saved} =
             Social.edit_draft(c.org_id, post.id, c.n.id, %{body: "Edited"}, submit: false)

    assert saved.status == "draft"
    assert {:ok, sent} = Social.edit_draft(c.org_id, post.id, c.n.id, %{}, submit: true)
    assert sent.status == "quality_review"
    assert final_items(post) == []
  end

  test "pass records who, when and exact content while preserving the chosen time and no final approver",
       c do
    post = requested!(c)
    assert {:ok, passed} = Social.pass_quality_review(c.org_id, post.id, c.n.id)
    assert passed.status == "needs_approval"
    assert passed.quality_passed_by_user_id == c.n.id
    assert %DateTime{} = passed.quality_passed_at
    assert passed.quality_pass_fingerprint == Approvals.content_fingerprint(passed)
    assert passed.scheduled_at == post.scheduled_at
    assert passed.approved_by_user_id == nil and passed.approved_at == nil
    assert passed.external_id == nil and passed.publish_attempts == 0
    assert QualityReview.valid_pass?(passed)
    assert %ApprovalCard{} = Approvals.live_card(post.id)
    assert Enum.sort(Enum.map(final_items(post), & &1.user_id)) == Enum.sort([c.h1.id, c.h2.id])
    assert Fake.calls(:publish) == []
  end

  test "incomplete or elapsed-time pass is refused without writes or clearing the chosen time",
       c do
    post = requested!(c, %{scheduled_at: nil})
    before = effects(post)
    assert {:error, {:incomplete_post, _}} = Social.pass_quality_review(c.org_id, post.id, c.n.id)
    assert effects(post) == before
    past = DateTime.add(DateTime.utc_now(), -3600)
    post = Repo.update!(Ecto.Changeset.change(post, scheduled_at: past))
    before = effects(post)

    assert {:error, {:incomplete_post, ["The publish time has passed. Choose a new one."]}} =
             Social.pass_quality_review(c.org_id, post.id, c.n.id)

    assert effects(post) == before
    assert Repo.get!(Post, post.id).scheduled_at == past
  end

  test "wrong-role pass and final approval refuse with no side effects", c do
    post = requested!(c)
    before = effects(post)

    assert {:error, :not_a_quality_reviewer} =
             Social.pass_quality_review(c.org_id, post.id, c.h1.id)

    assert {:error, :not_an_approver} = Social.approve_post(c.org_id, post, c.n.id)
    assert {:error, :quality_review_required} = Social.approve_post(c.org_id, post, c.h1.id)
    assert effects(post) == before
    {:ok, draft} = Social.create_post(c.org_id, c.a, %{body: "Draft", scheduled_at: future()})
    assert {:error, :quality_review_required} = Social.approve_post(c.org_id, draft, c.h1.id)
  end

  test "all human quality-stage content editors require the quality role", c do
    post = requested!(c)
    before = effects(post)

    assert {:error, :not_a_quality_reviewer} =
             Social.edit_quality_review(c.org_id, post.id, c.h1.id, %{body: "Not my stage"})

    assert {:error, :not_a_quality_reviewer} =
             Social.set_cover(c.org_id, c.h1.id, post.id, :clear)

    assert {:error, :not_a_quality_reviewer} =
             Social.set_platform_options(c.org_id, c.h1.id, post.id, %{
               "first_comment" => "Not my stage"
             })

    assert effects(post) == before
    assert {:ok, _} = Social.set_cover(c.org_id, c.n.id, post.id, :clear)

    assert {:ok, edited} =
             Social.set_platform_options(c.org_id, c.n.id, post.id, %{
               "first_comment" => "Quality edit"
             })

    assert edited.status == "quality_review"
    assert Fake.calls(:publish) == []
  end

  test "quality-stage editing preserves the archived-account scheduling refusal", c do
    post = requested!(c)
    Repo.update!(Ecto.Changeset.change(c.a, archived_at: DateTime.utc_now()))
    before = effects(post)

    assert {:error, :account_archived} =
             Social.edit_quality_review(c.org_id, post.id, c.n.id, %{
               scheduled_at: DateTime.add(future(), 3600)
             })

    assert effects(post) == before

    assert {:ok, edited} =
             Social.edit_quality_review(c.org_id, post.id, c.n.id, %{
               body: "Preparation may still be edited"
             })

    assert edited.status == "quality_review"
  end

  test "an existing final-review card is not grandfathered and has an explicit return route", c do
    {:ok, profile} = Social.update_profile(c.org_id, c.profile, %{quality_reviewer_user_ids: []})
    {old, card} = pending_post!(%{c | profile: profile}, c.a)
    {:ok, _} = Social.update_profile(c.org_id, profile, %{quality_reviewer_user_ids: [c.n.id]})
    before = effects(old)

    assert {:error, :quality_review_required} =
             Approvals.decide_approve(card.canvas_id, %{id: c.h1.id})

    assert effects(old) == before
    assert {:ok, returned} = Social.return_to_quality_review(c.org_id, old.id, c.n.id)
    assert returned.status == "quality_review"
    assert Repo.get!(ApprovalCard, card.id).state == "superseded"
    assert {:error, :already_decided} = Approvals.decide_approve(card.canvas_id, %{id: c.h1.id})
    assert Fake.calls(:publish) == []
  end

  test "send back requires a note and returns an editable draft without final approval", c do
    post = requested!(c)
    before = effects(post)

    assert {:error, :note_required} =
             Social.send_back_quality_review(c.org_id, post.id, c.n.id, " ")

    assert effects(post) == before
    assert {:ok, sent} = Social.send_back_quality_review(c.org_id, post.id, c.n.id, "Fix the cut")
    assert sent.status == "draft" and sent.rejection_reason == "Fix the cut"
    assert sent.approved_by_user_id == nil
    assert sent.scheduled_at == post.scheduled_at
    assert final_items(post) == []
    assert Fake.calls(:publish) == []
  end

  test "send back notifies a human author with an exact draft route", c do
    c = with_ideas_runtime(c)
    post = requested!(c)

    Repo.transaction(fn ->
      Platform.Social.PostEvents.record!(post, "created", {:human, c.h1.id})
    end)

    assert {:ok, _} =
             Social.send_back_quality_review(
               c.org_id,
               post.id,
               c.n.id,
               "Please improve the ending"
             )

    item =
      Repo.one(
        from(i in Platform.Inbox.Item,
          where:
            i.source_id == ^post.id and i.user_id == ^c.h1.id and i.kind == "social_post_revision"
        )
      )

    assert item.title == "Changes requested"
    assert item.url =~ "post=#{post.id}"
    assert Repo.get!(Post, post.id).rejection_reason == "Please improve the ending"
  end

  test "a content edit invalidates the pass and makes its old final card unusable", c do
    post = requested!(c)
    {:ok, passed} = Social.pass_quality_review(c.org_id, post.id, c.n.id)
    card = Approvals.live_card(post.id)
    assert {:ok, edited} = Social.update_post(c.org_id, passed, %{body: "Changed after pass"})
    assert edited.status == "quality_review"
    refute QualityReview.valid_pass?(edited)
    assert Repo.get!(ApprovalCard, card.id).state == "superseded"
    assert {:error, :already_decided} = Approvals.decide_approve(card.canvas_id, %{id: c.h1.id})
    assert Fake.calls(:publish) == []
  end

  test "approval checks the stored content mark even if a writer did not route its edit", c do
    post = requested!(c)
    {:ok, passed} = Social.pass_quality_review(c.org_id, post.id, c.n.id)
    altered = Repo.update!(Ecto.Changeset.change(passed, body: "Different persisted content"))
    before = effects(altered)
    refute QualityReview.valid_pass?(altered)
    assert {:error, :quality_review_required} = Social.approve_post(c.org_id, altered.id, c.h1.id)
    assert effects(altered) == before
  end

  test "time-only edit preserves a valid pass, then the ordinary approver can approve", c do
    post = requested!(c)
    {:ok, passed} = Social.pass_quality_review(c.org_id, post.id, c.n.id)
    at = DateTime.add(future(), 3600)
    assert {:ok, changed} = Social.update_post(c.org_id, passed, %{scheduled_at: at})
    assert changed.status == "needs_approval"
    assert QualityReview.valid_pass?(changed)
    assert changed.quality_pass_fingerprint == passed.quality_pass_fingerprint
    assert {:ok, approved} = Social.approve_post(c.org_id, changed, c.h1.id)
    assert approved.approved_by_user_id == c.h1.id
  end

  test "a revoked reviewer cannot edit or pass a stale open quality post", c do
    post = requested!(c)
    {:ok, _} = Social.update_profile(c.org_id, c.profile, %{quality_reviewer_user_ids: [c.h2.id]})
    before = effects(post)

    assert {:error, :not_a_quality_reviewer} =
             Social.pass_quality_review(c.org_id, post.id, c.n.id)

    assert {:error, :not_a_quality_reviewer} =
             Social.edit_quality_review(c.org_id, post.id, c.n.id, %{body: "Forbidden"})

    assert effects(post) == before
  end

  test "quality review ignores ownership, final approval retains the live owner rule", c do
    account = Repo.update!(Ecto.Changeset.change(c.a, owner_user_id: c.h1.id))
    post = requested!(%{c | a: account})
    assert {:ok, passed} = Social.pass_quality_review(c.org_id, post.id, c.n.id)
    assert {:error, :not_the_owner} = Social.approve_post(c.org_id, passed, c.h2.id)
    assert {:ok, _} = Social.approve_post(c.org_id, passed, c.h1.id)
  end

  test "the reused quality content mark covers every accepted content field and excludes time" do
    post = %Post{
      account_id: Ecto.UUID.generate(),
      body: "Original",
      link_url: "https://example.org",
      media_file_ids: [Ecto.UUID.generate()],
      platform_options: %{"title" => "Original"}
    }

    fp = Approvals.content_fingerprint(post)

    for change <- [
          %{account_id: Ecto.UUID.generate()},
          %{body: "Edited"},
          %{link_url: "https://example.org/new"},
          %{media_file_ids: [Ecto.UUID.generate()]},
          %{cover_file_id: Ecto.UUID.generate()},
          %{cover_offset_ms: 500},
          %{platform_options: %{"title" => "Edited"}},
          %{platform_options: %{"title" => "Original", "first_comment" => "Added"}},
          %{is_aigc: true},
          %{ai_disclosure: "Disclosure"}
        ] do
      refute Approvals.content_fingerprint(struct(post, change)) == fp
    end

    assert Approvals.content_fingerprint(%{post | scheduled_at: future()}) == fp
  end
end
