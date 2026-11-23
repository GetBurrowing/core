defmodule Platform.Social.QualityReviewConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Platform.SocialFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, ApprovalCard, Post, PostEvents, Profile, Publisher.Fake}

  setup do
    Sandbox.mode(Repo, :auto)
    Fake.reset()
    root = Repo.one!(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1))

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Quality lock control",
        slug: "quality-lock-#{Ecto.UUID.generate()}",
        parent_org_id: root.id
      })

    approver = user!() |> member!(org.id)
    reviewer = user!() |> member!(org.id)
    space = channel!(org.id)

    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: "Quality lock control",
        space_id: space.id,
        approver_user_ids: [approver.id],
        quality_reviewer_user_ids: [reviewer.id]
      })

    {:ok, account} =
      Social.create_account(org.id, profile, %{platform: "linkedin", status: "connected"})

    {:ok, post} =
      Social.create_post(org.id, account, %{
        body: "A complete quality request",
        status: "needs_approval",
        scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    assert post.status == "quality_review"

    on_exit(fn ->
      steps = [
        fn -> Repo.delete_all(from(i in Platform.Inbox.Item, where: i.source_id == ^post.id)) end,
        fn -> Repo.delete_all(from(p in Post, where: p.id == ^post.id)) end,
        fn -> Repo.delete_all(from(a in Account, where: a.id == ^account.id)) end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id == ^profile.id)) end,
        fn -> Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^space.id)) end,
        fn ->
          Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
        end,
        fn ->
          Repo.delete_all(
            from(u in Platform.Accounts.User, where: u.id in ^[approver.id, reviewer.id])
          )
        end,
        fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id)) end
      ]

      errors =
        try do
          Enum.flat_map(steps, fn step ->
            try do
              step.()
              []
            catch
              kind, reason -> [{kind, reason, __STACKTRACE__}]
            end
          end)
        after
          Sandbox.mode(Repo, :manual)
        end

      case errors do
        [{kind, reason, stack} | _] -> :erlang.raise(kind, reason, stack)
        [] -> :ok
      end
    end)

    %{org: org, reviewer: reviewer, profile: profile, post: post}
  end

  test "Pass waits for concurrent reviewer removal and rechecks the committed profile", c do
    parent = self()

    before =
      {Repo.get!(Post, c.post.id), PostEvents.list_for_post(c.post.id),
       Repo.aggregate(from(i in Platform.Inbox.Item, where: i.source_id == ^c.post.id), :count)}

    remover =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Social.update_profile(c.org.id, c.profile, %{quality_reviewer_user_ids: []})
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:removal_held, pid})

          receive do
            :release -> :ok
          after
            5_000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:removal_held, holder_pid}, 5_000

    passer =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:pass_started, pid})
          Social.pass_quality_review(c.org.id, c.post.id, c.reviewer.id)
        end)
      end)

    try do
      assert_receive {:pass_started, passer_pid}, 5_000
      assert passer_pid != holder_pid

      assert blocked_on_profile?(passer_pid, holder_pid),
             "Pass never waited on this removal's profile lock"

      # The observed wait must precede the pass write, not a later fan-out lock.
      assert Repo.get!(Post, c.post.id) == elem(before, 0)
      send(remover.pid, :release)
      assert {:ok, :ok} = Task.await(remover, 5_000)
      assert {:error, :not_a_quality_reviewer} = Task.await(passer, 5_000)
      assert Repo.get!(Profile, c.profile.id).quality_reviewer_user_ids == []

      assert {Repo.get!(Post, c.post.id), PostEvents.list_for_post(c.post.id),
              Repo.aggregate(
                from(i in Platform.Inbox.Item, where: i.source_id == ^c.post.id),
                :count
              )} == before

      assert Repo.aggregate(from(a in ApprovalCard, where: a.post_id == ^c.post.id), :count) == 0
      assert Fake.calls() == []
    after
      send(remover.pid, :release)
      Task.shutdown(remover, :brutal_kill)
      Task.shutdown(passer, :brutal_kill)
    end
  end

  defp blocked_on_profile?(pid, holder, tries \\ 200)
  defp blocked_on_profile?(_pid, _holder, 0), do: false

  defp blocked_on_profile?(pid, holder, tries) do
    [[blocked]] =
      Repo.query!(
        "SELECT $2 = ANY(pg_blocking_pids($1)) AND EXISTS (SELECT 1 FROM pg_locks WHERE pid=$1 AND locktype='tuple' AND relation='social_profiles'::regclass)",
        [pid, holder]
      ).rows

    if blocked do
      true
    else
      Process.sleep(10)
      blocked_on_profile?(pid, holder, tries - 1)
    end
  end
end
