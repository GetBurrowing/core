defmodule Platform.Social.StudioSaveVersionTest do
  @moduledoc """
  Social Studio slice B: `Studio.save_version/5`, the only content writer for
  Studio rows, including retarget and the agent
  actor (draft and needs_approval only).
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.{PostEvents, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    %{w: w}
  end

  defp save(w, post, attrs, user \\ nil, ex \\ nil),
    do:
      Studio.save_version(
        w.org_id,
        post.id,
        {:human, (user || w.approver).id},
        attrs,
        ex || expect(post)
      )

  describe "editing in draft and needs_approval (no approval to revoke)" do
    test "bumps version and state_rev, keeps status, writes edited then version_saved", %{w: w} do
      post = submitted_post!(w, w.x)

      assert {:ok, %{post: saved, version: 2, revoked_approval: nil, cancelled_plan?: false}} =
               save(w, post, %{body: "Second draft"})

      assert {saved.body, saved.version, saved.state_rev, saved.status} ==
               {"Second draft", 2, post.state_rev + 1, "needs_approval"}

      assert actions(post) == ~w(created submitted edited version_saved)
      [_, _, edited, saved_ev] = PostEvents.list_for_post(post.id)
      assert {edited.body_before, edited.body_after} == {post.body, "Second draft"}
      assert saved_ev.post_version == 2
      assert send_calls() == []
    end

    test "a draft stays a draft; a non-body edit writes no edited event", %{w: w} do
      post = studio_post!(w, w.x, "draft")
      assert {:ok, %{post: saved}} = save(w, post, %{link_url: "https://example.test/a"})

      assert {saved.status, saved.link_url, saved.version} ==
               {"draft", "https://example.test/a", 2}

      assert actions(post) == ~w(created version_saved)
    end

    test "nothing to change is :no_changes and writes nothing", %{w: w} do
      post = submitted_post!(w, w.x)
      before = write_counts()
      assert {:error, :no_changes} = save(w, post, %{body: post.body})
      assert {:error, :no_changes} = save(w, post, %{})
      assert write_counts() == before
    end

    test "unknown or forbidden keys are refused up front", %{w: w} do
      post = submitted_post!(w, w.x)
      before = write_counts()

      assert {:error, {:field_not_allowed, keys}} =
               save(w, post, %{body: "x", status: "approved", scheduled_at: DateTime.utc_now()})

      assert Enum.sort(keys) == ["scheduled_at", "status"]
      assert write_counts() == before
    end
  end

  describe "editing approved or planned content revokes, server side" do
    for {field, value} <- [
          body: "New body",
          link_url: "https://example.test/new",
          media_file_ids: ["0191a7a0-0000-7000-8000-000000000001"],
          platform_options: %{"alt_text" => "Fresh"},
          is_aigc: true,
          ai_disclosure: "Made with AI"
        ] do
      test "changing #{field} ends the current approval in the same transaction", %{w: w} do
        approved = studio_approve!(w, submitted_post!(w, w.x))

        assert {:ok, %{post: saved, revoked_approval: revoked, cancelled_plan?: false}} =
                 save(w, approved, %{unquote(field) => unquote(Macro.escape(value))})

        assert saved.status == "needs_approval"
        assert saved.version == 2
        assert saved.approved_by_user_id == nil
        assert saved.approved_at == nil
        assert revoked.state == "superseded"

        assert [%{state: "superseded", version: 1, ended_reason: "version changed"}] =
                 receipts(approved)
      end
    end

    test "the superseded row is kept and the next approval names version 2", %{w: w} do
      approved = studio_approve!(w, submitted_post!(w, w.x))
      {:ok, %{post: saved}} = save(w, approved, %{body: "Edited"})

      {:ok, %{approval: second}} =
        Studio.approve_version(w.org_id, saved.id, w.approver.id, expect(saved))

      assert second.version == 2
      assert second.account_id == w.x.id

      assert [%{state: "superseded", version: 1}, %{state: "current", version: 2}] =
               receipts(approved)

      assert actions(approved) ==
               ~w(created submitted approved edited version_saved approval_revoked approved)
    end

    test "a planned post also clears the plan and writes plan_cancelled", %{w: w} do
      planned = studio_plan!(w, studio_approve!(w, submitted_post!(w, w.x)))

      assert {:ok, %{post: saved, cancelled_plan?: true}} = save(w, planned, %{body: "Changed"})

      assert {saved.status, saved.scheduled_at, saved.planned_by_user_id} ==
               {"needs_approval", nil, nil}

      assert actions(planned) ==
               ~w(created submitted approved planned edited version_saved approval_revoked plan_cancelled)
    end

    test "editing through Social.update_post (legacy) stays refused and leaves the approval", %{
      w: w
    } do
      approved = studio_approve!(w, submitted_post!(w, w.x))
      assert {:error, :studio_post} = Social.update_post(w.org_id, approved, %{body: "sneaky"})
      assert [%{state: "current"}] = receipts(approved)
    end
  end

  describe "authority, receipts and races" do
    test "stale version and stale state_rev write nothing", %{w: w} do
      post = submitted_post!(w, w.x)
      {:ok, _} = save(w, post, %{body: "winner"})
      before = write_counts()

      assert {:error, {:stale, %{state_rev: 1, version: 2}}} = save(w, post, %{body: "loser"})
      assert {:error, :expect_required} = save(w, post, %{body: "loser"}, nil, %{})
      assert write_counts() == before
    end

    test "non-approvers are refused for every class", %{w: w} do
      post = submitted_post!(w, w.x)
      stranger = user!() |> member!(w.org_id)
      before = write_counts()

      for id <- [stranger.id, w.agent.id, w.outsider.id] do
        assert {:error, reason} =
                 Studio.save_version(w.org_id, post.id, {:human, id}, %{body: "x"}, expect(post))

        assert reason in ~w(not_a_human not_an_approver approver_no_access)a
      end

      assert write_counts() == before
    end

    test "an archived account refuses an ordinary edit", %{w: w} do
      post = submitted_post!(w, w.x)
      {:ok, _} = Social.archive_account(w.org_id, w.x)
      before = write_counts()
      assert {:error, :account_archived} = save(w, post, %{body: "x"})
      assert write_counts() == before
    end

    test "a failing version_saved event rolls the edit and the revoke back", %{w: w} do
      approved = studio_approve!(w, submitted_post!(w, w.x))
      fail_event!("version_saved")
      before = write_counts()
      assert_raise Ecto.ConstraintError, fn -> save(w, approved, %{body: "boom"}) end
      assert write_counts() == before
      assert fresh(approved) == approved
      assert [%{state: "current"}] = receipts(approved)
    end

    test "a failing approval_revoked event rolls back (last event of the set)", %{w: w} do
      approved = studio_approve!(w, submitted_post!(w, w.x))
      fail_event!("approval_revoked")
      assert_raise Ecto.ConstraintError, fn -> save(w, approved, %{body: "boom"}) end
      assert fresh(approved) == approved
      assert [%{state: "current"}] = receipts(approved)
    end
  end

  describe "agents (draft and needs_approval only)" do
    test "an agent saves a version in draft and needs_approval with an agent actor", %{w: w} do
      for status <- ~w(draft needs_approval) do
        post = studio_post!(w, w.x, status)

        assert {:ok, %{post: saved}} =
                 Studio.save_version(
                   w.org_id,
                   post.id,
                   {:agent, w.agent.id},
                   %{body: "agent #{status}"},
                   expect(post)
                 )

        assert saved.version == 2
        assert saved.status == status

        edits =
          Enum.filter(PostEvents.list_for_post(post.id), &(&1.action in ~w(edited version_saved)))

        assert Enum.map(edits, &{&1.actor_kind, &1.actor_id}) == [
                 {"agent", w.agent.id},
                 {"agent", w.agent.id}
               ]
      end
    end

    test "an agent is :post_locked on approved and planned, and cannot retarget", %{w: w} do
      approved = studio_approve!(w, submitted_post!(w, w.x))
      planned = studio_plan!(w, studio_approve!(w, submitted_post!(w, w.tiktok)))
      draft = studio_post!(w, w.x, "draft")
      before = write_counts()

      for post <- [approved, planned] do
        assert {:error, :post_locked} =
                 Studio.save_version(
                   w.org_id,
                   post.id,
                   {:agent, w.agent.id},
                   %{body: "no"},
                   expect(post)
                 )
      end

      assert {:error, :agent_cannot_retarget} =
               Studio.save_version(
                 w.org_id,
                 draft.id,
                 {:agent, w.agent.id},
                 %{account_id: w.tiktok.id},
                 expect(draft)
               )

      assert write_counts() == before
    end
  end

  describe "retarget" do
    test "approved to another account: needs_approval, version +1, old receipt superseded", %{
      w: w
    } do
      approved = studio_approve!(w, submitted_post!(w, w.x))

      assert {:ok, %{post: moved, revoked_approval: revoked}} =
               save(w, approved, %{account_id: w.tiktok.id})

      assert {moved.account_id, moved.status, moved.version} == {w.tiktok.id, "needs_approval", 2}
      assert {revoked.state, revoked.account_id} == {"superseded", w.x.id}

      assert Enum.find(receipts(approved), &(&1.id == revoked.id)).ended_reason ==
               "account changed"

      assert actions(approved) ==
               ~w(created submitted approved retargeted version_saved approval_revoked)

      evs = PostEvents.list_for_post(approved.id)
      retargeted = Enum.find(evs, &(&1.action == "retargeted"))
      assert retargeted.account_id == w.tiktok.id
      assert retargeted.note =~ w.x.id and retargeted.note =~ w.tiktok.id
      revoked_ev = Enum.find(evs, &(&1.action == "approval_revoked"))
      assert {revoked_ev.account_id, revoked_ev.post_version} == {w.x.id, 1}
    end

    test "planned adds plan_cancelled; draft stays draft; needs_approval stays", %{w: w} do
      planned = studio_plan!(w, studio_approve!(w, submitted_post!(w, w.x)))

      assert {:ok, %{post: moved, cancelled_plan?: true}} =
               save(w, planned, %{account_id: w.tiktok.id})

      assert {moved.status, moved.scheduled_at} == {"needs_approval", nil}

      assert actions(planned) ==
               ~w(created submitted approved planned retargeted version_saved approval_revoked plan_cancelled)

      draft = studio_post!(w, w.x, "draft")
      assert {:ok, %{post: d}} = save(w, draft, %{account_id: w.tiktok.id})
      assert d.status == "draft"
      assert actions(draft) == ~w(created retargeted version_saved)

      na = submitted_post!(w, w.x)
      assert {:ok, %{post: n}} = save(w, na, %{account_id: w.tiktok.id})
      assert n.status == "needs_approval"
    end

    test "needs the approver check on BOTH accounts", %{w: w} do
      post = submitted_post!(w, w.x)
      owner = user!() |> member!(w.org_id)
      {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)
      before = write_counts()

      # new account owned by someone else: the profile approver fails on it
      assert {:error, :not_the_owner} = save(w, post, %{account_id: w.tiktok.id})
      # the owner of the new account is no approver of the old (unowned) one
      assert {:error, :not_an_approver} =
               Studio.save_version(
                 w.org_id,
                 post.id,
                 {:human, owner.id},
                 %{account_id: w.tiktok.id},
                 expect(post)
               )

      assert write_counts() == before
    end

    test "new account must be live, in the same profile and org", %{w: w} do
      post = submitted_post!(w, w.x)
      {:ok, _} = Social.archive_account(w.org_id, w.tiktok)
      other_profile = second_profile!(w)
      before = write_counts()

      assert {:error, :account_archived} = save(w, post, %{account_id: w.tiktok.id})

      # An account of another profile is indistinguishable from no account
      assert {:error, :not_found} = save(w, post, %{account_id: other_profile.account.id})

      assert {:error, :not_found} = save(w, post, %{account_id: Ecto.UUID.generate()})
      assert write_counts() == before
    end

    test "from an archived account only a retarget is allowed", %{w: w} do
      post = submitted_post!(w, w.x)
      {:ok, _} = Social.archive_account(w.org_id, w.x)
      stranger = user!() |> member!(w.org_id)
      before = write_counts()

      assert {:error, :account_archived} = save(w, post, %{body: "edit"})

      assert {:error, :not_an_approver} =
               Studio.save_version(
                 w.org_id,
                 post.id,
                 {:human, stranger.id},
                 %{account_id: w.tiktok.id},
                 expect(post)
               )

      assert write_counts() == before
      assert {:ok, %{post: moved}} = save(w, post, %{account_id: w.tiktok.id})
      assert moved.account_id == w.tiktok.id
    end

    test "archived account with an archived owner: a profile approver may move it, a stranger may not",
         %{w: w} do
      post = submitted_post!(w, w.tiktok)
      owner = user!() |> member!(w.org_id)
      {:ok, acct} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)
      {:ok, _} = Platform.Accounts.archive_user(owner)
      {:ok, _} = Social.archive_account(w.org_id, acct)
      stranger = user!() |> member!(w.org_id)
      before = write_counts()

      assert {:error, :not_an_approver} =
               Studio.save_version(
                 w.org_id,
                 post.id,
                 {:human, stranger.id},
                 %{account_id: w.x.id},
                 expect(post)
               )

      assert write_counts() == before
      assert {:ok, %{post: moved}} = save(w, post, %{account_id: w.x.id})
      assert moved.account_id == w.x.id
    end

    test "a LIVE owner of an archived account stays exclusive for the retarget", %{w: w} do
      post = submitted_post!(w, w.tiktok)
      owner = user!() |> member!(w.org_id)
      {:ok, acct} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)
      {:ok, _} = Social.archive_account(w.org_id, acct)
      before = write_counts()
      assert {:error, :not_the_owner} = save(w, post, %{account_id: w.x.id})
      assert write_counts() == before
    end

    test "a failing retargeted event rolls back", %{w: w} do
      post = submitted_post!(w, w.x)
      fail_event!("retargeted")
      assert_raise Ecto.ConstraintError, fn -> save(w, post, %{account_id: w.tiktok.id}) end
      assert fresh(post) == post
    end
  end

  # A second profile (same org) with one account, for the cross-profile refusal.
  defp second_profile!(w) do
    {:ok, profile} =
      Social.create_profile(w.org_id, %{
        name: "Other show #{unique()}",
        project_id: w.project.id,
        home_url: "https://www.youtube.com/@othershow",
        approver_user_ids: [w.approver.id]
      })

    {:ok, account} = Social.create_account(w.org_id, profile, %{platform: "x", handle: "@other"})
    %{profile: profile, account: account}
  end
end
