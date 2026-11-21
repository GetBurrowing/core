defmodule Platform.Social.FollowerSyncTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  import Ecto.Query
  import ExUnit.CaptureLog
  alias Platform.Social.{AnalyticsSync, FollowerSnapshot, FollowerSync, FollowerSyncState}
  alias Platform.Social.Analytics.SyncState
  alias Platform.Social.Publisher.Zernio, as: Publisher
  @now ~U[2026-11-21 12:00:00.000000Z]

  setup do
    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "follower-fixture-key",
        scope: {:integration, nil},
        provider: "social"
      )

    org = org_id!()

    {profile, account} =
      social_account!(org, "youtube", %{
        provider: "zernio",
        provider_account_ref: "account-A",
        status: "connected"
      })

    profile = Repo.update!(Ecto.Changeset.change(profile, provider_profile_ref: "profile-A"))
    %{org: org, profile: profile, account: account}
  end

  defp body(value \\ 97, overrides \\ %{}, now \\ @now) do
    finish = DateTime.to_date(now)

    Map.merge(
      %{
        "data" => [
          %{
            "date" => Date.to_iso8601(Date.add(finish, -1)),
            "accountId" => "account-A",
            "profileId" => "profile-A",
            "platform" => "youtube",
            "username" => "example",
            "metrics" => %{"followers" => value}
          }
        ],
        "pagination" => %{"nextCursor" => nil, "hasMore" => false},
        "meta" => %{
          "entity" => "accounts",
          "granularity" => "day",
          "groupBy" => "account",
          "attribution" => "publish",
          "fromDate" => Date.to_iso8601(Date.add(finish, -89)),
          "toDate" => Date.to_iso8601(finish),
          "stale" => false,
          "staleSince" => nil
        }
      },
      overrides
    )
  end

  defp stub(response, status \\ 200, headers \\ []) do
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      send(parent, {:follower_http, URI.decode_query(conn.query_string)})
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
    end)
  end

  defp run(c, now \\ @now), do: FollowerSync.sync_org(c.org, now: now, pace_ms: 0)

  test "one bounded daily read persists and an immediate repeated sweep does not refetch", c do
    stub(body())
    assert {:ok, {:refreshed, 1}} = run(c)
    assert [%{followers: 97, date: ~D[2026-11-20]}] = Repo.all(FollowerSnapshot)

    assert_received {:follower_http,
                     %{
                       "accountId" => "account-A",
                       "fromDate" => "2026-08-24",
                       "toDate" => "2026-11-21"
                     }}

    state = Repo.get!(FollowerSyncState, c.account.id)
    assert state.succeeded_at == @now
    assert state.next_attempt_at == ~U[2026-11-21 13:00:00.000000Z]
    assert {:ok, :idle} = run(c)
    refute_received {:follower_http, _}
  end

  test "multiple accounts advance one at a time without adding a request loop", c do
    {:ok, _} =
      Platform.Social.create_account(c.org, c.profile, %{
        platform: "youtube",
        provider: "zernio",
        provider_account_ref: "account-B",
        status: "connected"
      })

    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      query = URI.decode_query(conn.query_string)
      send(parent, {:bounded_request, query["accountId"]})
      value = body()

      Req.Test.json(conn, %{
        value
        | "data" => [%{hd(value["data"]) | "accountId" => query["accountId"]}]
      })
    end)

    assert {:ok, {:refreshed, 1}} = run(c)
    assert_received {:bounded_request, "account-A"}
    refute_received {:bounded_request, _}
    assert {:ok, {:refreshed, 1}} = run(c)
    assert_received {:bounded_request, "account-B"}
    refute_received {:bounded_request, _}
    assert {:ok, :idle} = run(c)
    assert Repo.aggregate(FollowerSnapshot, :count) == 2
  end

  test "failed refresh retains observations and durable backoff blocks a new worker", c do
    # The post reader uses the wall clock; both sides must share its anchor.
    now = DateTime.utc_now()
    stub(body(97, %{}, now))
    assert {:ok, {:refreshed, 1}} = run(c, now)
    later = DateTime.add(now, 3600)
    stub(%{}, 429, [{"retry-after", "120"}])
    assert {:ok, {:failed, :rate_limited}} = run(c, later)
    assert [%{followers: 97}] = Repo.all(FollowerSnapshot)
    assert Repo.get!(FollowerSyncState, c.account.id).last_error == "rate_limited"
    assert Repo.get!(SyncState, c.org).retry_at == DateTime.add(later, 120)
    assert_received {:follower_http, _}
    assert_received {:follower_http, _}
    assert {:ok, :deferred} = run(c, DateTime.add(later, 1))
    refute_received {:follower_http, _}
    assert {:ok, :deferred} = AnalyticsSync.sync_org(c.org, pace_ms: 0, max_requests: 1)
  end

  test "the shared provider deadline prevents sibling-org follower and post requests", c do
    now = DateTime.utc_now()
    stub(%{}, 429, [{"retry-after", "120"}])
    assert {:ok, {:failed, :rate_limited}} = run(c, now)
    deadline = Repo.get!(SyncState, c.org).provider_retry_at
    assert deadline == DateTime.add(now, 120)
    assert DateTime.compare(deadline, DateTime.utc_now()) == :gt
    other_org = org_id!()

    {profile, _} =
      social_account!(other_org, "youtube", %{
        provider: "zernio",
        provider_account_ref: "account-B",
        status: "connected"
      })

    Repo.update!(Ecto.Changeset.change(profile, provider_profile_ref: "profile-B"))

    assert {:ok, :deferred} =
             FollowerSync.sync_org(other_org, now: DateTime.add(now, 1), pace_ms: 0)

    post_org = org_id!()

    assert {:ok, {:deferred, {:provider_deferred, _}}} =
             AnalyticsSync.sync_org(post_org, pace_ms: 0, max_requests: 1)

    assert_received {:follower_http, _}
    refute_received {:follower_http, _}

    for name <- [:provider_budget_restart_one, :provider_budget_restart_two] do
      pid =
        start_supervised!(
          {AnalyticsSync,
           name: name,
           start: true,
           boot_sweep: false,
           pace_ms: 0,
           max_requests: 1,
           now: DateTime.add(now, 1),
           interval_ms: 3_600_000,
           notify: self()}
        )

      Req.Test.allow(Publisher, self(), pid)
      send(pid, :sweep)
      assert_receive {:analytics_swept, ^pid}, 2000
      stop_supervised!(name)
    end

    refute_received {:follower_http, _}

    expired = DateTime.add(now, -1)

    for org <- [c.org, other_org, post_org] do
      Repo.get!(SyncState, org)
      |> Ecto.Changeset.change(retry_at: expired, provider_retry_at: expired)
      |> Repo.update!()
    end

    resumed_at = DateTime.add(now, 121)
    value = body(97, %{}, resumed_at)
    entry = %{hd(value["data"]) | "accountId" => "account-B", "profileId" => "profile-B"}
    stub(%{value | "data" => [entry]})

    assert {:ok, {:refreshed, 1}} =
             FollowerSync.sync_org(other_org, now: resumed_at, pace_ms: 0)

    assert_received {:follower_http, %{"accountId" => "account-B"}}
    refute_received {:follower_http, _}
  end

  test "revised values overwrite and mismatched identity preserves the last good page", c do
    stub(body())
    assert {:ok, {:refreshed, 1}} = run(c)
    stub(body(104))
    assert {:ok, {:refreshed, 1}} = run(c, DateTime.add(@now, 3600))
    assert [%{followers: 104}] = Repo.all(FollowerSnapshot)
    bad = body(999)
    bad = %{bad | "data" => [%{hd(bad["data"]) | "profileId" => "foreign-profile"}]}
    stub(bad)
    assert {:ok, {:failed, :identity_mismatch}} = run(c, DateTime.add(@now, 7200))
    assert [%{followers: 104}] = Repo.all(FollowerSnapshot)
  end

  test "vendor stale metadata and timeout are retained separately from the observation date", c do
    value = body()

    stub(%{
      value
      | "meta" => %{value["meta"] | "stale" => true, "staleSince" => "2026-11-20T12:00:00Z"}
    })

    assert {:ok, {:refreshed, 1}} = run(c)
    assert Repo.get!(FollowerSyncState, c.account.id).source_stale
    Req.Test.stub(Publisher, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:ok, {:failed, :transport}} = run(c, DateTime.add(@now, 3600))
    assert [%{followers: 97, date: ~D[2026-11-20]}] = Repo.all(FollowerSnapshot)
    assert Repo.get!(FollowerSyncState, c.account.id).last_error == "transport"
  end

  test "LinkedIn and disconnected accounts cause no follower request", c do
    stub(body())
    Repo.update!(Ecto.Changeset.change(c.account, platform: "linkedin"))
    assert {:ok, :idle} = run(c)
    Repo.update!(Ecto.Changeset.change(c.account, platform: "youtube", status: "reauth_needed"))
    assert {:ok, :idle} = run(c)
    refute_received {:follower_http, _}
  end

  test "a failed read after reconnection does not inherit the old account's successful freshness",
       c do
    stub(body())
    assert {:ok, {:refreshed, 1}} = run(c)
    Repo.update!(Ecto.Changeset.change(c.account, provider_account_ref: "account-B"))
    stub(%{}, 503, [{"retry-after", "60"}])
    assert {:ok, {:failed, :rate_limited}} = run(c, DateTime.add(@now, 1))
    state = Repo.get!(FollowerSyncState, c.account.id)
    assert state.provider_account_ref == "account-B"
    assert state.succeeded_at == nil
    refute state.source_stale
  end

  test "existing scheduled analytics sweep invokes the follower reader, not a second worker", c do
    Repo.insert!(%SyncState{org_id: c.org, cursor: "C0", bootstrap_complete: true})
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      if String.ends_with?(conn.request_path, "/metrics/accounts") do
        send(parent, :scheduled_followers)
        Req.Test.json(conn, body())
      else
        Req.Test.json(conn, %{"data" => [], "nextCursor" => "C1", "hasMore" => false})
      end
    end)

    pid =
      start_supervised!(
        {AnalyticsSync,
         name: :ticker_analytics_worker,
         start: true,
         boot_sweep: false,
         pace_ms: 0,
         max_requests: 1,
         now: @now,
         interval_ms: 3_600_000,
         notify: self()}
      )

    Req.Test.allow(Publisher, self(), pid)
    send(pid, :sweep)
    assert_receive {:analytics_swept, ^pid}, 2000
    assert_received :scheduled_followers
    assert [%{followers: 97}] = Repo.all(FollowerSnapshot)
  end

  test "unexpected follower exceptions roll back without restarting or stopping later org post work",
       c do
    other_org = org_id!()

    {other_profile, other_account} =
      social_account!(other_org, "youtube", %{
        provider: "zernio",
        provider_account_ref: "account-B",
        status: "connected"
      })

    Repo.update!(Ecto.Changeset.change(other_profile, provider_profile_ref: "profile-B"))

    for {org, cursor} <- [{c.org, "org-A"}, {other_org, "org-B"}] do
      Repo.insert!(%SyncState{org_id: org, cursor: cursor, bootstrap_complete: true})
    end

    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      q = URI.decode_query(conn.query_string)

      if String.ends_with?(conn.request_path, "/metrics/accounts") do
        Repo.update_all(
          from(a in Platform.Social.Account, where: a.provider_account_ref == ^q["accountId"]),
          set: [handle: "must-roll-back"]
        )

        send(parent, {:forced_follower_raise, q["accountId"]})
        raise "forced follower boundary failure"
      else
        send(parent, {:post_org_read, q["cursor"]})
        Req.Test.json(conn, %{"data" => [], "nextCursor" => q["cursor"], "hasMore" => false})
      end
    end)

    {:ok, pid} =
      GenServer.start(AnalyticsSync,
        start: true,
        boot_sweep: false,
        pace_ms: 0,
        max_requests: 1,
        now: @now,
        interval_ms: 50,
        notify: self()
      )

    monitor = Process.monitor(pid)
    Req.Test.allow(Publisher, self(), pid)

    try do
      log =
        capture_log(fn ->
          send(pid, :sweep)
          assert_receive {:analytics_swept, ^pid}, 2000
          assert_receive {:post_org_read, "org-A"}
          assert_receive {:post_org_read, "org-B"}
          assert_receive {:forced_follower_raise, "account-A"}
          assert_receive {:forced_follower_raise, "account-B"}
          assert_receive {:analytics_swept, ^pid}, 2000
          refute_received {:DOWN, ^monitor, :process, ^pid, _}
        end)

      assert log =~ "follower_step_failed"
      assert log =~ "RuntimeError"
      assert Repo.get!(Platform.Social.Account, c.account.id).handle != "must-roll-back"
      assert Repo.get!(Platform.Social.Account, other_account.id).handle != "must-roll-back"
      assert Repo.aggregate(FollowerSyncState, :count) == 0
      assert Process.alive?(pid)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
      Process.demonitor(monitor, [:flush])
    end
  end

  test "follower shutdown exits remain shutdowns rather than successful sweeps", c do
    Repo.insert!(%SyncState{org_id: c.org, cursor: "C0", bootstrap_complete: true})

    Req.Test.stub(Publisher, fn conn ->
      if String.ends_with?(conn.request_path, "/metrics/accounts") do
        exit(:shutdown)
      else
        Req.Test.json(conn, %{"data" => [], "nextCursor" => "C1", "hasMore" => false})
      end
    end)

    {:ok, pid} =
      GenServer.start(AnalyticsSync,
        start: true,
        boot_sweep: false,
        pace_ms: 0,
        max_requests: 1,
        now: @now,
        notify: self()
      )

    ref = Process.monitor(pid)
    Req.Test.allow(Publisher, self(), pid)

    try do
      send(pid, :sweep)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 2000
      refute_received {:analytics_swept, ^pid}
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
      Process.demonitor(ref, [:flush])
    end
  end
end
