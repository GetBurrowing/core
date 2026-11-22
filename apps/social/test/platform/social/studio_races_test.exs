defmodule Platform.Social.StudioRacesTest do
  @moduledoc """
  Social Studio slice B: the race table, with two real database
  connections (sandbox `:auto`, as in `StudioProfileLockConcurrencyTest`).

  Each race is made deterministic with a HOLDER: one process runs the first
  Studio call inside an outer transaction and keeps it open (so its row locks
  stay held and its writes uncommitted); the second process then makes its
  call, which must BLOCK on the post (or clip) lock; releasing the holder
  commits, and the second call reads the committed row and answers. So the
  order is fixed and the lock itself is what is tested, not scheduling luck.
  Every outcome also asserts the single receipt, event and `state_rev` the
  winner left, and that no publisher was called. The world is committed and
  purged by hand afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, Post, PostApproval, PostEvent, Profile, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Sandbox.mode(Repo, :auto)
    Fake.reset()
    n = System.unique_integer([:positive])

    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{name: "Race root #{n}", slug: "race-root-#{n}"}),
           true}

        root ->
          {root, false}
      end

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Race #{n}",
        slug: "race-#{n}",
        parent_org_id: root.id
      })

    user = fn tag ->
      u =
        Repo.insert!(%Platform.Accounts.User{
          email: "race-#{tag}-#{n}@example.com",
          oidc_sub: "race-#{tag}-#{n}",
          name: "Race #{tag} #{n}"
        })

      Repo.insert!(%Platform.Tenancy.OrgMembership{user_id: u.id, org_id: org.id, role: "member"})
      u
    end

    [u1, u2, u3] = Enum.map(~w(one two three), user)
    {:ok, project} = Platform.Tasks.create_project(%{name: "Race #{n}", org_id: org.id})

    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: "Race show #{n}",
        project_id: project.id,
        home_url: "https://www.youtube.com/@raceshow",
        approver_user_ids: [u1.id, u2.id]
      })

    {:ok, a} = Social.create_account(org.id, profile, %{platform: "x", handle: "@a#{n}"})
    {:ok, b} = Social.create_account(org.id, profile, %{platform: "tiktok", handle: "@b#{n}"})
    {:ok, c} = Social.create_account(org.id, profile, %{platform: "linkedin", handle: "@c#{n}"})
    {:ok, profile} = Studio.set_enabled(org.id, profile.id, u1.id, true)

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "race-agent-#{n}",
        name: "Race agent #{n}",
        metadata: %{"org_id" => org.id}
      })

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      profile_ids = Repo.all(from(p in Profile, where: p.org_id == ^org.id, select: p.id))

      post_ids =
        Repo.all(
          from(po in Post,
            join: ac in Platform.Social.Account,
            on: ac.id == po.account_id,
            where: ac.profile_id in ^profile_ids,
            select: po.id
          )
        )

      Repo.delete_all(from(r in PostApproval, where: r.post_id in ^post_ids))
      Repo.delete_all(from(po in Post, where: po.id in ^post_ids))
      Repo.delete_all(from(c in Clip, where: c.profile_id in ^profile_ids))
      Repo.delete_all(from(p in Profile, where: p.id in ^profile_ids))
      Repo.delete_all(from(f in Platform.Files.File, where: f.project_id == ^project.id))
      Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
      Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id in ^[u1.id, u2.id, u3.id]))
      Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^agent.id))
      Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id))
      if own_root?, do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
      Sandbox.mode(Repo, :manual)
    end)

    %{
      org: org,
      profile: profile,
      u1: u1,
      u2: u2,
      u3: u3,
      a: a,
      b: b,
      c: c,
      project: project,
      agent: agent
    }
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp post!(ctx, account, status \\ "needs_approval") do
    {:ok, post} =
      Studio.create_post(ctx.org.id, account.id, ctx.u1.id, %{
        body: "race #{System.unique_integer([:positive])}",
        status: status
      })

    post
  end

  defp expect(%Post{} = p, extra \\ %{}),
    do: Map.merge(%{state_rev: p.state_rev, version: p.version}, extra)

  defp row(%Post{id: id}), do: Repo.get!(Post, id)

  defp approve(ctx, post, user, ex \\ nil),
    do: Studio.approve_version(ctx.org.id, post.id, user.id, ex || expect(post))

  defp future, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  defp actions(post_id),
    do:
      Repo.all(
        from(e in PostEvent,
          where: e.post_id == ^post_id,
          order_by: [asc: e.inserted_at, asc: e.id],
          select: e.action
        )
      )

  defp states(post_id),
    do:
      Repo.all(
        from(r in PostApproval,
          where: r.post_id == ^post_id,
          order_by: [asc: r.approved_at, asc: r.id],
          select: {r.version, r.state}
        )
      )

  # Runs `fun` inside an outer transaction that stays open until `release/1`.
  defp hold(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = fun.()
          send(parent, {:held, self(), result})

          receive do
            :release -> result
          after
            10_000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:held, _pid, result}, 5_000
    {task, result}
  end

  defp release({task, _result}) do
    send(task.pid, :release)
    assert {:ok, result} = Task.await(task, 10_000)
    result
  end

  # Starts `fun` in a second process and proves it is blocked on the holder.
  defp contend(fun) do
    task = Task.async(fun)
    assert Task.yield(task, 400) == nil, "the second call must block on the row lock"
    task
  end

  defp no_send, do: assert(Enum.reject(Fake.calls(), &match?({:verify_webhook, _, _}, &1)) == [])

  defp approve_and_plan!(ctx, post) do
    {:ok, %{post: approved}} = approve(ctx, post, ctx.u1)

    {:ok, %{post: planned}} =
      Studio.plan_post(ctx.org.id, post.id, ctx.u1.id, expect(approved), future())

    planned
  end

  # ── the race table ───────────────────────────────────────────────────

  test "discard commits before submit: submit refuses the discarded draft", ctx do
    post = post!(ctx, ctx.a, "draft")
    first = hold(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u1.id, expect(post)) end)
    assert {:ok, discarded} = elem(first, 1)
    second = contend(fn -> Studio.resubmit(ctx.org.id, post.id, ctx.u2.id, expect(post)) end)
    release(first)
    assert {:error, :post_discarded} = Task.await(second, 10_000)
    assert row(post).state_rev == discarded.state_rev
    assert Enum.count(actions(post.id), &(&1 == "discarded")) == 1
    refute "submitted" in actions(post.id)
    no_send()
  end

  test "submit commits before discard: discard is stale", ctx do
    post = post!(ctx, ctx.a, "draft")
    first = hold(fn -> Studio.resubmit(ctx.org.id, post.id, ctx.u1.id, expect(post)) end)
    assert {:ok, submitted} = elem(first, 1)
    second = contend(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u2.id, expect(post)) end)
    release(first)
    assert {:error, {:stale, %{state_rev: rev}}} = Task.await(second, 10_000)
    assert rev == submitted.state_rev
    assert row(post).status == "needs_approval"
    refute "discarded" in actions(post.id)
    no_send()
  end

  test "discard commits before edit: edit refuses the discarded draft", ctx do
    post = post!(ctx, ctx.a, "draft")
    first = hold(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u1.id, expect(post)) end)
    assert {:ok, discarded} = elem(first, 1)

    second =
      contend(fn ->
        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u2.id},
          %{body: "late edit"},
          expect(post)
        )
      end)

    release(first)
    assert {:error, :post_discarded} = Task.await(second, 10_000)
    assert row(post).body == post.body
    assert row(post).state_rev == discarded.state_rev
    no_send()
  end

  test "edit commits before discard: discard is stale", ctx do
    post = post!(ctx, ctx.a, "draft")

    first =
      hold(fn ->
        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u1.id},
          %{body: "first edit"},
          expect(post)
        )
      end)

    assert {:ok, %{post: edited}} = elem(first, 1)
    second = contend(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u2.id, expect(post)) end)
    release(first)
    assert {:error, {:stale, %{state_rev: rev}}} = Task.await(second, 10_000)
    assert rev == edited.state_rev
    assert row(post).body == "first edit"
    refute "discarded" in actions(post.id)
    no_send()
  end

  test "discard commits before restore: restore with the old observation is stale", ctx do
    post = post!(ctx, ctx.a, "draft")
    first = hold(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u1.id, expect(post)) end)
    assert {:ok, discarded} = elem(first, 1)
    second = contend(fn -> Studio.restore_draft(ctx.org.id, post.id, ctx.u2.id, expect(post)) end)
    release(first)
    assert {:error, {:stale, %{state_rev: rev}}} = Task.await(second, 10_000)
    assert rev == discarded.state_rev
    assert row(post).discarded_at != nil
    refute "restored" in actions(post.id)
    no_send()
  end

  test "restore commits before discard: discard with the old observation is stale", ctx do
    post = post!(ctx, ctx.a, "draft")
    {:ok, discarded} = Studio.discard_draft(ctx.org.id, post.id, ctx.u1.id, expect(post))

    first =
      hold(fn -> Studio.restore_draft(ctx.org.id, post.id, ctx.u1.id, expect(discarded)) end)

    assert {:ok, restored} = elem(first, 1)

    second =
      contend(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u2.id, expect(discarded)) end)

    release(first)
    assert {:error, {:stale, %{state_rev: rev}}} = Task.await(second, 10_000)
    assert rev == restored.state_rev
    assert is_nil(row(post).discarded_at)
    assert Enum.count(actions(post.id), &(&1 == "discarded")) == 1
    no_send()
  end

  test "concurrent discards serialize and the second is stale", ctx do
    post = post!(ctx, ctx.a, "draft")
    first = hold(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u1.id, expect(post)) end)
    assert {:ok, discarded} = elem(first, 1)
    second = contend(fn -> Studio.discard_draft(ctx.org.id, post.id, ctx.u2.id, expect(post)) end)
    release(first)
    assert {:error, {:stale, %{state_rev: rev}}} = Task.await(second, 10_000)
    assert rev == discarded.state_rev
    assert row(post).state_rev == discarded.state_rev
    assert Enum.count(actions(post.id), &(&1 == "discarded")) == 1
    no_send()
  end

  test "two approvers at once: the first commits, the second is stale, one receipt", ctx do
    post = post!(ctx, ctx.a)
    first = hold(fn -> approve(ctx, post, ctx.u1) end)
    assert {:ok, %{post: %{state_rev: 1}}} = elem(first, 1)
    second = contend(fn -> approve(ctx, post, ctx.u2) end)

    release(first)
    assert {:error, {:stale, %{state_rev: 1, version: 1}}} = Task.await(second, 10_000)

    assert row(post).approved_by_user_id == ctx.u1.id
    assert states(post.id) == [{1, "current"}]
    assert Enum.count(actions(post.id), &(&1 == "approved")) == 1
    no_send()
  end

  test "approve racing edit, edit first: the approve is stale (version also moved)", ctx do
    post = post!(ctx, ctx.a)

    edit =
      hold(fn ->
        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u1.id},
          %{body: "edited"},
          expect(post)
        )
      end)

    approve_task = contend(fn -> approve(ctx, post, ctx.u2) end)
    release(edit)

    assert {:error, {:stale, %{state_rev: 1, version: 2}}} = Task.await(approve_task, 10_000)
    assert states(post.id) == []
    assert row(post).status == "needs_approval"
    no_send()
  end

  test "approve racing edit, approve first: the edit is stale; a deliberate edit then revokes",
       ctx do
    post = post!(ctx, ctx.a)
    first = hold(fn -> approve(ctx, post, ctx.u1) end)

    edit =
      contend(fn ->
        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u2.id},
          %{body: "late edit"},
          expect(post)
        )
      end)

    release(first)

    assert {:error, {:stale, %{state_rev: 1, version: 1}}} = Task.await(edit, 10_000)
    assert row(post).body == post.body
    assert states(post.id) == [{1, "current"}]

    # the editor reloads, sees the approval, and edits on purpose
    approved = row(post)

    assert {:ok, %{revoked_approval: %{state: "superseded"}}} =
             Studio.save_version(
               ctx.org.id,
               post.id,
               {:human, ctx.u2.id},
               %{body: "late edit"},
               expect(approved)
             )

    assert states(post.id) == [{1, "superseded"}]
    no_send()
  end

  test "plan racing cancel, cancel commits first: the plan call is stale, no plan is recreated",
       ctx do
    planned = ctx |> post!(ctx.a) |> then(&approve_and_plan!(ctx, &1))

    cancel =
      hold(fn -> Studio.cancel_plan(ctx.org.id, planned.id, ctx.u1.id, expect(planned)) end)

    replan =
      contend(fn ->
        Studio.plan_post(ctx.org.id, planned.id, ctx.u2.id, expect(planned), future())
      end)

    release(cancel)

    assert {:error, {:stale, _}} = Task.await(replan, 10_000)
    row = row(planned)
    assert {row.status, row.scheduled_at} == {"approved", nil}
    assert List.last(actions(planned.id)) == "plan_cancelled"
    assert Enum.count(actions(planned.id), &(&1 == "planned")) == 1
    no_send()
  end

  test "replan racing cancel, replan commits first: the cancel is stale, the newer plan stays",
       ctx do
    planned = ctx |> post!(ctx.a) |> then(&approve_and_plan!(ctx, &1))
    later = DateTime.add(DateTime.utc_now(), 7_200, :second)

    replan =
      hold(fn -> Studio.plan_post(ctx.org.id, planned.id, ctx.u2.id, expect(planned), later) end)

    cancel =
      contend(fn -> Studio.cancel_plan(ctx.org.id, planned.id, ctx.u1.id, expect(planned)) end)

    release(replan)

    assert {:error, {:stale, _}} = Task.await(cancel, 10_000)
    row = row(planned)
    assert row.status == "planned"
    assert DateTime.compare(row.scheduled_at, later) == :eq
    refute "plan_cancelled" in actions(planned.id)
    no_send()
  end

  test "stale revoke vs a new approval: the re-approval stays current, the revoke is stale",
       ctx do
    # U1 owns the account and approves; ownership moves to U2, who re-approves while U1's
    # old view (receipt R1, state_rev 1) tries to revoke.
    post = post!(ctx, ctx.b)
    {:ok, acct} = Social.set_account_owner(ctx.org.id, ctx.b, ctx.u1.id)
    {:ok, %{post: approved, approval: r1}} = approve(ctx, post, ctx.u1)
    {:ok, _} = Social.set_account_owner(ctx.org.id, acct, ctx.u2.id)

    reapprove = hold(fn -> approve(ctx, post, ctx.u2, expect(approved)) end)

    revoke =
      contend(fn ->
        Studio.revoke_approval(
          ctx.org.id,
          post.id,
          ctx.u2.id,
          expect(approved, %{approval_id: r1.id}),
          "old view"
        )
      end)

    release(reapprove)

    assert {:error, {:stale, %{state_rev: 2}}} = Task.await(revoke, 10_000)
    assert states(post.id) == [{1, "superseded"}, {1, "current"}]
    assert row(post).status == "approved"
    refute "approval_revoked" in actions(post.id)
    no_send()
  end

  test "double submit: the second approve carries the old state_rev and writes nothing", ctx do
    post = post!(ctx, ctx.a)
    first = hold(fn -> approve(ctx, post, ctx.u1) end)
    second = contend(fn -> approve(ctx, post, ctx.u1) end)
    release(first)
    assert {:error, {:stale, _}} = Task.await(second, 10_000)
    assert states(post.id) == [{1, "current"}]
    assert Enum.count(actions(post.id), &(&1 == "approved")) == 1
  end

  test "free race, repeated: two approvers, exactly one wins every round", ctx do
    for _ <- 1..15 do
      post = post!(ctx, ctx.a)
      parent = self()

      tasks =
        for user <- [ctx.u1, ctx.u2] do
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> approve(ctx, post, user))
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _}, 2_000)
      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:stale, _}}, &1)) == 1
      assert [{1, "current"}] = states(post.id)
      assert Enum.count(actions(post.id), &(&1 == "approved")) == 1
    end
  end

  # ── creative acceptance ──────────────────────────────────────────────

  defp studio_clip!(ctx) do
    {:ok, file, _} =
      Platform.Files.add_bytes(
        ctx.project,
        "clip bytes #{System.unique_integer([:positive])}",
        "clip.mp4",
        "video/mp4",
        ingest: false
      )

    {:ok, clip} =
      AgentDrafts.submit_clip(
        {:tenant, ctx.org.id},
        ctx.profile.id,
        %{
          "file_id" => file.id,
          "title" => "T",
          "caption" => "C",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        ctx.agent.id
      )

    Repo.update_all(from(c in Clip, where: c.id == ^clip.id), set: [flow: "studio"])

    render_id =
      Repo.one!(from(r in Platform.Social.ClipRender, where: r.clip_id == ^clip.id, select: r.id))

    {clip, render_id}
  end

  defp accept(ctx, clip, rid, accounts),
    do:
      Studio.accept_render(ctx.org.id, clip.id, ctx.u1.id, %{
        render_id: rid,
        account_ids: Enum.map(accounts, & &1.id)
      })

  defp posts_of(clip_id), do: Repo.all(from(p in Post, where: p.clip_id == ^clip_id))

  test "concurrent accepts of one render and destination leave one post, one event pair", ctx do
    {clip, rid} = studio_clip!(ctx)
    first = hold(fn -> accept(ctx, clip, rid, [ctx.a]) end)
    assert {:ok, %{posts: [created]}} = elem(first, 1)
    second = contend(fn -> accept(ctx, clip, rid, [ctx.a]) end)
    release(first)

    assert {:ok, %{posts: [same]}} = Task.await(second, 10_000)
    assert same.id == created.id
    assert [%{id: id}] = posts_of(clip.id)
    assert id == created.id
    assert actions(created.id) == ~w(created submitted)
    no_send()
  end

  test "concurrent accepts for overlapping accounts: one post per account", ctx do
    {clip, rid} = studio_clip!(ctx)
    first = hold(fn -> accept(ctx, clip, rid, [ctx.a, ctx.b]) end)
    second = contend(fn -> accept(ctx, clip, rid, [ctx.b, ctx.c]) end)
    release(first)

    assert {:ok, %{posts: [_, _]}} = Task.await(second, 10_000)
    posts = posts_of(clip.id)

    assert Enum.sort(Enum.map(posts, & &1.account_id)) ==
             Enum.sort([ctx.a.id, ctx.b.id, ctx.c.id])

    for p <- posts, do: assert(actions(p.id) == ~w(created submitted))
  end

  test "replay of accept for A while A's post is being retargeted: waits, then returns the retargeted post, nothing created",
       ctx do
    {clip, rid} = studio_clip!(ctx)
    {:ok, %{posts: [post]}} = accept(ctx, clip, rid, [ctx.a])

    retarget =
      hold(fn ->
        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u1.id},
          %{account_id: ctx.c.id},
          expect(post)
        )
      end)

    assert {:ok, %{post: %{account_id: c_id}}} = elem(retarget, 1)
    assert c_id == ctx.c.id

    # The replay locks the post it returns (the actor is authorised for the
    # destination of the post actually returned), so it WAITS for the retarget
    # that holds the post, then returns the post on its new account C.
    replay = contend(fn -> accept(ctx, clip, rid, [ctx.a]) end)
    release(retarget)

    assert {:ok, %{posts: [replayed]}} = Task.await(replay, 10_000)
    assert {replayed.id, replayed.account_id} == {post.id, ctx.c.id}

    assert {:ok, %{posts: [again]}} = accept(ctx, clip, rid, [ctx.a])
    assert {again.id, again.account_id} == {post.id, ctx.c.id}
    assert [_one] = posts_of(clip.id)
  end

  test "a retarget onto C racing an accept for C: exactly one holds C, the other is :duplicate_destination",
       ctx do
    {clip, rid} = studio_clip!(ctx)
    {:ok, %{posts: [post]}} = accept(ctx, clip, rid, [ctx.a])

    retarget =
      hold(fn ->
        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u1.id},
          %{account_id: ctx.c.id},
          expect(post)
        )
      end)

    assert {:ok, _} = elem(retarget, 1)
    acceptor = contend(fn -> accept(ctx, clip, rid, [ctx.c]) end)
    release(retarget)

    assert {:error, {:destinations, [%{account_id: cid, reason: :duplicate_destination}]}} =
             Task.await(acceptor, 10_000)

    assert cid == ctx.c.id
    assert [only] = posts_of(clip.id)
    assert {only.id, only.account_id} == {post.id, ctx.c.id}
  end

  test "revoke first: the post is needs_approval, the old-observation re-approval is stale",
       ctx do
    post = post!(ctx, ctx.b)
    {:ok, acct} = Social.set_account_owner(ctx.org.id, ctx.b, ctx.u1.id)
    {:ok, %{post: approved, approval: r1}} = approve(ctx, post, ctx.u1)
    {:ok, _} = Social.set_account_owner(ctx.org.id, acct, ctx.u2.id)

    revoke =
      hold(fn ->
        Studio.revoke_approval(
          ctx.org.id,
          post.id,
          ctx.u2.id,
          expect(approved, %{approval_id: r1.id}),
          "gone"
        )
      end)

    assert {:ok, _} = elem(revoke, 1)
    reapprove = contend(fn -> approve(ctx, post, ctx.u2, expect(approved)) end)
    release(revoke)

    assert {:error, {:stale, %{state_rev: 2, version: 1}}} = Task.await(reapprove, 10_000)
    assert row(post).status == "needs_approval"
    assert states(post.id) == [{1, "revoked"}]
    assert Enum.count(actions(post.id), &(&1 == "approved")) == 1
    no_send()
  end

  test "concurrent identical requests: one transition, one stale, rev bumped once", ctx do
    requests = [
      {"needs_approval", fn p, ex -> Studio.approve_version(ctx.org.id, p.id, ctx.u1.id, ex) end},
      {"needs_approval",
       fn p, ex ->
         Studio.save_version(ctx.org.id, p.id, {:human, ctx.u1.id}, %{body: "once"}, ex)
       end},
      {"needs_approval",
       fn p, ex ->
         Studio.save_version(ctx.org.id, p.id, {:human, ctx.u1.id}, %{account_id: ctx.b.id}, ex)
       end},
      {"needs_approval",
       fn p, ex -> Studio.request_changes(ctx.org.id, p.id, ctx.u1.id, ex, "no") end},
      {"approved", fn p, ex -> Studio.plan_post(ctx.org.id, p.id, ctx.u1.id, ex, future()) end},
      {"planned", fn p, ex -> Studio.cancel_plan(ctx.org.id, p.id, ctx.u1.id, ex) end}
    ]

    for {status, call} <- requests do
      post = post!(ctx, ctx.a)

      post =
        case status do
          "needs_approval" -> post
          "approved" -> elem(approve(ctx, post, ctx.u1), 1).post
          "planned" -> approve_and_plan!(ctx, post)
        end

      observed = expect(post)
      first = hold(fn -> call.(post, observed) end)
      assert {:ok, _} = elem(first, 1)
      second = contend(fn -> call.(post, observed) end)
      release(first)

      assert {:error, {:stale, %{state_rev: r}}} = Task.await(second, 10_000)
      assert r == post.state_rev + 1
      assert row(post).state_rev == post.state_rev + 1
    end
  end

  test "two concurrent replays of an acceptance after a retarget return the same post", ctx do
    {clip, rid} = studio_clip!(ctx)
    {:ok, %{posts: [post]}} = accept(ctx, clip, rid, [ctx.a])

    {:ok, %{post: moved}} =
      Studio.save_version(
        ctx.org.id,
        post.id,
        {:human, ctx.u1.id},
        %{account_id: ctx.c.id},
        expect(post)
      )

    first = hold(fn -> accept(ctx, clip, rid, [ctx.a]) end)
    second = contend(fn -> accept(ctx, clip, rid, [ctx.a]) end)
    release(first)

    assert {:ok, %{posts: [again]}} = Task.await(second, 10_000)
    assert {again.id, again.account_id, again.version} == {post.id, ctx.c.id, moved.version}
    assert row(post) == row(moved)
    assert actions(post.id) |> Enum.count(&(&1 == "created")) == 1
    assert [_one] = posts_of(clip.id)
  end

  test "a post retargeted while a writer waits for its lock: the writer starts again and locks the new account in order",
       ctx do
    post = post!(ctx, ctx.a)
    parent = self()

    retarget =
      hold(fn ->
        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u1.id},
          %{account_id: ctx.c.id},
          expect(post)
        )
      end)

    assert {:ok, _} = elem(retarget, 1)

    contender =
      contend(fn ->
        id = "retry-trace-#{System.unique_integer([:positive])}"
        me = self()

        :telemetry.attach(
          id,
          [:platform, :repo, :query],
          fn _e, _m, %{query: q, params: params}, _c ->
            if self() == me and q =~ ~r/FOR SHARE\s*$/ and q =~ ~s(FROM "social_),
              do: send(parent, {:share, q, params})
          end,
          nil
        )

        try do
          Studio.approve_version(ctx.org.id, post.id, ctx.u2.id, expect(post))
        after
          :telemetry.detach(id)
        end
      end)

    release(retarget)
    assert {:error, {:stale, %{state_rev: 1, version: 2}}} = Task.await(contender, 10_000)

    shares =
      Stream.repeatedly(fn ->
        receive do
          {:share, q, _} -> q
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    # two attempts: profile, account(s), then the post is NOT FOR SHARE; the
    # second attempt starts again with a second profile lock
    assert Enum.count(shares, &(&1 =~ ~s(FROM "social_profiles"))) == 2
  end

  # ── the replay restart ───────────────────────────────────────────────

  # The pair: a replay for A learns the post now sits on B,
  # and B sorts BEFORE A. `a` is the higher id, `b` the lower.
  defp ordered_pair(ctx) do
    [b, a | _] = Enum.sort_by([ctx.a, ctx.b, ctx.c], & &1.id)
    {a, b}
  end

  defp retarget!(ctx, post, account) do
    {:ok, %{post: moved}} =
      Studio.save_version(
        ctx.org.id,
        post.id,
        {:human, ctx.u1.id},
        %{account_id: account.id},
        expect(post)
      )

    moved
  end

  test "a replay for A, post now on B < A, against a writer that locks B then A: no deadlock",
       ctx do
    {a, b} = ordered_pair(ctx)
    assert b.id < a.id
    {clip, rid} = studio_clip!(ctx)
    {:ok, %{posts: [post]}} = accept(ctx, clip, rid, [a])
    moved = retarget!(ctx, post, b)
    parent = self()

    # The other party takes B's row lock, then (once told) A's: B then A. Its
    # locks conflict with a FOR SHARE, so a replay that still held A while it
    # waited for B would deadlock with it.
    other =
      Task.async(fn ->
        Repo.transaction(fn ->
          Social.lock_account(ctx.profile, b.id, :update)
          send(parent, :holds_b)

          receive do
            :take_a -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end

          Social.lock_account(ctx.profile, a.id, :update)
          :done
        end)
      end)

    assert_receive :holds_b, 5_000
    replay = Task.async(fn -> accept(ctx, clip, rid, [a]) end)
    assert Task.yield(replay, 500) == nil, "the second pass must wait for B"
    send(other.pid, :take_a)

    assert {:ok, :done} = Task.await(other, 15_000)
    assert {:ok, %{posts: [again]}} = Task.await(replay, 15_000)
    assert {again.id, again.account_id, again.version} == {post.id, b.id, moved.version}
    assert [_one] = posts_of(clip.id)
  end

  test "the destination changed again between the two passes: stale, nothing changed", ctx do
    {clip, rid} = studio_clip!(ctx)
    {:ok, %{posts: [post]}} = accept(ctx, clip, rid, [ctx.a])
    moved = retarget!(ctx, post, ctx.b)
    parent = self()

    replay =
      Task.async(fn ->
        me = self()
        id = "c6-restart-#{System.unique_integer([:positive])}"

        # When the first pass has committed (its locks are gone), move the post
        # on to C from another connection, before the second pass begins.
        :telemetry.attach(
          id,
          [:platform, :repo, :query],
          fn _e, _m, %{query: q}, _c ->
            if self() == me and q == "commit" and not :persistent_term.get({id, :moved}, false) do
              :persistent_term.put({id, :moved}, true)

              Task.async(fn -> send(parent, {:moved, retarget!(ctx, moved, ctx.c)}) end)
              |> Task.await(10_000)
            end
          end,
          nil
        )

        try do
          result = accept(ctx, clip, rid, [ctx.a])
          {result, :persistent_term.get({id, :moved}, false)}
        after
          :telemetry.detach(id)
          :persistent_term.erase({id, :moved})
        end
      end)

    assert {result, hook_ran?} = Task.await(replay, 20_000)
    assert hook_ran?, "the post must have moved between the passes"
    assert_receive {:moved, moved_again}, 1_000
    assert moved_again.account_id == ctx.c.id

    assert {:error, {:stale, %{state_rev: rev, version: ver}}} = result
    assert {rev, ver} == {moved_again.state_rev, moved_again.version}
    assert row(post).account_id == ctx.c.id
    assert [_one] = posts_of(clip.id)
    assert Enum.count(actions(post.id), &(&1 == "created")) == 1
  end

  test "replay: post moved B then back to A between passes returns the locked authorised A row",
       ctx do
    # Guard: the second pass decides on the rows it locked. A is in its locked
    # set (it is requested), so a post that is back on A is a plain replay, not
    # a "changed again" stale.
    {clip, rid} = studio_clip!(ctx)
    {:ok, %{posts: [post]}} = accept(ctx, clip, rid, [ctx.a])
    moved = retarget!(ctx, post, ctx.b)
    parent = self()

    replay =
      Task.async(fn ->
        me = self()
        id = "c6-back-to-a-#{System.unique_integer([:positive])}"

        # The first pass saw the post on B and ended its transaction. When it
        # commits, move the post back to A from another connection.
        :telemetry.attach(
          id,
          [:platform, :repo, :query],
          fn _e, _m, %{query: q}, _c ->
            if self() == me and q == "commit" and not :persistent_term.get({id, :moved}, false) do
              :persistent_term.put({id, :moved}, true)

              Task.async(fn ->
                back = retarget!(ctx, moved, ctx.a)
                send(parent, {:moved, back, actions(post.id)})
              end)
              |> Task.await(10_000)
            end
          end,
          nil
        )

        try do
          result = accept(ctx, clip, rid, [ctx.a])
          {result, :persistent_term.get({id, :moved}, false)}
        after
          :telemetry.detach(id)
          :persistent_term.erase({id, :moved})
        end
      end)

    assert {result, hook_ran?} = Task.await(replay, 20_000)
    assert hook_ran?, "the post must have moved back to A between the passes"
    assert_receive {:moved, back, events_after_retarget}, 1_000
    assert back.account_id == ctx.a.id

    assert {:ok, %{posts: [again]}} = result
    assert {again.id, again.account_id, again.version} == {post.id, ctx.a.id, back.version}
    assert again.state_rev == back.state_rev

    # a replay writes nothing: the row and the events are what the retarget
    # left, and there is no new post
    assert row(post) == row(back)
    assert [_one] = posts_of(clip.id)
    assert Enum.count(actions(post.id), &(&1 == "created")) == 1
    assert actions(post.id) == events_after_retarget
  end

  test "writer: the third attempt that still finds an unlocked destination is stale, with no writes",
       ctx do
    # Guard: `write_attempt` makes three attempts (two restarts). The third one
    # that finds the post on an account it has not locked answers the stale
    # shape instead of taking an account lock after the post lock.
    {:ok, d} =
      Social.create_account(ctx.org.id, ctx.profile, %{platform: "instagram", handle: "@d"})

    post = post!(ctx, ctx.a)
    parent = self()
    marker = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        marker,
        [:platform, :repo, :query],
        fn _e, _m, %{query: q}, _c ->
          if Process.get(marker) == true and q =~ ~s(FROM "social_accounts") and q =~ "FOR SHARE" do
            n = Process.get({marker, :n}, 0) + 1
            Process.put({marker, :n}, n)
            send(parent, {:attempt, n, self()})

            # Only the first three attempts wait for their retarget; a fourth
            # one (the mutation) runs straight on.
            if n <= 3 do
              receive do
                :resume -> :ok
              after
                10_000 -> raise "C7 handshake timed out"
              end
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(marker) end)

    writer =
      Task.async(fn ->
        Process.put(marker, true)

        Studio.save_version(
          ctx.org.id,
          post.id,
          {:human, ctx.u1.id},
          %{body: "writer body #{System.unique_integer([:positive])}"},
          expect(post)
        )
      end)

    last =
      Enum.reduce([ctx.b, ctx.c, d], post, fn destination, current ->
        assert_receive {:attempt, _n, writer_pid}, 5_000
        moved = retarget!(ctx, current, destination)
        send(writer_pid, :resume)
        moved
      end)

    events_after_retargets = actions(post.id)
    assert {:error, {:stale, %{state_rev: rev, version: ver}}} = Task.await(writer, 5_000)
    assert {rev, ver} == {last.state_rev, last.version}
    refute_receive {:attempt, 4, _}, 200

    # no writes by the writer: the row and events are what the three retargets left
    assert row(post) == row(last)
    assert row(post).account_id == d.id
    assert actions(post.id) == events_after_retargets
  end
end
