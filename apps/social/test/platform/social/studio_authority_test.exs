defmodule Platform.Social.StudioAuthorityTest do
  @moduledoc """
  Social Studio slice B: a non-approver cannot approve, plan, cancel,
  revoke, request changes, resubmit, save a version, retarget or accept, by any
  Studio context path, and nothing is written. One matrix: every function x
  every actor class, each asserting an `{:error, reason}`, the exact reason
  family, and unchanged post, event and receipt counts.

  The post sits on an OWNED account whose ownership moved from U1 to U2 after
  U1 approved, planned and rejected things, so "former owner" is real.
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
    u1 = user!() |> member!(w.org_id)
    u2 = user!() |> member!(w.org_id)

    # Create everything while the account is unowned (the approver creates),
    # then hand it to U1, let U1 act, then hand it to U2.
    posts = %{
      approve: submitted_post!(w, w.tiktok),
      plan: submitted_post!(w, w.tiktok),
      cancel: submitted_post!(w, w.tiktok),
      revoke: submitted_post!(w, w.tiktok),
      changes: submitted_post!(w, w.tiktok),
      resubmit: submitted_post!(w, w.tiktok),
      save: submitted_post!(w, w.tiktok),
      retarget: submitted_post!(w, w.tiktok)
    }

    {:ok, acct} = Social.set_account_owner(w.org_id, w.tiktok, u1.id)

    plan = studio_approve!(w, posts.plan, u1)
    cancel = studio_plan!(w, studio_approve!(w, posts.cancel, u1), u1)
    revoke = studio_approve!(w, posts.revoke, u1)

    {:ok, resubmit} =
      Studio.request_changes(w.org_id, posts.resubmit.id, u1.id, expect(posts.resubmit), "redo")

    clip = w |> pending_clip!() |> make_studio_clip!()

    {:ok, _} = Social.set_account_owner(w.org_id, acct, u2.id)

    posts = %{posts | plan: plan, cancel: cancel, revoke: revoke, resubmit: resubmit}
    %{w: w, u1: u1, u2: u2, posts: posts, clip: clip}
  end

  defp calls(%{w: w, posts: p, clip: clip}) do
    org = w.org_id
    future = DateTime.add(DateTime.utc_now(), 3_600, :second)
    receipt_id = fn post -> hd(receipts(post)).id end

    [
      approve: fn u -> Studio.approve_version(org, p.approve.id, u, expect(p.approve)) end,
      plan: fn u -> Studio.plan_post(org, p.plan.id, u, expect(p.plan), future) end,
      cancel: fn u -> Studio.cancel_plan(org, p.cancel.id, u, expect(p.cancel)) end,
      revoke: fn u ->
        Studio.revoke_approval(
          org,
          p.revoke.id,
          u,
          expect(p.revoke, %{approval_id: receipt_id.(p.revoke)}),
          "x"
        )
      end,
      request_changes: fn u ->
        Studio.request_changes(org, p.changes.id, u, expect(p.changes), "x")
      end,
      resubmit: fn u -> Studio.resubmit(org, p.resubmit.id, u, expect(p.resubmit), "x") end,
      save_version: fn u ->
        Studio.save_version(org, p.save.id, {:human, u}, %{body: "new"}, expect(p.save))
      end,
      retarget: fn u ->
        Studio.save_version(
          org,
          p.retarget.id,
          {:human, u},
          %{account_id: w.x.id},
          expect(p.retarget)
        )
      end,
      accept_render: fn u ->
        Studio.accept_render(org, clip.id, u, %{
          render_id: render_id!(clip),
          account_ids: [w.tiktok.id]
        })
      end
    ]
  end

  @refusals ~w(not_a_human approver_archived not_an_approver approver_no_access not_the_owner)a

  test "every function refuses every non-approver class and writes nothing", ctx do
    %{w: w, u1: u1} = ctx
    archived = approver2!(w)
    {:ok, _} = Platform.Accounts.archive_user(archived)
    other_owner = user!() |> member!(w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.x, other_owner.id)

    classes = [
      agent: w.agent.id,
      unlisted_member: (user!() |> member!(w.org_id)).id,
      archived_user: archived.id,
      owner_of_another_account: other_owner.id,
      former_owner: u1.id,
      listed_approver_of_owned_account: w.approver.id,
      wrong_org: w.outsider.id
    ]

    for {fun_name, call} <- calls(ctx), {class, user_id} <- classes do
      # retarget also needs the NEW account (x, owned by someone else now) -
      # the cases above fail on the old one first, which is the point.
      before = write_counts()

      reason =
        case call.(user_id) do
          # accept_render answers in the destinations envelope
          {:error, {:destinations, [%{reason: reason}]}} -> reason
          {:error, reason} -> reason
          other -> flunk("#{fun_name} as #{class} was not refused: #{inspect(other)}")
        end

      assert reason in @refusals, "#{fun_name} as #{class}: #{inspect(reason)}"
      assert write_counts() == before, "#{fun_name} as #{class} wrote rows"
    end

    # Posts untouched.
    for {_name, post} <- ctx.posts, do: assert(fresh(post) == post)
    assert send_calls() == []
  end

  test "the current owner passes every check the matrix refuses others on (not vacuous)", ctx do
    %{w: w, u2: u2} = ctx
    all = Map.new(calls(ctx))

    assert {:ok, %{post: %{status: "approved"}}} = all.approve.(u2.id)
    assert {:error, :approval_needs_refresh} = all.plan.(u2.id)
    assert {:ok, %{status: "approved"}} = all.cancel.(u2.id)
    assert {:ok, %{status: "needs_approval"}} = all.revoke.(u2.id)
    assert {:ok, %{status: "draft"}} = all.request_changes.(u2.id)
    assert {:ok, %{status: "needs_approval"}} = all.resubmit.(u2.id)
    assert {:ok, %{post: %{version: 2}}} = all.save_version.(u2.id)
    assert {:ok, %{posts: [_]}} = all.accept_render.(u2.id)
    # retarget needs approver rights on the unowned target too: U2 is not a profile approver.
    assert {:error, :not_an_approver} = all.retarget.(u2.id)
    _ = w
  end
end
