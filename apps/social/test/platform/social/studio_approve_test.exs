defmodule Platform.Social.StudioApproveTest do
  @moduledoc """
  Social Studio slice B: `Studio.approve_version/4`, `list_approvals/2` and
  `Approvals.content_fingerprint/1`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Approvals, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    %{w: w, post: submitted_post!(w, w.x)}
  end

  describe "approving is not planning" do
    test "approve leaves scheduled_at nil, status approved, and never touches a publisher",
         %{w: w, post: post} do
      assert {:ok, %{post: approved, approval: approval}} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))

      assert approved.status == "approved"
      assert approved.scheduled_at == nil
      assert approved.publish_after == nil
      assert approved.approved_by_user_id == w.approver.id
      assert approved.state_rev == post.state_rev + 1
      assert approved.version == post.version
      assert approval.state == "current"
      assert send_calls() == []
      assert Fake.calls() == []
    end
  end

  describe "one receipt names one version and one account" do
    test "the receipt carries version, account, approver and the content fingerprint",
         %{w: w, post: post} do
      {:ok, %{approval: approval}} =
        Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))

      assert approval.post_id == post.id
      assert approval.version == 1
      assert approval.account_id == w.x.id
      assert approval.approved_by_user_id == w.approver.id
      assert approval.content_fingerprint == Approvals.content_fingerprint(fresh(post))
      assert %DateTime{} = approval.approved_at
      assert approval.snapshot["body"] == post.body
    end

    test "list_approvals is newest first and scoped to the org", %{w: w, post: post} do
      approved = studio_approve!(w, post)
      approver2 = approver2!(w)
      {:ok, _} = Social.set_account_owner(w.org_id, w.x, approver2.id)

      {:ok, _} =
        Studio.approve_version(w.org_id, post.id, approver2.id, expect(approved))

      assert {:ok, [newest, oldest]} = Studio.list_approvals(w.org_id, post.id)
      assert newest.state == "current"
      assert oldest.state == "superseded"
      assert {:error, :not_found} = Studio.list_approvals(w.other_org_id, post.id)
    end
  end

  describe "content_fingerprint/1" do
    test "ignores the schedule, covers account, body, link, media, cover and options", %{
      post: post
    } do
      base = Approvals.content_fingerprint(post)
      assert base == Approvals.content_fingerprint(%{post | scheduled_at: DateTime.utc_now()})
      assert base != Approvals.content_fingerprint(%{post | body: "different"})
      assert base != Approvals.content_fingerprint(%{post | link_url: "https://x.test/a"})

      assert base !=
               Approvals.content_fingerprint(%{post | media_file_ids: [Ecto.UUID.generate()]})

      assert base != Approvals.content_fingerprint(%{post | account_id: Ecto.UUID.generate()})
      assert base != Approvals.content_fingerprint(%{post | platform_options: %{"a" => "b"}})
      assert base != Approvals.content_fingerprint(%{post | is_aigc: true})
      assert base != Approvals.content_fingerprint(%{post | ai_disclosure: "ai"})
      assert base != Approvals.content_fingerprint(%{post | cover_offset_ms: 5})
      # legacy fingerprint is unchanged and DOES cover the schedule
      refute Approvals.fingerprint(post) ==
               Approvals.fingerprint(%{post | scheduled_at: DateTime.utc_now()})
    end

    test "a shown fingerprint that no longer matches is stale and writes nothing",
         %{w: w, post: post} do
      before = write_counts()

      assert {:error, {:stale, _}} =
               Studio.approve_version(
                 w.org_id,
                 post.id,
                 w.approver.id,
                 expect(post, %{fingerprint: "not-the-content"})
               )

      assert write_counts() == before

      assert {:ok, _} =
               Studio.approve_version(
                 w.org_id,
                 post.id,
                 w.approver.id,
                 expect(post, %{fingerprint: Approvals.content_fingerprint(post)})
               )
    end
  end

  describe "history" do
    test "writes exactly one approved event", %{w: w, post: post} do
      studio_approve!(w, post)
      assert actions(post) == ~w(created submitted approved)
      [_, _, ev] = Platform.Social.PostEvents.list_for_post(post.id)

      assert {ev.actor_kind, ev.actor_id, ev.post_version, ev.account_id} ==
               {"human", w.approver.id, 1, w.x.id}
    end

    test "a failing event insert rolls the whole approval back", %{w: w, post: post} do
      fail_event!("approved")
      before = write_counts()

      assert_raise Ecto.ConstraintError, fn ->
        Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))
      end

      assert write_counts() == before
      assert fresh(post) == post
    end

    test "a repeated call carries the old state_rev: stale, no second receipt, no event",
         %{w: w, post: post} do
      studio_approve!(w, post)
      before = write_counts()

      assert {:error, {:stale, %{state_rev: 1, version: 1}}} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))

      assert write_counts() == before
    end
  end

  describe "stale tokens and the expect map" do
    test "a stale version alone is stale", %{w: w, post: post} do
      before = write_counts()

      assert {:error, {:stale, %{version: 1}}} =
               Studio.approve_version(
                 w.org_id,
                 post.id,
                 w.approver.id,
                 %{state_rev: post.state_rev, version: 7}
               )

      assert write_counts() == before
    end

    test "expect without state_rev is refused", %{w: w, post: post} do
      before = write_counts()

      assert {:error, :expect_required} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, %{})

      assert write_counts() == before
    end
  end

  describe "check order" do
    test "wrong org reads not_found", %{w: w, post: post} do
      assert {:error, :not_found} =
               Studio.approve_version(w.other_org_id, post.id, w.approver.id, expect(post))
    end

    test "studio disabled", %{w: w, post: post} do
      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      before = write_counts()

      assert {:error, :studio_disabled} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))

      assert write_counts() == before
    end

    test "a legacy post is not a studio post", %{w: w} do
      {:ok, legacy} =
        Social.create_post(w.org_id, w.x, %{body: "legacy", status: "needs_approval"})

      assert {:error, :not_studio_post} =
               Studio.approve_version(w.org_id, legacy.id, w.approver.id, expect(legacy))
    end

    test "an archived account refuses before the actor check, so a stranger also sees it",
         %{w: w, post: post} do
      {:ok, _} = Social.archive_account(w.org_id, w.x)
      stranger = user!()

      assert {:error, :account_archived} =
               Studio.approve_version(w.org_id, post.id, stranger.id, expect(post))

      assert {:error, :account_archived} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))

      assert fresh(post) == post
    end

    test "a stranger is refused by the actor check before staleness is revealed",
         %{w: w, post: post} do
      stranger = user!()

      assert {:error, :not_an_approver} =
               Studio.approve_version(w.org_id, post.id, stranger.id, %{
                 state_rev: 99,
                 version: 99
               })
    end

    test "social.use denied on the project refuses, nothing written", %{w: w, post: post} do
      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "social.use",
          resource: {:project, w.project.id}
        })

      before = write_counts()

      assert {:error, :no_social_access} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))

      assert write_counts() == before
    end

    test "a profile without a live project refuses with studio_needs_project", %{w: w, post: post} do
      Repo.update_all(from(p in Social.Profile, where: p.id == ^w.profile.id),
        set: [project_id: nil]
      )

      assert {:error, :studio_needs_project} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, expect(post))
    end

    test "only a needs_approval post can be approved first time", %{w: w} do
      draft = studio_post!(w, w.x, "draft")

      assert {:error, :not_awaiting_approval} =
               Studio.approve_version(w.org_id, draft.id, w.approver.id, expect(draft))
    end

    test "approving an approved post whose approver still passes is :already_approved",
         %{w: w, post: post} do
      approved = studio_approve!(w, post)

      assert {:error, :already_approved} =
               Studio.approve_version(w.org_id, post.id, w.approver.id, expect(approved))
    end
  end

  describe "non-approvers, by actor class" do
    defp actors(w) do
      owner_of_y = user!() |> member!(w.org_id)
      {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, owner_of_y.id)
      archived = approver2!(w)
      {:ok, _} = Platform.Accounts.archive_user(archived)

      [
        agent: w.agent.id,
        unlisted: user!() |> member!(w.org_id) |> Map.fetch!(:id),
        archived: archived.id,
        owner_of_another_account: owner_of_y.id,
        outsider: w.outsider.id
      ]
    end

    test "every class is refused and nothing is written", %{w: w, post: post} do
      for {class, id} <- actors(w) do
        before = write_counts()

        assert {:error, reason} =
                 Studio.approve_version(w.org_id, post.id, id, expect(post)),
               "class #{class}"

        assert reason in ~w(not_a_human approver_archived not_an_approver approver_no_access
                            not_the_owner)a,
               "class #{class}: #{inspect(reason)}"

        assert write_counts() == before
        assert fresh(post) == post
      end

      assert send_calls() == []
    end

    test "a listed approver of an OWNED account is refused (owner is exclusive)", %{w: w} do
      owner = user!() |> member!(w.org_id)
      owned = submitted_post!(w, w.tiktok)
      {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)

      assert {:error, :not_the_owner} =
               Studio.approve_version(w.org_id, owned.id, w.approver.id, expect(owned))

      assert {:ok, %{post: %{status: "approved"}}} =
               Studio.approve_version(w.org_id, owned.id, owner.id, expect(owned))
    end
  end

  describe "re-approval after an ownership change" do
    test "the new owner re-approves: new receipt, old superseded, plan cleared with plan_cancelled",
         %{w: w} do
      u1 = user!() |> member!(w.org_id)
      u2 = user!() |> member!(w.org_id)
      post = submitted_post!(w, w.tiktok)
      {:ok, acct} = Social.set_account_owner(w.org_id, w.tiktok, u1.id)
      approved = studio_approve!(w, post, u1)
      planned = studio_plan!(w, approved, u1)
      {:ok, _} = Social.set_account_owner(w.org_id, acct, u2.id)

      assert {:ok, %{post: after_re, approval: new}} =
               Studio.approve_version(w.org_id, post.id, u2.id, expect(planned))

      assert after_re.status == "approved"
      assert after_re.scheduled_at == nil
      assert after_re.planned_by_user_id == nil
      assert after_re.approved_by_user_id == u2.id
      assert after_re.version == planned.version
      assert after_re.state_rev == planned.state_rev + 1
      assert new.state == "current"
      assert new.version == planned.version

      assert [old, current] = receipts(post)
      assert {old.state, old.ended_reason} == {"superseded", "authority changed"}
      assert current.id == new.id
      assert actions(post) == ~w(created submitted approved planned approved plan_cancelled)
      [_, _, _, _, re_event, _] = Platform.Social.PostEvents.list_for_post(post.id)
      assert re_event.note =~ "authority changed"
      assert send_calls() == []
    end
  end
end
