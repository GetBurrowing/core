defmodule Platform.Social.StudioChecklistTest do
  @moduledoc """
  Cases from the independent slice B review that no
  other file pins as such: re-approval and planning for the approved and unowned
  variants, a retarget needing both destinations (with history),
  a retarget collision with receipts and plans, and a repeated request
  being stale, even after the statuses cycle.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.Studio

  setup do
    w = studio_world!()

    {:ok, third} =
      Social.create_account(w.org_id, w.profile, %{platform: "linkedin", handle: "@chk3"})

    %{w: w, third: third}
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  defp own!(w, account, user) do
    {:ok, account} = Social.set_account_owner(w.org_id, account, user.id)
    account
  end

  defp save(w, post, user, attrs),
    do: Studio.save_version(w.org_id, post.id, {:human, user.id}, attrs, expect(post))

  defp rows(post), do: {fresh(post), receipts(post), actions(post), write_counts()}

  describe "a new owner cannot plan on the former owner's receipt" do
    test "approved post: :approval_needs_refresh, receipt and history untouched", %{w: w} do
      u1 = user!() |> member!(w.org_id)
      u2 = user!() |> member!(w.org_id)
      post = submitted_post!(w, w.tiktok)
      acct = own!(w, w.tiktok, u1)
      approved = studio_approve!(w, post, u1)
      own!(w, acct, u2)
      before = rows(approved)

      assert {:error, :approval_needs_refresh} =
               Studio.plan_post(w.org_id, approved.id, u2.id, expect(approved), future())

      assert rows(approved) == before
      assert [%{state: "current"}] = receipts(approved)
    end
  end

  describe "re-approval refreshes authority, then planning is separate" do
    test "approved after an ownership change: new receipt, then a plan with fresh state_rev", %{
      w: w
    } do
      u1 = user!() |> member!(w.org_id)
      u2 = user!() |> member!(w.org_id)
      post = submitted_post!(w, w.tiktok)
      acct = own!(w, w.tiktok, u1)
      approved = studio_approve!(w, post, u1)
      own!(w, acct, u2)

      assert {:ok, %{post: re}} =
               Studio.approve_version(w.org_id, approved.id, u2.id, expect(approved))

      assert re.status == "approved" and re.scheduled_at == nil

      assert [%{state: "superseded", ended_reason: "authority changed"}, %{state: "current"}] =
               receipts(approved)

      assert actions(approved) == ~w(created submitted approved approved)

      # the old observation cannot plan
      assert {:error, {:stale, _}} =
               Studio.plan_post(w.org_id, approved.id, u2.id, expect(approved), future())

      assert {:ok, %{post: planned}} =
               Studio.plan_post(w.org_id, approved.id, u2.id, expect(re), future())

      assert planned.state_rev == re.state_rev + 1 and planned.version == re.version
      assert [_, %{state: "current"}] = receipts(approved)
    end

    test "unowned account: the receipt's approver leaves the list, another approver re-approves",
         %{w: w} do
      u1 = approver2!(w)
      approved = w |> submitted_post!(w.x) |> then(&studio_approve!(w, &1, u1))
      {:ok, _} = Social.update_profile(w.org_id, w.profile, %{approver_user_ids: [w.approver.id]})

      assert {:error, :approval_needs_refresh} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(approved), future())

      assert {:ok, %{approval: new}} =
               Studio.approve_version(w.org_id, approved.id, w.approver.id, expect(approved))

      assert new.approved_by_user_id == w.approver.id

      assert [%{state: "superseded", ended_reason: "authority changed"}, %{state: "current"}] =
               receipts(approved)
    end
  end

  describe "retarget needs authority at both destinations" do
    setup %{w: w, third: third} do
      u1 = user!() |> member!(w.org_id)
      u2 = user!() |> member!(w.org_id)
      %{u1: u1, u2: u2, a: w.x, b: third}
    end

    for status <- ~w(approved planned) do
      test "#{status}: A only and B only are refused, nothing changes; both succeeds",
           %{w: w, u1: u1, u2: u2, a: a, b: b} do
        status = unquote(status)
        post = studio_post!(w, a, "needs_approval")
        own!(w, a, u1)
        b = own!(w, b, u1)
        post = studio_approve!(w, post, u1)
        post = if status == "planned", do: studio_plan!(w, post, u1), else: post

        # B moves to u2: u1 is authorised on A only
        b = own!(w, b, u2)
        before = rows(post)
        assert {:error, :not_the_owner} = save(w, post, u1, %{account_id: b.id})
        assert rows(post) == before

        # u2 is authorised on B only: refused on A
        assert {:error, :not_the_owner} = save(w, post, u2, %{account_id: b.id})
        assert rows(post) == before

        # both: control
        own!(w, b, u1)

        assert {:ok, %{post: moved, revoked_approval: %{state: "superseded"}}} =
                 save(w, post, u1, %{account_id: b.id})

        assert moved.account_id == b.id
        assert moved.version == post.version + 1 and moved.state_rev == post.state_rev + 1
        assert moved.status == "needs_approval" and moved.scheduled_at == nil

        added = actions(post) -- ~w(created submitted approved planned)

        expected =
          ~w(retargeted version_saved approval_revoked) ++
            if(status == "planned", do: ~w(plan_cancelled), else: [])

        assert Enum.sort(added) == Enum.sort(expected)
      end
    end

    test "a draft stays a draft", %{w: w, u1: u1, b: b, a: a} do
      post = studio_post!(w, a, "draft")
      own!(w, a, u1)
      own!(w, b, u1)
      assert {:ok, %{post: moved}} = save(w, post, u1, %{account_id: b.id})
      assert {moved.status, moved.account_id} == {"draft", b.id}
    end
  end

  describe "a retarget collision leaves both posts and their history intact" do
    for status <- ~w(approved planned) do
      test "P_A #{status}: :duplicate_destination, receipts, plan and events untouched", %{w: w} do
        status = unquote(status)
        clip = w |> pending_clip!() |> make_studio_clip!()

        {:ok, %{posts: posts}} =
          Studio.accept_render(w.org_id, clip.id, w.approver.id, %{
            render_id: render_id!(clip),
            account_ids: [w.x.id, w.tiktok.id]
          })

        p_a = Enum.find(posts, &(&1.account_id == w.x.id))
        p_b = Enum.find(posts, &(&1.account_id == w.tiktok.id))
        p_a = studio_approve!(w, p_a)
        p_a = if status == "planned", do: studio_plan!(w, p_a), else: p_a
        before = {rows(p_a), rows(p_b)}

        assert {:error, :duplicate_destination} =
                 save(w, p_a, w.approver, %{account_id: w.tiktok.id})

        assert {rows(p_a), rows(p_b)} == before
        assert fresh(p_a).accepted_account_id == w.x.id
      end
    end
  end

  describe "a repeated request is stale" do
    defp repeats(w) do
      u = w.approver.id
      o = w.org_id

      [
        approve: {"needs_approval", fn p, e -> Studio.approve_version(o, p.id, u, e) end},
        plan: {"approved", fn p, e -> Studio.plan_post(o, p.id, u, e, future()) end},
        replan: {"planned", fn p, e -> Studio.plan_post(o, p.id, u, e, future()) end},
        cancel: {"planned", fn p, e -> Studio.cancel_plan(o, p.id, u, e) end},
        revoke:
          {"approved",
           fn p, e ->
             [%{id: id}] = receipts(p)
             Studio.revoke_approval(o, p.id, u, Map.put(e, :approval_id, id), "again")
           end},
        request_changes:
          {"needs_approval", fn p, e -> Studio.request_changes(o, p.id, u, e, "no") end},
        resubmit: {"rejected", fn p, e -> Studio.resubmit(o, p.id, u, e, "ok") end},
        save_version:
          {"needs_approval",
           fn p, e -> Studio.save_version(o, p.id, {:human, u}, %{body: "once"}, e) end},
        retarget:
          {"needs_approval",
           fn p, e -> Studio.save_version(o, p.id, {:human, u}, %{account_id: w.tiktok.id}, e) end}
      ]
    end

    test "the identical request twice: the first transitions, the second is stale and writes nothing",
         %{w: w} do
      for {name, {status, call}} <- repeats(w) do
        post =
          if status == "rejected" do
            p = studio_post!(w, w.x, "needs_approval")
            {:ok, r} = Studio.request_changes(w.org_id, p.id, w.approver.id, expect(p), "no")
            r
          else
            studio_post!(w, w.x, status)
          end

        observed = expect(post)
        assert {:ok, _} = call.(post, observed), "#{name} first call"
        after_first = {fresh(post), receipts(post), actions(post), write_counts()}

        assert {:error, {:stale, %{state_rev: r, version: v}}} = call.(post, observed), "#{name}"
        assert {r, v} == {fresh(post).state_rev, fresh(post).version}

        assert {fresh(post), receipts(post), actions(post), write_counts()} == after_first,
               "#{name}"

        assert fresh(post).state_rev == post.state_rev + 1, "#{name} bumps state_rev once"
      end
    end

    test "plan, cancel, plan again: the original plan request is still stale", %{w: w} do
      approved = w |> submitted_post!(w.x) |> then(&studio_approve!(w, &1))
      observed = expect(approved)

      assert {:ok, %{post: planned}} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, observed, future())

      assert {:ok, cancelled} =
               Studio.cancel_plan(w.org_id, approved.id, w.approver.id, expect(planned))

      assert {:ok, %{post: replanned}} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, expect(cancelled), future())

      assert replanned.status == "planned"
      before = rows(replanned)

      assert {:error, {:stale, %{state_rev: r}}} =
               Studio.plan_post(w.org_id, approved.id, w.approver.id, observed, future())

      assert r == replanned.state_rev
      assert rows(replanned) == before
    end
  end
end
