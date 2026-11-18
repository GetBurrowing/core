defmodule Platform.Social.StudioPlanTest do
  @moduledoc """
  Social Studio slice B: `plan_post/5` and `cancel_plan/4` (approval,
  ownership, history and never sending). Planning is internal: no publisher is ever called.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.{Post, PostEvents, Publishing, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    post = submitted_post!(w, w.x)
    %{w: w, post: post, approved: studio_approve!(w, post)}
  end

  defp future(secs \\ 3_600), do: DateTime.add(DateTime.utc_now(), secs, :second)

  describe "plan_post/5" do
    test "plans an approved post as a separate action and writes planned",
         %{w: w, approved: approved} do
      at = future()

      assert {:ok, %{post: planned, approval: approval}} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved), at)

      assert planned.status == "planned"
      assert DateTime.compare(planned.scheduled_at, at) == :eq
      assert planned.planned_by_user_id == w.approver.id
      assert %DateTime{} = planned.planned_set_at
      assert planned.state_rev == approved.state_rev + 1
      assert planned.version == approved.version
      assert approval.state == "current"
      assert actions(approved) == ~w(created submitted approved planned)
      assert send_calls() == []
    end

    test "planned_at may ride in the expect map", %{w: w, approved: approved} do
      assert {:ok, %{post: %{status: "planned"}}} =
               Studio.plan_post(
                 w.org_id,
                 approved.id,
                 w.approver.id,
                 expect(approved, %{planned_at: future()})
               )
    end

    test "a replan keeps the plan, bumps state_rev and notes the previous time",
         %{w: w, approved: approved} do
      first = studio_plan!(w, approved, nil, future(3_600))
      later = future(7_200)

      {:ok, %{post: again}} =
        Studio.plan_post(w.org_id, first.id, w.approver.id, expect(first), later)

      assert again.status == "planned"
      assert DateTime.compare(again.scheduled_at, later) == :eq
      assert again.state_rev == first.state_rev + 1
      assert actions(first) == ~w(created submitted approved planned planned)
      last = List.last(PostEvents.list_for_post(first.id))
      assert last.note =~ DateTime.to_iso8601(first.scheduled_at)
    end

    test "a time in the past, or not a time, is refused and nothing is written",
         %{w: w, approved: approved} do
      before = write_counts()

      assert {:error, :time_in_past} =
               Studio.plan_post(
                 w.org_id,
                 approved.id,
                 w.approver.id,
                 expect(approved),
                 future(-5)
               )

      assert {:error, :invalid_time} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved), "soon")

      assert {:error, :invalid_time} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved))

      assert write_counts() == before
      assert fresh(approved) == approved
    end

    test "a post that is not approved cannot be planned", %{w: w, post: post} do
      fresh_post = submitted_post!(w, w.tiktok)
      draft = studio_post!(w, w.tiktok, "draft")
      before = write_counts()

      for p <- [fresh_post, draft] do
        assert {:error, :not_approved} =
                 Studio.plan_post(w.org_id, p.id, w.approver.id, expect(p), future())
      end

      assert write_counts() == before
      _ = post
    end

    test "a stale call writes nothing and creates no plan", %{w: w, approved: approved} do
      first = studio_plan!(w, approved)
      before = write_counts()

      assert {:error, {:stale, %{state_rev: rev}}} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved), future())

      assert rev == first.state_rev
      assert write_counts() == before
    end

    test "a failing planned event rolls the plan back", %{w: w, approved: approved} do
      fail_event!("planned")
      before = write_counts()

      assert_raise Ecto.ConstraintError, fn ->
        Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved), future())
      end

      assert write_counts() == before
      assert fresh(approved) == approved
    end

    test "a non-approver cannot plan", %{w: w, approved: approved} do
      stranger = user!() |> member!(w.org_id)
      before = write_counts()

      for id <- [stranger.id, w.agent.id, w.outsider.id] do
        assert {:error, reason} =
                 Studio.plan_post(w.org_id, approved.id, id, expect(approved), future())

        assert reason in ~w(not_a_human not_an_approver approver_no_access)a
      end

      assert write_counts() == before
    end

    test "an archived account refuses plan", %{w: w, approved: approved} do
      {:ok, _} = Social.archive_account(w.org_id, w.x)

      assert {:error, :account_archived} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved), future())
    end
  end

  describe "pinned ownership tests" do
    setup %{w: w} do
      u1 = user!() |> member!(w.org_id)
      u2 = user!() |> member!(w.org_id)
      post = submitted_post!(w, w.tiktok)
      {:ok, acct} = Social.set_account_owner(w.org_id, w.tiktok, u1.id)
      approved = studio_approve!(w, post, u1)
      planned = studio_plan!(w, approved, u1)
      {:ok, _} = Social.set_account_owner(w.org_id, acct, u2.id)
      %{u1: u1, u2: u2, planned: planned, acct: acct}
    end

    test "former owner cannot plan, replan, cancel, approve or retarget",
         %{w: w, u1: u1, planned: planned} do
      before = write_counts()

      for call <- [
            fn -> Studio.plan_post(w.org_id, planned.id, u1.id, expect(planned), future()) end,
            fn -> Studio.cancel_plan(w.org_id, planned.id, u1.id, expect(planned)) end,
            fn -> Studio.approve_version(w.org_id, planned.id, u1.id, expect(planned)) end,
            fn ->
              Studio.save_version(
                w.org_id,
                planned.id,
                {:human, u1.id},
                %{account_id: w.x.id},
                expect(planned)
              )
            end
          ] do
        assert {:error, :not_the_owner} = call.()
      end

      assert write_counts() == before
    end

    test "new owner: plan is :approval_needs_refresh, cancel works, re-approve then plan",
         %{w: w, u2: u2, planned: planned} do
      before = write_counts()

      assert {:error, :approval_needs_refresh} =
               Studio.plan_post(w.org_id, planned.id, u2.id, expect(planned), future())

      assert write_counts() == before
      assert fresh(planned) == planned

      # cancel works for the new owner and keeps the receipt
      assert {:ok, cancelled} = Studio.cancel_plan(w.org_id, planned.id, u2.id, expect(planned))
      assert cancelled.status == "approved"
      assert [%{state: "current"}] = receipts(planned)

      # a replan is still refused (b), until a fresh approval
      assert {:error, :approval_needs_refresh} =
               Studio.plan_post(w.org_id, planned.id, u2.id, expect(cancelled), future())

      assert {:ok, %{post: reapproved}} =
               Studio.approve_version(w.org_id, planned.id, u2.id, expect(cancelled))

      assert [%{state: "superseded"}, %{state: "current"}] = receipts(planned)

      assert {:ok, %{post: %{status: "planned"}}} =
               Studio.plan_post(w.org_id, planned.id, u2.id, expect(reapproved), future())
    end
  end

  describe "cancel_plan/4" do
    test "returns to approved, keeps the receipt, clears the plan, stays unpublishable",
         %{w: w, approved: approved} do
      planned = studio_plan!(w, approved)

      assert {:ok, %Post{} = cancelled} =
               Studio.cancel_plan(w.org_id, planned.id, w.approver.id, expect(planned))

      assert cancelled.status == "approved"
      assert cancelled.scheduled_at == nil
      assert cancelled.planned_by_user_id == nil
      assert cancelled.planned_set_at == nil
      assert cancelled.state_rev == planned.state_rev + 1
      assert cancelled.approved_by_user_id == w.approver.id
      assert [%{state: "current"}] = receipts(planned)
      assert actions(planned) == ~w(created submitted approved planned plan_cancelled)

      refute Publishing.publishable?(cancelled)
      assert {:error, :studio_post} = Publishing.publish_post(w.org_id, cancelled.id)
      assert send_calls() == []
    end

    test ":not_planned for an approved post; stale for an old state_rev",
         %{w: w, approved: approved} do
      before = write_counts()

      assert {:error, :not_planned} =
               Studio.cancel_plan(w.org_id, approved.id, w.approver.id, expect(approved))

      assert write_counts() == before

      planned = studio_plan!(w, approved)
      before = write_counts()

      assert {:error, {:stale, _}} =
               Studio.cancel_plan(w.org_id, planned.id, w.approver.id, expect(approved))

      assert write_counts() == before
    end

    test "a failing plan_cancelled event rolls back", %{w: w, approved: approved} do
      planned = studio_plan!(w, approved)
      fail_event!("plan_cancelled")
      before = write_counts()

      assert_raise Ecto.ConstraintError, fn ->
        Studio.cancel_plan(w.org_id, planned.id, w.approver.id, expect(planned))
      end

      assert write_counts() == before
      assert fresh(planned) == planned
    end

    test "a live owner is exclusive for cancel; profile approvers are refused", %{w: w} do
      owner = user!() |> member!(w.org_id)
      post = submitted_post!(w, w.tiktok)
      {:ok, acct} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)
      planned = studio_plan!(w, studio_approve!(w, post, owner), owner)
      before = write_counts()

      assert {:error, :not_the_owner} =
               Studio.cancel_plan(w.org_id, planned.id, w.approver.id, expect(planned))

      assert write_counts() == before
      assert {:ok, _} = Studio.cancel_plan(w.org_id, planned.id, owner.id, expect(planned))
      _ = acct
    end

    test "with the owner archived, a profile approver may cancel but never approve or plan",
         %{w: w} do
      owner = user!() |> member!(w.org_id)
      post = submitted_post!(w, w.tiktok)
      {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)
      planned = studio_plan!(w, studio_approve!(w, post, owner), owner)
      {:ok, _} = Platform.Accounts.archive_user(owner)
      stranger = user!() |> member!(w.org_id)

      before = write_counts()

      assert {:error, :not_an_approver} =
               Studio.cancel_plan(w.org_id, planned.id, stranger.id, expect(planned))

      assert {:error, :not_the_owner} =
               Studio.plan_post(w.org_id, planned.id, w.approver.id, expect(planned), future())

      assert {:error, :not_the_owner} =
               Studio.approve_version(w.org_id, planned.id, w.approver.id, expect(planned))

      assert write_counts() == before

      assert {:ok, cancelled} =
               Studio.cancel_plan(w.org_id, planned.id, w.approver.id, expect(planned))

      assert cancelled.status == "approved"
      # cancelling granted nothing: the approver still cannot plan the same post
      assert {:error, :not_the_owner} =
               Studio.plan_post(w.org_id, planned.id, w.approver.id, expect(cancelled), future())
    end

    test "cancel is allowed on an archived account, everything else is refused",
         %{w: w, approved: approved} do
      planned = studio_plan!(w, approved)
      {:ok, _} = Social.archive_account(w.org_id, w.x)

      assert {:error, :account_archived} =
               Studio.approve_version(w.org_id, planned.id, w.approver.id, expect(planned))

      assert {:error, :account_archived} =
               Studio.revoke_approval(w.org_id, planned.id, w.approver.id, expect(planned))

      assert {:ok, %{status: "approved"}} =
               Studio.cancel_plan(w.org_id, planned.id, w.approver.id, expect(planned))
    end
  end
end
