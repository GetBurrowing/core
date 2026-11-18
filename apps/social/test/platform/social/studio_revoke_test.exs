defmodule Platform.Social.StudioRevokeTest do
  @moduledoc """
  Social Studio slice B: `revoke_approval/5`, `request_changes/5`, `resubmit/5`
  Covers exact events, receipt states, stale and archived cases.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.Studio
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    post = submitted_post!(w, w.x)
    %{w: w, post: post, approved: studio_approve!(w, post)}
  end

  defp current!(post), do: Enum.find(receipts(post), &(&1.state == "current"))

  describe "revoke_approval" do
    test "approved to needs_approval, same version, receipt revoked, one event",
         %{w: w, approved: approved} do
      receipt = current!(approved)

      assert {:ok, revoked} =
               Studio.revoke_approval(
                 w.org_id,
                 approved.id,
                 w.approver.id,
                 expect(approved, %{approval_id: receipt.id}),
                 "wrong slot"
               )

      assert revoked.status == "needs_approval"
      assert revoked.version == approved.version
      assert revoked.approved_by_user_id == nil
      assert revoked.approved_at == nil
      assert revoked.state_rev == approved.state_rev + 1

      assert [%{state: "revoked", ended_reason: "wrong slot", ended_by_id: id}] =
               receipts(approved)

      assert id == w.approver.id
      assert actions(approved) == ~w(created submitted approved approval_revoked)
      assert List.last(Platform.Social.PostEvents.list_for_post(approved.id)).note == "wrong slot"
      assert send_calls() == []
    end

    test "a planned post also clears the plan and writes plan_cancelled", %{
      w: w,
      approved: approved
    } do
      planned = studio_plan!(w, approved)
      receipt = current!(planned)

      assert {:ok, revoked} =
               Studio.revoke_approval(
                 w.org_id,
                 planned.id,
                 w.approver.id,
                 expect(planned, %{approval_id: receipt.id, reason: "from the map"})
               )

      assert {revoked.status, revoked.scheduled_at, revoked.planned_by_user_id} ==
               {"needs_approval", nil, nil}

      assert actions(planned) ==
               ~w(created submitted approved planned approval_revoked plan_cancelled)

      assert [%{ended_reason: "from the map"}] = receipts(planned)
    end

    test "stale revoke after a re-approval: the later approval stays current",
         %{w: w, approved: approved} do
      old = current!(approved)

      {:ok, revoked} =
        Studio.revoke_approval(
          w.org_id,
          approved.id,
          w.approver.id,
          expect(approved, %{approval_id: old.id})
        )

      {:ok, %{post: again}} =
        Studio.approve_version(w.org_id, approved.id, w.approver.id, expect(revoked))

      before = write_counts()

      assert {:error, {:stale, _}} =
               Studio.revoke_approval(
                 w.org_id,
                 approved.id,
                 w.approver.id,
                 expect(approved, %{approval_id: old.id})
               )

      assert write_counts() == before
      assert %{state: "current"} = current!(again)
    end

    test ":approval_not_current when the ids differ at equal state_rev", %{
      w: w,
      approved: approved
    } do
      before = write_counts()

      for id <- [Ecto.UUID.generate(), nil] do
        assert {:error, :approval_not_current} =
                 Studio.revoke_approval(
                   w.org_id,
                   approved.id,
                   w.approver.id,
                   expect(approved, %{approval_id: id})
                 )
      end

      assert write_counts() == before
    end

    test "a failing approval_revoked event rolls everything back", %{w: w, approved: approved} do
      fail_event!("approval_revoked")
      before = write_counts()

      assert_raise Ecto.ConstraintError, fn ->
        Studio.revoke_approval(
          w.org_id,
          approved.id,
          w.approver.id,
          expect(approved, %{approval_id: current!(approved).id})
        )
      end

      assert write_counts() == before
      assert fresh(approved) == approved
      assert %{state: "current"} = current!(approved)
    end

    test "a non-approver and an archived account are refused", %{w: w, approved: approved} do
      stranger = user!() |> member!(w.org_id)
      ex = expect(approved, %{approval_id: current!(approved).id})
      before = write_counts()

      assert {:error, :not_an_approver} =
               Studio.revoke_approval(w.org_id, approved.id, stranger.id, ex)

      {:ok, _} = Social.archive_account(w.org_id, w.x)

      assert {:error, :account_archived} =
               Studio.revoke_approval(w.org_id, approved.id, w.approver.id, ex)

      assert write_counts() == before
    end
  end

  describe "request_changes and resubmit" do
    # The outer setup approves `post`; these tests need a post still awaiting approval.
    setup %{w: w}, do: %{post: submitted_post!(w, w.tiktok)}

    test "needs_approval to draft with a reason, then resubmit", %{w: w, post: post} do
      assert {:ok, drafted} =
               Studio.request_changes(
                 w.org_id,
                 post.id,
                 w.approver.id,
                 expect(post),
                 "  shorter  "
               )

      assert drafted.status == "draft"
      assert drafted.rejection_reason == "shorter"
      assert %DateTime{} = drafted.rejected_at
      assert drafted.state_rev == post.state_rev + 1
      assert drafted.version == post.version
      assert Social.Post.rejected?(drafted)

      assert {:ok, back} =
               Studio.resubmit(w.org_id, post.id, w.approver.id, expect(drafted), "tightened")

      assert back.status == "needs_approval"
      assert back.rejection_reason == nil
      assert back.rejected_at == nil
      assert back.state_rev == drafted.state_rev + 1
      assert actions(post) == ~w(created submitted rejected submitted)
      [_, _, rejected, submitted] = Platform.Social.PostEvents.list_for_post(post.id)
      assert rejected.note == "shorter"
      assert submitted.note == "tightened"
    end

    test "refusals: blank reason, wrong status, stale", %{w: w, post: post} do
      before = write_counts()

      assert {:error, :reason_required} =
               Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "   ")

      approved = studio_approve!(w, post)

      assert {:error, :not_awaiting_approval} =
               Studio.request_changes(w.org_id, post.id, w.approver.id, expect(approved), "no")

      assert {:error, {:stale, _}} =
               Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "late")

      assert {_, _, _} = before
    end

    test "failing events roll back; non-approvers and archived accounts are refused",
         %{w: w, post: post} do
      stranger = user!() |> member!(w.org_id)
      before = write_counts()

      assert {:error, :not_an_approver} =
               Studio.request_changes(w.org_id, post.id, stranger.id, expect(post), "x")

      fail_event!("rejected")

      assert_raise Ecto.ConstraintError, fn ->
        Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "x")
      end

      assert write_counts() == before
      assert fresh(post) == post
      {:ok, _} = Social.archive_account(w.org_id, w.tiktok)

      assert {:error, :account_archived} =
               Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "x")
    end

    test "resubmit failing event rolls back; archived refused", %{w: w, post: post} do
      {:ok, drafted} = Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "x")
      stranger = user!() |> member!(w.org_id)
      before = write_counts()

      assert {:error, :not_an_approver} =
               Studio.resubmit(w.org_id, post.id, stranger.id, expect(drafted))

      fail_event!("submitted")

      assert_raise Ecto.ConstraintError, fn ->
        Studio.resubmit(w.org_id, post.id, w.approver.id, expect(drafted))
      end

      assert write_counts() == before
      assert fresh(post) == drafted
      {:ok, _} = Social.archive_account(w.org_id, w.tiktok)

      assert {:error, :account_archived} =
               Studio.resubmit(w.org_id, post.id, w.approver.id, expect(drafted))
    end
  end

  describe "plain submit: any Studio draft to needs_approval" do
    setup %{w: w}, do: %{draft: studio_post!(w, w.tiktok, "draft")}

    test "a never-rejected draft is submitted: event, state_rev, version kept, no receipt",
         %{w: w, draft: draft} do
      assert draft.status == "draft"
      refute Social.Post.rejected?(draft)
      receipts_before = length(receipts(draft))

      assert {:ok, sent} =
               Studio.resubmit(w.org_id, draft.id, w.approver.id, expect(draft), "ready")

      assert sent.status == "needs_approval"
      assert sent.state_rev == draft.state_rev + 1
      assert sent.version == draft.version
      assert sent.rejection_reason == nil
      assert sent.rejected_at == nil
      assert sent.approved_by_user_id == nil
      assert sent.scheduled_at == nil
      assert length(receipts(draft)) == receipts_before
      assert List.last(actions(draft)) == "submitted"
      assert List.last(Platform.Social.PostEvents.list_for_post(draft.id)).note == "ready"
      assert send_calls() == []
    end

    test "after request_changes the history is kept and the rejection fields are cleared",
         %{w: w} do
      post = submitted_post!(w, w.tiktok)

      {:ok, drafted} =
        Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "no")

      assert Social.Post.rejected?(drafted)

      assert {:ok, back} = Studio.resubmit(w.org_id, post.id, w.approver.id, expect(drafted))

      assert back.status == "needs_approval"
      assert back.rejection_reason == nil
      assert back.rejected_at == nil
      assert back.state_rev == drafted.state_rev + 1
      assert back.version == drafted.version
      assert actions(post) == ~w(created submitted rejected submitted)
      assert length(receipts(post)) == 0
    end

    test "wrong state is :not_a_draft and writes nothing", %{w: w, post: post, approved: approved} do
      awaiting = submitted_post!(w, w.tiktok)
      before = write_counts()
      events = actions(post)

      assert {:error, :not_a_draft} =
               Studio.resubmit(w.org_id, approved.id, w.approver.id, expect(approved))

      assert {:error, :not_a_draft} =
               Studio.resubmit(w.org_id, awaiting.id, w.approver.id, expect(awaiting))

      assert write_counts() == before
      assert actions(post) == events
      assert fresh(awaiting) == awaiting
    end

    test "stale has the exact shape and writes nothing", %{w: w, draft: draft} do
      before = write_counts()
      stale = expect(draft) |> Map.put(:state_rev, draft.state_rev - 1)

      assert {:error, {:stale, %{state_rev: rev, version: ver}}} =
               Studio.resubmit(w.org_id, draft.id, w.approver.id, stale)

      assert rev == draft.state_rev
      assert ver == draft.version

      stale_version = expect(draft) |> Map.put(:version, draft.version + 1)

      assert {:error, {:stale, _}} =
               Studio.resubmit(w.org_id, draft.id, w.approver.id, stale_version)

      assert write_counts() == before
      assert fresh(draft) == draft
      assert actions(draft) == ~w(created)
    end

    test "an unauthorised caller is refused and nothing is written", %{w: w, draft: draft} do
      stranger = user!() |> member!(w.org_id)
      before = write_counts()

      assert {:error, :not_an_approver} =
               Studio.resubmit(w.org_id, draft.id, stranger.id, expect(draft))

      assert write_counts() == before
      assert fresh(draft) == draft
      assert actions(draft) == ~w(created)
    end

    test "an agent id is refused as not a human and nothing is written", %{w: w, draft: draft} do
      before = write_counts()

      assert {:error, :not_a_human} =
               Studio.resubmit(w.org_id, draft.id, w.agent.id, expect(draft))

      assert write_counts() == before
      assert fresh(draft) == draft
      assert actions(draft) == ~w(created)
    end
  end
end
