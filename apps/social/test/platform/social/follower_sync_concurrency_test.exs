defmodule Platform.Social.FollowerSyncConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social.{Account, FollowerSnapshot, FollowerSync, FollowerSyncState, Profile}
  alias Platform.Social.Analytics.SyncState

  setup do
    Sandbox.mode(Repo, :auto)
    ids = Map.new([:org, :profile, :account], &{&1, Ecto.UUID.generate()})

    on_exit(fn ->
      steps = [
        fn ->
          Repo.delete_all(from(s in FollowerSnapshot, where: s.account_id == ^ids.account))
        end,
        fn ->
          Repo.delete_all(from(s in FollowerSyncState, where: s.account_id == ^ids.account))
        end,
        fn -> Repo.delete_all(from(s in SyncState, where: s.org_id == ^ids.org)) end,
        fn -> Repo.delete_all(from(a in Account, where: a.id == ^ids.account)) end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id == ^ids.profile)) end,
        fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^ids.org)) end
      ]

      errors =
        try do
          Enum.flat_map(steps, fn step ->
            try do
              step.()
              []
            catch
              kind, reason -> [{kind, reason}]
            end
          end)
        after
          Sandbox.mode(Repo, :manual)
        end

      assert errors == []
    end)

    root = Repo.one!(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1))

    Repo.insert!(%Platform.Tenancy.Org{
      id: ids.org,
      name: "Follower lock probe",
      slug: "followers-#{ids.org}",
      parent_org_id: root.id
    })

    Repo.insert!(%Profile{
      id: ids.profile,
      org_id: ids.org,
      name: "Follower lock probe",
      provider_profile_ref: "profile-A"
    })

    Repo.insert!(%Account{
      id: ids.account,
      profile_id: ids.profile,
      platform: "youtube",
      status: "connected",
      provider: "zernio",
      provider_account_ref: "account-A"
    })

    Repo.insert!(%SyncState{org_id: ids.org})
    ids
  end

  for resource <- [:profile, :account, :org, :pacing] do
    @resource resource
    test "busy #{@resource} does not queue a follower HTTP transaction", ids do
      parent = self()
      resource = @resource

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            hold(resource, ids)
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:held, pid})

            receive do
              :release -> :ok
            after
              5000 -> Repo.rollback(:holder_timeout)
            end
          end)
        end)

      assert_receive {:held, holder_pid}, 2000

      worker =
        Task.async(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})
          FollowerSync.sync_org(ids.org, pace_ms: 0)
        end)

      try do
        assert_receive {:worker, worker_pid}, 2000
        refute worker_pid == holder_pid
        assert {:ok, {:ok, :busy}} = Task.yield(worker, 1000)

        assert Repo.aggregate(
                 from(s in FollowerSnapshot, where: s.account_id == ^ids.account),
                 :count
               ) == 0
      after
        send(holder.pid, :release)
        Task.await(holder, 3000)
        if Process.alive?(worker.pid), do: Task.await(worker, 3000)
      end
    end
  end

  defp hold(:profile, ids),
    do: Repo.one!(from(p in Profile, where: p.id == ^ids.profile, lock: "FOR UPDATE"))

  defp hold(:account, ids),
    do: Repo.one!(from(a in Account, where: a.id == ^ids.account, lock: "FOR UPDATE"))

  defp hold(:org, ids),
    do: Repo.one!(from(s in SyncState, where: s.org_id == ^ids.org, lock: "FOR UPDATE"))

  defp hold(:pacing, _ids), do: Repo.query!("SELECT pg_advisory_xact_lock(734002911)")
end
