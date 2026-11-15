defmodule Platform.Social.StudioProfileLockConcurrencyTest do
  @moduledoc """
  Two real database connections (the sandbox is switched to `:auto`, as in
  `Platform.Calendar.BookingConcurrencyTest`): `Social.delete_profile/2` and
  `Studio.create_post/4` serialise on the profile row lock, so a Studio post is
  never created and then silently cascaded away. The world is committed and
  removed by hand afterwards.
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

    {:ok, profile} =
      Social.create_profile(ctx.org.id, %{
        name: "Race show #{n}",
        project_id: ctx.project.id,
        home_url: "https://www.youtube.com/@raceshow",
        approver_user_ids: [ctx.user.id]
      })

    {:ok, account} =
      Social.create_account(ctx.org.id, profile, %{platform: "x", handle: "@race#{n}"})

    {:ok, profile} = Studio.set_enabled(ctx.org.id, profile.id, ctx.user.id, true)
    %{profile: profile, account: account}
  end

  defp create(ctx, w),
    do:
      Studio.create_post(ctx.org.id, w.account.id, ctx.user.id, %{body: "race", status: "draft"})

  defp studio_count(profile_id) do
    Repo.aggregate(
      from(po in Post,
        join: a in Account,
        on: a.id == po.account_id,
        where: a.profile_id == ^profile_id and po.flow == "studio"
      ),
      :count
    )
  end

  # A process that locks the profile row in `mode`, tells the test, and holds
  # its transaction open until told to `:release`; `work` then runs inside it.
  defp holder(ctx, w, mode, work \\ fn -> :ok end) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        Social.lock_profile(ctx.org.id, w.profile.id, mode) || Repo.rollback(:gone)
        send(parent, :locked)

        receive do
          :release -> work.()
        after
          10_000 -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  test "a create waits for a deletion in flight, then reads the profile as not_found", ctx do
    w = world!(ctx)
    deleter = holder(ctx, w, :update, fn -> Repo.delete!(Repo.get!(Profile, w.profile.id)) end)
    assert_receive :locked, 5_000

    creator = Task.async(fn -> create(ctx, w) end)
    assert Task.yield(creator, 400) == nil, "create must block on the profile row lock"

    send(deleter.pid, :release)
    assert {:ok, _} = Task.await(deleter, 10_000)
    assert {:error, :not_found} = Task.await(creator, 10_000)
    assert Repo.get(Profile, w.profile.id) == nil
    assert studio_count(w.profile.id) == 0
  end

  test "a deletion waits for a create in flight, then is refused", ctx do
    w = world!(ctx)

    # The in-flight create: holds the `:share` lock the real create_post takes,
    # then writes its Studio post and commits.
    creator =
      holder(ctx, w, :share, fn ->
        %Post{account_id: w.account.id, flow: "studio"}
        |> Post.studio_create_changeset(%{"body" => "in flight", "status" => "draft"})
        |> Repo.insert!()
      end)

    assert_receive :locked, 5_000

    deleter = Task.async(fn -> Social.delete_profile(ctx.org.id, w.profile) end)
    assert Task.yield(deleter, 400) == nil, "delete must block on the profile row lock"

    send(creator.pid, :release)
    assert {:ok, %Post{} = post} = Task.await(creator, 10_000)
    assert {:error, :has_studio_posts} = Task.await(deleter, 10_000)
    assert Repo.get(Profile, w.profile.id)
    assert Repo.get(Post, post.id)
  end

  test "two creates hold :share together; a delete waits for both", ctx do
    w = world!(ctx)
    a = holder(ctx, w, :share)
    assert_receive :locked, 5_000
    b = holder(ctx, w, :share)
    assert_receive :locked, 2_000, "shared locks must not queue behind each other"

    deleter = Task.async(fn -> Social.delete_profile(ctx.org.id, w.profile) end)
    assert Task.yield(deleter, 400) == nil
    send(a.pid, :release)
    assert Task.yield(deleter, 300) == nil, "still one share lock held"
    send(b.pid, :release)
    assert {:ok, _} = Task.await(deleter, 10_000)
  end

  test "free race, repeated: never a created post plus a successful delete", ctx do
    outcomes =
      for _ <- 1..20 do
        w = world!(ctx)
        parent = self()

        tasks =
          for job <- [:create, :delete] do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go ->
                  case job do
                    :create -> {:create, create(ctx, w)}
                    :delete -> {:delete, Social.delete_profile(ctx.org.id, w.profile)}
                  end
              end
            end)
          end

        for _ <- tasks, do: assert_receive({:ready, _}, 2_000)
        Enum.each(tasks, &send(&1.pid, :go))
        results = tasks |> Enum.map(&Task.await(&1, 15_000)) |> Map.new()

        case results do
          %{create: {:ok, post}, delete: {:error, :has_studio_posts}} ->
            assert Repo.get(Post, post.id)
            assert Repo.get(Profile, w.profile.id)
            :create_won

          %{create: {:error, :not_found}, delete: {:ok, _}} ->
            assert Repo.get(Profile, w.profile.id) == nil
            assert studio_count(w.profile.id) == 0
            :delete_won
        end
      end

    # Every round matched one of the two consistent shapes (a `case` clause
    # error would have failed the round); both may or may not occur.
    assert length(outcomes) == 20
  end
end
