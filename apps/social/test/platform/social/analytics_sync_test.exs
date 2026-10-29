defmodule Platform.Social.AnalyticsSyncTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Social.{AnalyticsSync, Post}
  alias Platform.Social.Analytics.SyncState
  alias Platform.Social.Publisher.Zernio, as: Publisher

  setup do
    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "fixture-only-key",
        scope: {:integration, nil},
        provider: "social"
      )

    org = org_id!()

    {profile, account} =
      social_account!(org, "x", %{
        provider: "zernio",
        provider_account_ref: "account-A",
        status: "connected"
      })

    profile =
      profile |> Ecto.Changeset.change(provider_profile_ref: "profile-A") |> Repo.update!()

    post = published!(org, account, "publisher-A", "platform-A", "analytics-A")
    %{org: org, profile: profile, account: account, post: post}
  end

  defp published!(org, account, external_id, platform_id, analytics_id) do
    approved_post!(org, account)
    |> Ecto.Changeset.change(
      status: "published",
      external_id: external_id,
      platform_post_id: platform_id,
      analytics_external_id: analytics_id,
      metrics: %{"views" => 7},
      metrics_synced_at: ~U[2026-10-01 00:00:00.000000Z]
    )
    |> Repo.update!()
  end

  defp ready(org, cursor \\ "C0") do
    Repo.insert!(%SyncState{org_id: org, cursor: cursor, bootstrap_complete: true})
  end

  defp run(org, opts \\ []),
    do: AnalyticsSync.sync_org(org, Keyword.merge([pace_ms: 0, max_requests: 10], opts))

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        "postId" => "analytics-A",
        "accountId" => "account-A",
        "profileId" => "profile-A",
        "platform" => "twitter",
        "platformPostId" => "platform-A",
        "syncedAt" => "2026-10-29T00:00:00Z",
        "isDeleted" => false,
        "metrics" => %{"views" => 12400}
      },
      overrides
    )
  end

  defp page(data, cursor \\ "C1", more \\ false),
    do: %{"data" => data, "nextCursor" => cursor, "hasMore" => more}

  defp baseline(post, overrides \\ %{}) do
    Map.merge(
      %{
        "postId" => "analytics-A",
        "latePostId" => post.external_id,
        "analytics" => %{"views" => 999_999},
        "platformAnalytics" => [
          %{
            "platform" => "twitter",
            "platformPostId" => post.platform_post_id,
            "accountId" => "account-A",
            "syncStatus" => "synced",
            "analytics" => %{"views" => 100, "lastUpdated" => "2026-10-29T00:00:00Z"}
          }
        ]
      },
      overrides
    )
  end

  defp stub(fun) do
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      query = URI.decode_query(conn.query_string)
      send(parent, {:http, conn.request_path, query})
      fun.(conn, query)
    end)
  end

  test "bootstrap captures cursor before baseline, checkpoints and resumes after restart", c do
    Repo.update!(Ecto.Changeset.change(c.post, analytics_external_id: nil))

    stub(fn conn, q ->
      if String.ends_with?(conn.request_path, "/delta") do
        Req.Test.json(conn, page([], if(q["cursor"], do: "C2", else: "captured+/=")))
      else
        assert q == %{"postId" => "publisher-A"}
        Req.Test.json(conn, baseline(c.post))
      end
    end)

    assert :ok = run(c.org, max_requests: 1)
    assert Repo.get!(SyncState, c.org).cursor == "captured+/="
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
    assert_received {:http, "/api/v1/analytics/delta", %{}}
    refute_received {:http, "/api/v1/analytics", _}
    assert :ok = run(c.org, max_requests: 1)
    assert Repo.get!(SyncState, c.org).bootstrap_after_post_id == c.post.id
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 100}
    assert Repo.get!(Post, c.post.id).analytics_external_id == "analytics-A"
    assert {:ok, :caught_up} = run(c.org)
    state = Repo.get!(SyncState, c.org)
    assert state.bootstrap_complete
    assert state.cursor == "C2"
    assert state.replay_cursor == "captured+/="
    assert_received {:http, "/api/v1/analytics/delta", %{"cursor" => "captured+/="}}
  end

  test "pages apply absolute snapshots in feed order even when timestamp goes backwards", c do
    ready(c.org)

    stub(fn conn, q ->
      body =
        case q["cursor"] do
          "C0" ->
            page([snapshot()], "C1", true)

          "C1" ->
            page(
              [snapshot(%{"metrics" => %{"views" => 5}, "syncedAt" => "2026-10-20T00:00:00Z"})],
              "C2"
            )

          "C2" ->
            page(
              [snapshot(%{"metrics" => %{"views" => 5}, "syncedAt" => "2026-10-20T00:00:00Z"})],
              "C3"
            )
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, :caught_up} = run(c.org)
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 5}
    assert Repo.get!(Post, c.post.id).metrics_synced_at == ~U[2026-10-20 00:00:00.000000Z]
    assert Repo.get!(SyncState, c.org).cursor == "C2"
    assert {:ok, :caught_up} = run(c.org)
    assert_received {:http, _, %{"cursor" => "C2"}}
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 5}
  end

  test "cross-post and cross-org isolation requires post ID as well as platform identity", c do
    ready(c.org)
    # Same account AND platform-post collision deliberately makes the post ID
    # predicate necessary; a platform-only mutant must alter this other row.
    other = published!(c.org, c.account, "publisher-B", "platform-A", "analytics-B")
    org_b = org_id!()

    {profile_b, account_b} =
      social_account!(org_b, "x", %{
        provider: "zernio",
        provider_account_ref: "account-B",
        status: "connected"
      })

    Repo.update!(Ecto.Changeset.change(profile_b, provider_profile_ref: "profile-B"))
    foreign = published!(org_b, account_b, "publisher-A", "platform-A", "analytics-A")

    stub(fn conn, _ ->
      Req.Test.json(
        conn,
        page([
          snapshot(),
          snapshot(%{"postId" => "unknown", "metrics" => %{"views" => 999}}),
          snapshot(%{
            "accountId" => "account-B",
            "profileId" => "profile-B",
            "metrics" => %{"views" => 888}
          })
        ])
      )
    end)

    assert {:ok, :caught_up} = run(c.org)
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 12400}
    assert Repo.get!(Post, other.id).metrics == %{"views" => 7}
    assert Repo.get!(Post, foreign.id).metrics == %{"views" => 7}
    assert Repo.get(SyncState, org_b) == nil
  end

  test "deleted and unknown snapshots do not clear last values", c do
    ready(c.org)

    stub(fn conn, _ ->
      Req.Test.json(
        conn,
        page([snapshot(%{"isDeleted" => true}), snapshot(%{"postId" => "unknown"})])
      )
    end)

    assert {:ok, :caught_up} = run(c.org)
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
    assert Repo.get!(SyncState, c.org).cursor == "C1"
  end

  for status <- [202, 424, 429, 503] do
    test "HTTP #{status} keeps values and cursor and persists retry deadline", c do
      status = unquote(status)
      ready(c.org)

      stub(fn conn, _ ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "300")
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{})
      end)

      assert {:ok, {:deferred, _}} = run(c.org)
      state = Repo.get!(SyncState, c.org)
      assert state.cursor == "C0"
      assert DateTime.compare(state.retry_at, DateTime.utc_now()) == :gt
      assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
      assert Repo.get!(Post, c.post.id).metrics_synced_at == c.post.metrics_synced_at
      assert_received {:http, _, _}
      assert {:ok, :deferred} = run(c.org)
      refute_received {:http, _, _}
    end
  end

  test "incomplete identity rejects a page without applying snapshots or advancing cursor", c do
    ready(c.org)

    stub(fn conn, _ ->
      Req.Test.json(conn, page([snapshot(), Map.delete(snapshot(), "postId")]))
    end)

    assert {:ok, {:deferred, :invalid_response}} = run(c.org)
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
    assert Repo.get!(SyncState, c.org).cursor == "C0"
  end

  test "empty settling page retains replay position across runs", c do
    ready(c.org)
    stub(fn conn, _ -> Req.Test.json(conn, page([], "settling-position")) end)
    assert {:ok, :caught_up} = run(c.org)
    assert {:ok, :caught_up} = run(c.org)
    assert Repo.get!(SyncState, c.org).cursor == "settling-position"
    assert Repo.get!(SyncState, c.org).replay_cursor == "C0"
    assert_received {:http, _, %{"cursor" => "C0"}}
    assert_received {:http, _, %{"cursor" => "C0"}}
  end

  test "expired cursor captures fresh position before reloading mapped baseline", c do
    ready(c.org, "expired")

    stub(fn conn, q ->
      cond do
        q["cursor"] == "expired" -> conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
        String.ends_with?(conn.request_path, "/delta") -> Req.Test.json(conn, page([], "fresh"))
        true -> Req.Test.json(conn, baseline(c.post))
      end
    end)

    assert :ok = run(c.org, max_requests: 2)
    assert Repo.get!(SyncState, c.org).cursor == "fresh"
    refute Repo.get!(SyncState, c.org).bootstrap_complete
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
    assert :ok = run(c.org, max_requests: 1)
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 100}
  end

  test "baseline never learns mapping from a different publisher ID", c do
    Repo.update!(Ecto.Changeset.change(c.post, analytics_external_id: nil))
    ready(c.org)

    stub(fn conn, _ ->
      Req.Test.json(conn, baseline(c.post, %{"latePostId" => "somebody-else"}))
    end)

    assert :ok = run(c.org, max_requests: 1)
    assert Repo.get!(Post, c.post.id).analytics_external_id == nil
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
  end

  test "a crash during page application rolls back earlier metrics and cursor", c do
    ready(c.org)
    other = published!(c.org, c.account, "publisher-B", "platform-B", "analytics-B")
    # Inject a real DB fault on the SECOND snapshot, after the first update.
    # The CHECK is sandbox-local and disappears with test rollback.
    Repo.query!(
      "ALTER TABLE social_posts ADD CONSTRAINT analytics_fault_probe CHECK (COALESCE((metrics->>'views')::bigint, 0) < 900) NOT VALID"
    )

    stub(fn conn, _ ->
      Req.Test.json(
        conn,
        page([
          snapshot(%{"metrics" => %{"views" => 100}}),
          snapshot(%{
            "postId" => "analytics-B",
            "platformPostId" => "platform-B",
            "metrics" => %{"views" => 999}
          })
        ])
      )
    end)

    assert_raise Ecto.ConstraintError, fn -> run(c.org) end
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
    assert Repo.get!(Post, other.id).metrics == %{"views" => 7}
    assert Repo.get!(SyncState, c.org).cursor == "C0"
  end

  test "page budget bounds sweeps and request pacing prevents a burst", c do
    ready(c.org)
    owner = self()

    stub(fn conn, q ->
      send(owner, {:request_at, System.monotonic_time(:millisecond)})
      Req.Test.json(conn, page([snapshot()], q["cursor"] <> "x", true))
    end)

    assert :ok = run(c.org, max_requests: 2, pace_ms: 20)
    assert_received {:request_at, first}
    assert_received {:request_at, second}
    assert second - first >= 20
    refute_received {:request_at, _}
    assert Repo.get!(SyncState, c.org).cursor == "C0xx"
  end

  test "worker restart reads durable cursor instead of bootstrapping again", c do
    ready(c.org)

    stub(fn conn, q ->
      assert q["cursor"] in ["C0", "C1"]
      Req.Test.json(conn, page([snapshot()], if(q["cursor"] == "C0", do: "C1", else: "C2")))
    end)

    for name <- [:analytics_restart_first, :analytics_restart_second] do
      pid =
        start_supervised!(
          {AnalyticsSync,
           name: name,
           start: true,
           boot_sweep: false,
           pace_ms: 0,
           max_requests: 1,
           interval_ms: 3_600_000,
           notify: self()}
        )

      Req.Test.allow(Publisher, self(), pid)
      send(pid, :sweep)
      assert_receive {:analytics_swept, ^pid}, 2000
      stop_supervised!(name)
    end

    assert Repo.get!(SyncState, c.org).cursor == "C2"
    assert_received {:http, _, %{"cursor" => "C0"}}
    assert_received {:http, _, %{"cursor" => "C1"}}
    refute_received {:http, _, %{}}
  end

  test "pending baseline survives restart without skipping unfinished post", c do
    Repo.update!(Ecto.Changeset.change(c.post, analytics_external_id: nil))
    Repo.insert!(%SyncState{org_id: c.org, cursor: "captured"})
    stub(fn conn, _ -> conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{}) end)
    assert :ok = run(c.org, max_requests: 1)
    state = Repo.get!(SyncState, c.org)
    assert state.cursor == "captured"
    assert state.bootstrap_after_post_id == c.post.id
    assert state.pending_baseline_ids == [c.post.id]
    refute state.bootstrap_complete

    Repo.update!(
      Ecto.Changeset.change(state, baseline_retry_at: DateTime.add(DateTime.utc_now(), -1))
    )

    stub(fn conn, _ -> Req.Test.json(conn, baseline(c.post)) end)
    assert :ok = run(c.org, max_requests: 1)
    assert Repo.get!(SyncState, c.org).bootstrap_after_post_id == c.post.id
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 100}
  end

  test "unavailable new baseline cannot starve an established post's delta", c do
    ready(c.org)
    pending = published!(c.org, c.account, "publisher-pending", "platform-pending", nil)

    stub(fn conn, _ ->
      if String.ends_with?(conn.request_path, "/delta"),
        do: Req.Test.json(conn, page([snapshot()])),
        else: conn |> Plug.Conn.put_status(424) |> Req.Test.json(%{})
    end)

    assert {:ok, :caught_up} = run(c.org)
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 12400}
    assert Repo.get!(Post, pending.id).metrics == %{"views" => 7}
    state = Repo.get!(SyncState, c.org)
    assert state.pending_baseline_ids == [pending.id]
    assert state.retry_at == nil
    assert DateTime.compare(state.baseline_retry_at, DateTime.utc_now()) == :gt
    assert {:ok, :caught_up} = run(c.org)
    assert_received {:http, "/api/v1/analytics", _}
    refute_received {:http, "/api/v1/analytics", _}
    assert_received {:http, "/api/v1/analytics/delta", %{"cursor" => "C0"}}
    assert_received {:http, "/api/v1/analytics/delta", %{"cursor" => "C1"}}
  end

  test "200 pending platform retains an old mapping but queues unfinished rebaseline", c do
    Repo.insert!(%SyncState{org_id: c.org, cursor: "fresh", bootstrap_complete: false})
    stub(fn conn, _ -> Req.Test.json(conn, baseline(c.post, %{"platformAnalytics" => []})) end)
    assert :ok = run(c.org, max_requests: 1)
    state = Repo.get!(SyncState, c.org)
    assert state.pending_baseline_ids == [c.post.id]
    assert state.bootstrap_after_post_id == c.post.id
    assert Repo.get!(Post, c.post.id).metrics == %{"views" => 7}
    assert Repo.get!(Post, c.post.id).analytics_external_id == "analytics-A"
  end

  test "release host enables analytics only in prod even without Social config" do
    previous = Application.fetch_env(:social, :analytics_sync)
    previous_env = Application.fetch_env(:platform, :env)

    try do
      Application.delete_env(:social, :analytics_sync)

      for env <- [:test, :dev, :prod] do
        Application.put_env(:platform, :env, env)
        assert {:ok, options} = AnalyticsSync.init(boot_sweep: false)
        assert options[:start] == (env == :prod)
      end

      Application.put_env(:social, :analytics_sync, start: false)
      assert {:ok, options} = AnalyticsSync.init(boot_sweep: false)
      refute options[:start]
    after
      case previous do
        {:ok, value} -> Application.put_env(:social, :analytics_sync, value)
        :error -> Application.delete_env(:social, :analytics_sync)
      end

      case previous_env do
        {:ok, value} -> Application.put_env(:platform, :env, value)
        :error -> Application.delete_env(:platform, :env)
      end
    end
  end

  test "ordinary startup is disabled; explicit worker opt-in performs a bounded sweep", c do
    assert Application.get_env(:social, :analytics_sync)[:start] == false
    stub(fn conn, _ -> Req.Test.json(conn, page([], "startup")) end)

    parked =
      start_supervised!({AnalyticsSync, name: :analytics_parked, start: false, notify: self()})

    assert :sys.get_state(parked)[:start] == false
    send(parked, :sweep)
    assert_receive {:analytics_swept, ^parked}
    refute_received {:http, _, _}

    pid =
      start_supervised!(
        {AnalyticsSync,
         name: :analytics_opt_in,
         start: true,
         boot_sweep: false,
         pace_ms: 0,
         max_requests: 1,
         interval_ms: 3_600_000,
         notify: self()}
      )

    Req.Test.allow(Publisher, self(), pid)
    send(pid, :sweep)
    assert_receive {:analytics_swept, ^pid}, 2000
    assert Repo.get!(SyncState, c.org).cursor == "startup"
  end
end
