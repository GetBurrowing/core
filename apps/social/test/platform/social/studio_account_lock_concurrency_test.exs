defmodule Platform.Social.StudioAccountLockConcurrencyTest do
  @moduledoc """
  Two real database connections: an account archive or an owner transfer that
  is IN FLIGHT (uncommitted) while `Studio.create_post/4` passes its pre-lock
  checks. The create then waits on the account row lock (`Social.lock_account/3`,
  `FOR SHARE`), and on release decides again on the committed row. The reverse
  holds too: a create in flight makes the writer wait. The world is committed
  and removed by hand afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Post, Profile, Studio}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    # `orgs_single_root`: the tenant needs a parent. Reuse the root if one is
    # committed, else commit one of ours and remove it at the end.
    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{
             name: "Lock root #{n}",
             slug: "lock-root-#{Platform.TenancyFixtures.run_token()}-#{n}"
           }), true}

        root ->
          {root, false}
      end

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Lock race #{n}",
        slug: "lock-race-#{Platform.TenancyFixtures.run_token()}-#{n}",
        parent_org_id: root.id
      })

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "lock-race-#{Platform.TenancyFixtures.run_token()}-#{n}@example.com",
        oidc_sub: "lock-race-#{Platform.TenancyFixtures.run_token()}-#{n}",
        name: "Lock Race #{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org.id,
      role: "member"
    })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Lock race #{n}", org_id: org.id})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      profile_ids = Repo.all(from(p in Profile, where: p.org_id == ^org.id, select: p.id))

      Repo.delete_all(
        from(po in Post,
          join: a in Account,
          on: a.id == po.account_id,
          where: a.profile_id in ^profile_ids
        )
        |> select([po], po)
      )

      Repo.delete_all(from(p in Profile, where: p.id in ^profile_ids))
      Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
      Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^user.id))
      Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id))
      if own_root?, do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
      Sandbox.mode(Repo, :manual)
    end)

    %{org: org, user: user, project: project}
  end

  defp world!(ctx) do
    n = System.unique_integer([:positive])

    other =
      Repo.insert!(%Platform.Accounts.User{
        email: "acct-race-#{Platform.TenancyFixtures.run_token()}-#{n}@example.com",
        oidc_sub: "acct-race-#{Platform.TenancyFixtures.run_token()}-#{n}",
        name: "Acct Race #{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: other.id,
      org_id: ctx.org.id,
      role: "member"
    })

    on_exit(fn ->
      Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^other.id))
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^other.id))
    end)

    {:ok, profile} =
      Social.create_profile(ctx.org.id, %{
        name: "Acct race #{n}",
        project_id: ctx.project.id,
        home_url: "https://www.youtube.com/@acctrace",
        approver_user_ids: [ctx.user.id]
      })

    {:ok, account} =
      Social.create_account(ctx.org.id, profile, %{platform: "x", handle: "@acct#{n}"})

    {:ok, account} = Social.set_account_owner(ctx.org.id, account, ctx.user.id)
    {:ok, profile} = Studio.set_enabled(ctx.org.id, profile.id, ctx.user.id, true)
    %{profile: profile, account: account, other: other}
  end

  defp create(ctx, w),
    do:
      Studio.create_post(ctx.org.id, w.account.id, ctx.user.id, %{body: "race", status: "draft"})

  defp post_count(account_id),
    do: Repo.aggregate(from(po in Post, where: po.account_id == ^account_id), :count)

  # A process that runs `write` (an account writer) in a transaction, tells the
  # test, and holds the transaction open, uncommitted, until `:release`.
  defp writer(write) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        {:ok, _} = write.()
        send(parent, :written)

        receive do
          :release -> :ok
        after
          10_000 -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  test "a create that passed its early checks waits for an archive in flight, then refuses",
       ctx do
    w = world!(ctx)
    archiver = writer(fn -> Social.archive_account(ctx.org.id, w.account) end)
    assert_receive :written, 5_000

    creator = Task.async(fn -> create(ctx, w) end)
    assert Task.yield(creator, 400) == nil, "create must block on the account row lock"

    send(archiver.pid, :release)
    assert {:ok, _} = Task.await(archiver, 10_000)
    assert {:error, :account_archived} = Task.await(creator, 10_000)
    assert post_count(w.account.id) == 0
  end

  test "a create that passed its early checks waits for an owner transfer in flight, then refuses",
       ctx do
    w = world!(ctx)
    mover = writer(fn -> Social.set_account_owner(ctx.org.id, w.account, w.other.id) end)
    assert_receive :written, 5_000

    creator = Task.async(fn -> create(ctx, w) end)
    assert Task.yield(creator, 400) == nil, "create must block on the account row lock"

    send(mover.pid, :release)
    assert {:ok, _} = Task.await(mover, 10_000)
    assert {:error, :not_the_owner} = Task.await(creator, 10_000)
    assert post_count(w.account.id) == 0
  end

  test "an archive waits for a create in flight, which commits its post", ctx do
    w = world!(ctx)
    parent = self()

    creator =
      Task.async(fn ->
        Repo.transaction(fn ->
          profile = Social.lock_profile(ctx.org.id, w.profile, :share) || Repo.rollback(:gone)
          acct = Social.lock_account(profile, w.account.id, :share) || Repo.rollback(:gone)
          send(parent, :locked)

          receive do
            :release ->
              %Post{account_id: acct.id, flow: "studio"}
              |> Post.studio_create_changeset(%{"body" => "in flight", "status" => "draft"})
              |> Repo.insert!()
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :locked, 5_000
    archiver = Task.async(fn -> Social.archive_account(ctx.org.id, w.account) end)
    assert Task.yield(archiver, 400) == nil, "archive must wait for the create in flight"

    send(creator.pid, :release)
    assert {:ok, %Post{}} = Task.await(creator, 10_000)
    assert {:ok, %{archived_at: %DateTime{}}} = Task.await(archiver, 10_000)
    assert post_count(w.account.id) == 1
  end
end
