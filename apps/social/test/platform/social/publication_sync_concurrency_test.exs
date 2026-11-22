defmodule Platform.Social.PublicationSyncConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social.{Account, Profile, PublicationSync, Secrets}
  alias Platform.Social.Analytics.{PublicationOrgBudget, PublicationSyncState, SyncState}
  alias Platform.Social.Publisher.Zernio, as: Publisher

  setup do
    Sandbox.mode(Repo, :auto)
    org_id = Platform.SocialFixtures.org_id!()
    {:ok, profile} = Platform.Social.create_profile(org_id, %{name: "Publication isolation"})
    profile = Repo.update!(Ecto.Changeset.change(profile, provider_profile_ref: "profile-race"))

    {:ok, account} =
      Platform.Social.create_account(org_id, profile, %{
        platform: "youtube",
        provider: "zernio",
        provider_account_ref: "account-race",
        status: "connected"
      })

    Repo.insert!(%SyncState{org_id: org_id})

    Repo.insert!(%PublicationSyncState{
      account_id: account.id,
      kind: "discovery",
      provider_account_ref: account.provider_account_ref,
      provider_profile_ref: profile.provider_profile_ref
    })

    prior_key = Secrets.zernio_api_key()

    owned_key =
      if match?({:ok, _}, prior_key) do
        nil
      else
        {:ok, key} =
          Platform.Vault.put("social:zernio:api_key", :api_key, "publication-race-key",
            scope: {:integration, nil},
            provider: "social"
          )

        key.id
      end

    on_exit(fn ->
      try do
        Repo.delete_all(from(p in Profile, where: p.id == ^profile.id))
        Repo.delete_all(from(b in PublicationOrgBudget, where: b.org_id == ^org_id))
        Repo.delete_all(from(s in SyncState, where: s.org_id == ^org_id))
        Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org_id))

        if owned_key,
          do: Repo.delete_all(from(k in Platform.Vault.Credential, where: k.id == ^owned_key))
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    %{org_id: org_id, profile: profile, account: account, now: DateTime.utc_now()}
  end

  defp reply(conn) do
    q = URI.decode_query(conn.query_string)

    Req.Test.json(conn, %{
      "data" => [],
      "pagination" => %{"hasMore" => false, "nextCursor" => nil},
      "meta" => %{
        "entity" => "posts",
        "granularity" => "total",
        "fromDate" => q["fromDate"],
        "toDate" => q["toDate"],
        "stale" => false,
        "staleSince" => nil,
        "missingIds" => []
      }
    })
  end

  defp probe(query) do
    Task.async(fn ->
      Repo.transaction(fn ->
        try do
          Repo.one!(query)
          :available
        rescue
          error in Postgrex.Error ->
            if match?(%{code: :lock_not_available}, error.postgres),
              do: Repo.rollback(:locked),
              else: reraise(error, __STACKTRACE__)
        end
      end)
    end)
    |> Task.await(5_000)
  end

  test "request locks span HTTP while the committed allowance row is not held", c do
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      checks =
        [
          org: from(s in SyncState, where: s.org_id == ^c.org_id, lock: "FOR UPDATE NOWAIT"),
          profile: from(p in Profile, where: p.id == ^c.profile.id, lock: "FOR UPDATE NOWAIT"),
          account: from(a in Account, where: a.id == ^c.account.id, lock: "FOR UPDATE NOWAIT"),
          state:
            from(s in PublicationSyncState,
              where: s.account_id == ^c.account.id,
              lock: "FOR UPDATE NOWAIT"
            ),
          allowance:
            from(b in PublicationOrgBudget,
              where: b.org_id == ^c.org_id,
              lock: "FOR UPDATE NOWAIT"
            )
        ]
        |> Map.new(fn {name, query} -> {name, probe(query)} end)

      advisory =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_try_advisory_xact_lock(734002911)").rows
          end)
        end)
        |> Task.await(5_000)

      send(parent, {:held_during_http, Repo.in_transaction?(), checks, advisory})
      reply(conn)
    end)

    assert {:ok, :incomplete} = PublicationSync.step(c.org_id, clock: fn -> c.now end, pace_ms: 0)

    assert_received {:held_during_http, true,
                     %{
                       org: {:error, :locked},
                       profile: {:error, :locked},
                       account: {:error, :locked},
                       state: {:error, :locked},
                       allowance: {:ok, :available}
                     }, {:ok, [[false]]}}
  end

  test "a manually held advisory lock makes publication skip while spending its allowance",
       c do
    parent = self()
    Req.Test.stub(Publisher, fn _ -> flunk("a busy step must not issue HTTP") end)

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(734002911)")
          send(parent, :provider_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :provider_held

    result =
      try do
        PublicationSync.step(c.org_id, clock: fn -> c.now end, pace_ms: 0)
      after
        send(holder.pid, :release)
      end

    Task.await(holder, 5_000)
    assert result == {:ok, :busy}

    assert DateTime.compare(Repo.get!(PublicationOrgBudget, c.org_id).next_attempt_at, c.now) ==
             :gt

    assert Repo.one!(from(s in PublicationSyncState, where: s.account_id == ^c.account.id)).cursor ==
             nil
  end

  defp await_advisory_waiter(pid, expires) do
    [[waiting?]] =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = $1 AND locktype = 'advisory' AND classid = 0 AND objid = 734002911 AND NOT granted)",
        [pid]
      ).rows

    cond do
      waiting? ->
        true

      System.monotonic_time(:millisecond) >= expires ->
        false

      true ->
        Process.sleep(10)
        await_advisory_waiter(pid, expires)
    end
  end

  test "existing blocking post analytics waits behind publication HTTP and preserves the 1100ms pace",
       c do
    other_org = Platform.SocialFixtures.org_id!()

    {:ok, other_profile} =
      Platform.Social.create_profile(other_org, %{name: "Post analytics peer"})

    Repo.update!(Ecto.Changeset.change(other_profile, provider_profile_ref: "post-profile"))

    {:ok, _} =
      Platform.Social.create_account(other_org, other_profile, %{
        platform: "x",
        provider: "zernio",
        provider_account_ref: "post-account",
        status: "connected"
      })

    Repo.insert!(%SyncState{org_id: other_org, cursor: "post-cursor", bootstrap_complete: true})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(p in Profile, where: p.id == ^other_profile.id))
      Repo.delete_all(from(s in SyncState, where: s.org_id == ^other_org))
      Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^other_org))
    end)

    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      if String.ends_with?(conn.request_path, "/metrics/posts") do
        send(parent, {:publication_started, System.monotonic_time(:millisecond)})

        receive do
          :release_http -> :ok
        end

        reply(conn)
      else
        send(parent, {:post_started, System.monotonic_time(:millisecond)})
        Req.Test.json(conn, %{"data" => [], "hasMore" => false, "nextCursor" => "post-cursor"})
      end
    end)

    publication = Task.async(fn -> PublicationSync.step(c.org_id, pace_ms: 1100) end)
    Req.Test.allow(Publisher, self(), publication.pid)
    assert_receive {:publication_started, first_at}, 4_000

    post =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:post_backend, backend})
          Platform.Social.AnalyticsSync.sync_org(other_org, pace_ms: 1100, max_requests: 1)
        end)
      end)

    Req.Test.allow(Publisher, self(), post.pid)

    try do
      assert_receive {:post_backend, backend}, 2_000
      assert await_advisory_waiter(backend, System.monotonic_time(:millisecond) + 2_000)
      refute_received {:post_started, _}
    after
      send(publication.pid, :release_http)
    end

    assert {:ok, :incomplete} = Task.await(publication, 5_000)
    assert {:ok, _} = Task.await(post, 5_000)
    assert_received {:post_started, second_at}
    assert second_at - first_at >= 1100
  end

  test "actual follower HTTP blocks publication without refunding the allowance", c do
    other_org = Platform.SocialFixtures.org_id!()
    {:ok, other_profile} = Platform.Social.create_profile(other_org, %{name: "Follower peer"})
    Repo.update!(Ecto.Changeset.change(other_profile, provider_profile_ref: "follower-profile"))

    {:ok, _} =
      Platform.Social.create_account(other_org, other_profile, %{
        platform: "youtube",
        provider: "zernio",
        provider_account_ref: "follower-account",
        status: "connected"
      })

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(p in Profile, where: p.id == ^other_profile.id))
      Repo.delete_all(from(s in SyncState, where: s.org_id == ^other_org))
      Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^other_org))
    end)

    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      q = URI.decode_query(conn.query_string)

      if String.ends_with?(conn.request_path, "/metrics/accounts") do
        send(parent, :actual_follower_http)

        receive do
          :release_follower -> :ok
        end

        Req.Test.json(conn, %{
          "data" => [],
          "pagination" => %{"hasMore" => false, "nextCursor" => nil},
          "meta" => %{
            "entity" => "accounts",
            "granularity" => "day",
            "groupBy" => "account",
            "attribution" => "publish",
            "fromDate" => q["fromDate"],
            "toDate" => q["toDate"],
            "stale" => false,
            "staleSince" => nil
          }
        })
      else
        send(parent, :unexpected_publication_http)
        reply(conn)
      end
    end)

    # Start the real worker first, including its normal credential read inside
    # the request transaction. Publication's metadata-only preflight must not
    # wait for that credential's last-used UPDATE before spending its allowance
    # and failing the shared request try-lock.
    follower =
      Task.async(fn ->
        Platform.Social.FollowerSync.sync_org(other_org, now: c.now, pace_ms: 0)
      end)

    Req.Test.allow(Publisher, self(), follower.pid)

    try do
      assert_receive :actual_follower_http, 2_000

      publication =
        Task.async(fn ->
          PublicationSync.step(c.org_id, clock: fn -> c.now end, pace_ms: 0)
        end)

      Req.Test.allow(Publisher, self(), publication.pid)

      outcome =
        try do
          Task.yield(publication, 500)
        after
          send(follower.pid, :release_follower)
        end

      assert {:ok, _} = Task.await(follower, 5_000)
      # Drain a regression only after releasing its blocker; do not leave a
      # connection waiting for the pool timeout or retry the failing case.
      if is_nil(outcome), do: Task.await(publication, 5_000)
      assert outcome == {:ok, {:ok, :busy}}
      refute_received :unexpected_publication_http

      assert DateTime.compare(Repo.get!(PublicationOrgBudget, c.org_id).next_attempt_at, c.now) ==
               :gt
    after
      send(follower.pid, :release_follower)
    end
  end

  defp await_blocker(waiter, blocker, expires) do
    [[waiting?]] =
      Repo.query!("SELECT $2::int = ANY(pg_blocking_pids($1::int))", [waiter, blocker]).rows

    cond do
      waiting? ->
        true

      System.monotonic_time(:millisecond) >= expires ->
        false

      true ->
        Process.sleep(10)
        await_blocker(waiter, blocker, expires)
    end
  end

  test "a second-connection reconnect waits for HTTP then invalidates cursor and stales retained observations",
       c do
    approver =
      Platform.SocialFixtures.make_approver!(c.org_id, c.profile, Platform.SocialFixtures.user!())

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^approver.id))
    end)

    previous = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      if String.ends_with?(conn.request_path, "/metrics/posts") do
        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:publication_backend, backend})

        receive do
          :release_reconnect_http -> :ok
        end

        q = URI.decode_query(conn.query_string)

        Req.Test.json(conn, %{
          "data" => [
            %{
              "accountId" => "account-race",
              "profileId" => "profile-race",
              "platform" => "youtube",
              "platformPostId" => "abcdefghijk",
              "externalPostId" => "outside-fixture",
              "postId" => nil,
              "platformPostUrl" => "https://www.youtube.com/watch?v=abcdefghijk",
              "publishedAt" => q["toDate"] <> "T00:00:00Z",
              "lastSyncedAt" => DateTime.to_iso8601(c.now),
              "syncStatus" => "synced",
              "syncError" => nil,
              "isOwner" => nil,
              "isAd" => nil,
              "metrics" => %{"views" => 66}
            }
          ],
          "pagination" => %{"hasMore" => true, "nextCursor" => "retained-cursor"},
          "meta" => %{
            "entity" => "posts",
            "granularity" => "total",
            "fromDate" => q["fromDate"],
            "toDate" => q["toDate"],
            "stale" => false,
            "staleSince" => nil,
            "missingIds" => []
          }
        })
      else
        Req.Test.json(conn, %{
          "accounts" => [
            %{
              "_id" => "account-race",
              "platform" => "youtube",
              "profileId" => %{"_id" => "profile-race", "name" => "Fixture"},
              "username" => "fixture",
              "isActive" => true
            }
          ],
          "hasAnalyticsAccess" => true
        })
      end
    end)

    publication =
      Task.async(fn -> PublicationSync.step(c.org_id, clock: fn -> c.now end, pace_ms: 0) end)

    Req.Test.allow(Publisher, self(), publication.pid)
    assert_receive {:publication_backend, backend}, 2_000

    reconnect =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[writer]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:reconnect_writer, writer})

          Repo.transaction(fn ->
            Repo.one!(from(p in Profile, where: p.id == ^c.profile.id, lock: "FOR UPDATE"))

            Repo.get!(Account, c.account.id)
            |> Ecto.Changeset.change(status: "reauth_needed")
            |> Repo.update!()
          end)

          Platform.Social.complete_connect(c.org_id, c.profile, {:approver, approver.id}, %{
            account_ref: "account-race",
            platform: "youtube"
          })
        end)
      end)

    Req.Test.allow(Publisher, self(), reconnect.pid)

    waiting =
      try do
        assert_receive {:reconnect_writer, writer}, 2_000
        await_blocker(writer, backend, System.monotonic_time(:millisecond) + 2_000)
      after
        send(publication.pid, :release_reconnect_http)
      end

    assert {:ok, :incomplete} = Task.await(publication, 5_000)
    assert {:ok, _, :connected} = Task.await(reconnect, 5_000)
    assert waiting
    state = Repo.one!(from(s in PublicationSyncState, where: s.account_id == ^c.account.id))
    assert state.cursor == nil
    assert state.query_hash == nil

    assert Repo.one!(
             from(v in Platform.Social.Analytics.Publication,
               where: v.account_id == ^c.account.id
             )
           ).source_stale
  end
end
