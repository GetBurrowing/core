defmodule Platform.Social.PublicationSyncTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  import Platform.SocialFixtures
  alias Platform.Repo
  alias Platform.Social.{Post, PublicationSync}

  alias Platform.Social.Analytics.{
    Publication,
    PublicationOrgBudget,
    PublicationSyncState,
    Publications,
    SyncState
  }

  alias Platform.Social.Publisher.Zernio, as: Publisher

  @now ~U[2026-11-22 06:00:00.000000Z]

  setup do
    {profile, account} = social_account!(org_id!(), "youtube", %{provider: "zernio"})

    profile =
      Repo.update!(Ecto.Changeset.change(profile, provider_profile_ref: "profile-fixture"))

    account =
      Repo.update!(
        Ecto.Changeset.change(account,
          provider_account_ref: "account-fixture",
          status: "connected"
        )
      )

    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "publication-fixture-key",
        scope: {:integration, nil},
        provider: "social"
      )

    {:ok, profile: profile, account: account}
  end

  defp step(org, now \\ @now),
    do: apply(PublicationSync, :step, [org, [clock: fn -> now end, pace_ms: 0]])

  defp body(query) do
    %{
      "data" => [
        %{
          "accountId" => "account-fixture",
          "profileId" => "profile-fixture",
          "platform" => "youtube",
          "platformPostId" => "Abcdefg_123",
          "externalPostId" => "analytics-fixture",
          "postId" => nil,
          "platformPostUrl" => "https://www.youtube.com/watch?v=Abcdefg_123",
          "publishedAt" => "2026-11-16T01:33:50Z",
          "lastSyncedAt" => "2026-11-22T05:04:31Z",
          "syncStatus" => "synced",
          "syncError" => nil,
          "isOwner" => true,
          "isAd" => false,
          "metrics" => %{"views" => 66}
        }
      ],
      "pagination" => %{"hasMore" => false, "nextCursor" => nil},
      "meta" => %{
        "entity" => "posts",
        "granularity" => "total",
        "fromDate" => query["fromDate"],
        "toDate" => query["toDate"],
        "missingIds" => [],
        "stale" => false,
        "staleSince" => nil
      }
    }
  end

  defp stub(fun \\ nil) do
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      query = URI.decode_query(conn.query_string)
      send(parent, {:read, query, Repo.in_transaction?()})
      if fun, do: fun.(conn, query), else: Req.Test.json(conn, body(query))
    end)
  end

  test "discovery and day refresh share one durable allowance and HTTP stays inside the shared request transaction",
       ctx do
    stub()
    assert {:ok, :refreshed} = step(ctx.profile.org_id)
    assert_received {:read, %{"fromDate" => "2026-10-24", "toDate" => "2026-11-22"}, true}
    assert Repo.aggregate(Publication, :count) == 1
    assert Repo.aggregate(Post, :count) == 0
    assert Repo.get!(SyncState, ctx.profile.org_id).cursor == nil
    assert {:ok, :deferred} = step(ctx.profile.org_id)
    refute_received {:read, _, _}

    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, 61))

    assert_received {:read, %{"fromDate" => "2026-11-16", "toDate" => "2026-11-16"} = query, true}

    assert query["accountId"] == "account-fixture"
    refute Map.has_key?(query, "platformPostId")
    refute_received {:read, _, _}
  end

  test "defensive same-connection binding mutation refuses its response without cache writes",
       ctx do
    stub(fn conn, query ->
      Repo.update!(Ecto.Changeset.change(ctx.account, provider_account_ref: "replacement"))
      Req.Test.json(conn, body(query))
    end)

    assert {:error, :binding_changed} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    assert Repo.aggregate(Publication, :count) == 0
    assert Repo.aggregate(PublicationSyncState, :count) == 0
    assert Repo.get!(PublicationOrgBudget, ctx.profile.org_id).next_attempt_at > @now
  end

  test "publication rate limiting uses the existing install-wide org state without a second read",
       ctx do
    retry = DateTime.add(@now, 3600)
    Repo.insert!(%SyncState{org_id: ctx.profile.org_id, cursor: "post-stays", retry_at: retry})

    stub(fn conn, _ ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "600")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{})
    end)

    assert {:ok, :deferred} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    refute_received {:read, _, _}
    state = Repo.get!(SyncState, ctx.profile.org_id)
    assert state.provider_retry_at == DateTime.add(@now, 600)
    assert state.retry_at == retry
    assert state.cursor == "post-stays"
    assert Platform.Social.Analytics.Backoff.deadline(@now) == state.provider_retry_at

    assert {:ok, :deferred} = step(ctx.profile.org_id, DateTime.add(@now, 61))
    refute_received {:read, _, _}
  end

  test "an existing sibling-org provider deadline prevents a new publication read", ctx do
    Repo.insert!(%SyncState{org_id: org_id!(), provider_retry_at: DateTime.add(@now, 600)})
    stub()
    assert {:ok, :deferred} = step(ctx.profile.org_id)
    refute_received {:read, _, _}
  end

  test "partial listing progress resumes under the frozen account/date query on the next allowance",
       ctx do
    stub(fn conn, query ->
      value = body(query)

      value =
        cond do
          query["cursor"] -> %{value | "data" => []}
          query["fromDate"] == query["toDate"] -> value
          true -> put_in(value, ["pagination"], %{"hasMore" => true, "nextCursor" => "next-page"})
        end

      Req.Test.json(conn, value)
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id)
    assert_received {:read, original, true}
    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, 61))
    assert_received {:read, refresh_query, true}
    assert refresh_query["fromDate"] == "2026-11-16"
    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, 122))
    assert_received {:read, continued, true}
    assert Map.delete(continued, "cursor") == original
    assert continued["cursor"] == "next-page"
    assert Repo.aggregate(Publication, :count) == 1
  end

  test "the first query is durable before HTTP and a crashed attempt replays it across UTC midnight",
       ctx do
    at = ~U[2026-11-22 23:59:00.000000Z]
    stub(fn _conn, _query -> raise "controlled HTTP crash" end)
    assert_raise RuntimeError, "controlled HTTP crash", fn -> step(ctx.profile.org_id, at) end
    assert_received {:read, original, true}
    budget = Repo.get!(PublicationOrgBudget, ctx.profile.org_id)
    frozen = budget.reservations[ctx.account.id <> ":discovery"]
    assert frozen["query"]["from_date"] == "2026-10-24"
    assert frozen["query"]["to_date"] == "2026-11-22"
    assert is_binary(frozen["query_hash"])
    assert Repo.aggregate(PublicationSyncState, :count) == 0
    stub()
    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(at, 121))
    assert_received {:read, replay, true}
    assert replay == original
  end

  test "continuing older pages retain the backfill window index", ctx do
    stub(fn conn, query ->
      value = %{body(query) | "data" => []}

      value =
        if query["fromDate"] == "2026-10-24",
          do: value,
          else: put_in(value, ["pagination"], %{"hasMore" => true, "nextCursor" => "older-page"})

      Req.Test.json(conn, value)
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    assert {:ok, :incomplete} = step(ctx.profile.org_id, DateTime.add(@now, 61))
    assert_received {:read, %{"fromDate" => "2026-09-24"}, true}
    state = Repo.one!(from(s in PublicationSyncState, where: s.account_id == ^ctx.account.id))
    assert state.window_index == 1
  end

  test "a rejected older-window cursor restarts that frozen window rather than the recent head",
       ctx do
    stub(fn conn, query ->
      value = %{body(query) | "data" => []}

      cond do
        query["cursor"] ->
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})

        query["fromDate"] == "2026-10-24" ->
          Req.Test.json(conn, value)

        true ->
          Req.Test.json(
            conn,
            put_in(value, ["pagination"], %{"hasMore" => true, "nextCursor" => "older-page"})
          )
      end
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    assert {:ok, :incomplete} = step(ctx.profile.org_id, DateTime.add(@now, 61))
    assert_received {:read, older, true}
    assert {:ok, :deferred} = step(ctx.profile.org_id, DateTime.add(@now, 122))
    assert_received {:read, %{"cursor" => "older-page"}, true}
    assert {:ok, :incomplete} = step(ctx.profile.org_id, DateTime.add(@now, 423))
    assert_received {:read, replay, true}
    assert replay == older
  end

  test "nested invocation refuses a context where the allowance cannot commit independently",
       ctx do
    stub(fn conn, query ->
      assert {:error, :transaction_context} = step(ctx.profile.org_id, DateTime.add(@now, 61))
      Req.Test.json(conn, body(query))
    end)

    assert {:ok, :refreshed} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    refute_received {:read, _, _}
  end

  test "pagination cannot bypass the twelve-window history bound", ctx do
    stub(fn conn, query ->
      value = %{body(query) | "data" => []}

      value =
        if query["cursor"],
          do: value,
          else: put_in(value, ["pagination"], %{"hasMore" => true, "nextCursor" => "page-two"})

      Req.Test.json(conn, value)
    end)

    windows =
      for index <- 0..23 do
        assert {:ok, _} = step(ctx.profile.org_id, DateTime.add(@now, index * 61))
        assert_received {:read, query, true}
        query["fromDate"]
      end

    assert length(Enum.uniq(windows)) == 12
    assert {:ok, :idle} = step(ctx.profile.org_id, DateTime.add(@now, 24 * 61))
    refute_received {:read, _, _}
  end

  test "a second account progresses while discovery and refresh alternate under persisted allowance",
       ctx do
    {:ok, _} =
      Platform.Social.create_account(ctx.profile.org_id, ctx.profile, %{
        platform: "youtube",
        provider: "zernio",
        provider_account_ref: "account-second",
        status: "connected"
      })

    stub(fn conn, query ->
      value = body(query)
      value = put_in(value, ["data", Access.at(0), "accountId"], query["accountId"])
      Req.Test.json(conn, value)
    end)

    observed =
      for index <- 0..2 do
        assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, index * 61))
        assert_received {:read, query, true}
        query["accountId"]
      end

    assert Enum.sort(Enum.uniq(observed)) == ["account-fixture", "account-second"]
    assert Repo.aggregate(Publication, :count) == 2
  end

  test "no credentials or eligible account means no HTTP or spent allowance", ctx do
    stub()

    Repo.delete_all(
      from(k in Platform.Vault.Credential,
        where:
          k.slug == "social:zernio:api_key" and k.scope_type == "integration" and
            is_nil(k.scope_id)
      )
    )

    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner, do: send(owner, {:unset_key_preflight_sql, metadata.query})
        end,
        nil
      )

    try do
      assert {:ok, :idle} = step(ctx.profile.org_id)
    after
      :telemetry.detach(handler)
    end

    queries =
      Stream.repeatedly(fn ->
        receive do
          {:unset_key_preflight_sql, query} -> query
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert Enum.any?(queries, &String.contains?(&1, "vault_credentials"))
    refute Enum.any?(queries, &String.contains?(&1, "encrypted_data"))
    refute Enum.any?(queries, &Regex.match?(~r/\A(?:UPDATE|INSERT|DELETE)\b/, &1))
    refute_received {:read, _, _}
    assert Repo.aggregate(PublicationOrgBudget, :count) == 0
  end

  test "retained null ownership and ad fields allow the newer account-associated outside upload",
       ctx do
    stub(fn conn, query ->
      value = body(query)
      entry = %{hd(value["data"]) | "isOwner" => nil, "isAd" => nil}
      Req.Test.json(conn, %{value | "data" => [entry]})
    end)

    assert {:ok, :refreshed} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    row = Repo.one!(Publication)
    assert row.is_owner == nil
    assert row.is_ad == nil
    assert row.metrics["views"] == 66
  end

  test "successful same-reference reconnect invalidates its cursor and marks cached observations stale",
       ctx do
    stub(fn conn, query ->
      Req.Test.json(
        conn,
        put_in(body(query), ["pagination"], %{"hasMore" => true, "nextCursor" => "next"})
      )
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id)
    approver = make_approver!(ctx.profile.org_id, ctx.profile, user!())
    Repo.update!(Ecto.Changeset.change(ctx.account, status: "reauth_needed"))
    original = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, original) end)

    Req.Test.stub(Publisher, fn conn ->
      Req.Test.json(conn, %{
        "accounts" => [
          %{
            "_id" => "account-fixture",
            "platform" => "youtube",
            "profileId" => %{"_id" => "profile-fixture", "name" => "Fixture"},
            "username" => "fixture",
            "isActive" => true
          }
        ],
        "hasAnalyticsAccess" => true
      })
    end)

    assert {:ok, _, :connected} =
             Platform.Social.complete_connect(
               ctx.profile.org_id,
               ctx.profile,
               {:approver, approver.id},
               %{account_ref: "account-fixture", platform: "youtube"}
             )

    state = Repo.one!(from(s in PublicationSyncState, where: s.account_id == ^ctx.account.id))
    assert state.cursor == nil
    assert state.query_hash == nil
    assert Repo.one!(from(p in Publication, where: p.account_id == ^ctx.account.id)).source_stale
  end

  test "the ordinary analytics sweep adds one publication step without rewinding its legacy cursor",
       ctx do
    Repo.insert!(%SyncState{
      org_id: ctx.profile.org_id,
      cursor: "legacy-position",
      bootstrap_complete: true
    })

    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      query = URI.decode_query(conn.query_string)
      send(parent, {:sweep_read, conn.request_path})

      response =
        cond do
          String.ends_with?(conn.request_path, "/metrics/posts") ->
            body(query)

          String.ends_with?(conn.request_path, "/metrics/accounts") ->
            %{
              "data" => [],
              "pagination" => %{"hasMore" => false, "nextCursor" => nil},
              "meta" => %{
                "entity" => "accounts",
                "granularity" => "day",
                "groupBy" => "account",
                "attribution" => "publish",
                "fromDate" => query["fromDate"],
                "toDate" => query["toDate"],
                "stale" => false,
                "staleSince" => nil
              }
            }

          true ->
            %{"data" => [], "hasMore" => false, "nextCursor" => "legacy-position"}
        end

      Req.Test.json(conn, response)
    end)

    pid =
      start_supervised!(
        {Platform.Social.AnalyticsSync,
         [
           name: :publication_scheduler_fixture,
           start: true,
           boot_sweep: false,
           max_requests: 1,
           pace_ms: 0,
           now: @now,
           clock: fn -> @now end,
           notify: self(),
           interval_ms: 3_600_000
         ]}
      )

    Req.Test.allow(Publisher, self(), pid)
    send(pid, :sweep)
    assert_receive {:analytics_swept, ^pid}, 2_000
    assert_received {:sweep_read, "/api/v1/metrics/posts"}
    refute_received {:sweep_read, "/api/v1/metrics/posts"}
    assert Repo.aggregate(Publication, :count) == 1
    assert Repo.get!(SyncState, ctx.profile.org_id).cursor == "legacy-position"
  end

  test "a publication 429 prevents existing post and follower readers from issuing another request",
       ctx do
    now = DateTime.utc_now()

    stub(fn conn, _query ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "600")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{})
    end)

    assert {:ok, :deferred} = step(ctx.profile.org_id, now)
    assert_received {:read, _, true}
    Platform.Social.AnalyticsSync.sync_org(ctx.profile.org_id, pace_ms: 0, max_requests: 1)

    assert {:ok, :deferred} =
             Platform.Social.FollowerSync.sync_org(ctx.profile.org_id, pace_ms: 0, now: now)

    refute_received {:read, _, _}
  end

  test "a rejected cursor graph commits backoff, does not advance or demote, and later recovers",
       ctx do
    stub(fn conn, query ->
      value = body(query)

      pagination =
        cond do
          query["fromDate"] == query["toDate"] -> %{"hasMore" => false, "nextCursor" => nil}
          is_nil(query["cursor"]) -> %{"hasMore" => true, "nextCursor" => "A"}
          query["cursor"] == "A" -> %{"hasMore" => true, "nextCursor" => "B"}
          true -> %{"hasMore" => true, "nextCursor" => "A"}
        end

      Req.Test.json(conn, %{value | "pagination" => pagination})
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, 61))
    assert_received {:read, _, true}
    assert {:ok, :incomplete} = step(ctx.profile.org_id, DateTime.add(@now, 122))
    assert_received {:read, _, true}
    assert {:ok, :deferred} = step(ctx.profile.org_id, DateTime.add(@now, 183))
    assert_received {:read, %{"cursor" => "B"}, true}

    state =
      Repo.one!(
        from(s in PublicationSyncState,
          where: s.account_id == ^ctx.account.id and s.kind == "discovery"
        )
      )

    assert state.cursor == "B"
    assert state.last_error == "cursor_loop"
    assert state.next_attempt_at == DateTime.add(@now, 483)
    refute Repo.one!(Publication).not_listed
    assert {:ok, :idle} = step(ctx.profile.org_id, DateTime.add(@now, 244))
    refute_received {:read, _, _}
    stub()
    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, 484))
    assert_received {:read, %{"cursor" => "B"}, true}

    assert Repo.one!(
             from(s in PublicationSyncState,
               where: s.account_id == ^ctx.account.id and s.kind == "discovery"
             )
           ).last_error == nil
  end

  for {field, bad} <- [
        {"stale", :absent},
        {"stale", nil},
        {"stale", "false"},
        {"missingIds", :absent},
        {"missingIds", nil},
        {"missingIds", [1]},
        {"staleSince", :absent},
        {"staleSince", false}
      ] do
    @field field
    @bad bad
    test "malformed required metadata #{field}=#{inspect(bad)} commits backoff without accepting a page",
         ctx do
      stub()
      assert {:ok, :refreshed} = step(ctx.profile.org_id)
      assert_received {:read, _, true}
      before_video = Repo.one!(Publication)

      stub(fn conn, query ->
        rejected = body(query) |> Map.put("data", [])

        meta =
          if @bad == :absent,
            do: Map.delete(rejected["meta"], @field),
            else: Map.put(rejected["meta"], @field, @bad)

        Req.Test.json(conn, Map.put(rejected, "meta", meta))
      end)

      assert {:ok, :deferred} = step(ctx.profile.org_id, DateTime.add(@now, 61))
      assert_received {:read, _, true}
      state = Repo.get_by!(PublicationSyncState, account_id: ctx.account.id, kind: "refresh")
      assert state.last_error == "invalid_response"
      assert state.next_attempt_at == DateTime.add(@now, 361)
      assert state.cursor == nil
      assert state.completed_at == nil
      assert Repo.one!(Publication) == before_video
      assert {:ok, :idle} = step(ctx.profile.org_id, DateTime.add(@now, 122))
      refute_received {:read, _, _}
      stub()
      assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, 362))
      assert_received {:read, _, true}
    end
  end

  test "corrupt coverage is repaired without accepting its page, then restarts incomplete before completing",
       ctx do
    stub(fn conn, query ->
      Req.Test.json(conn, %{
        body(query)
        | "pagination" => %{"hasMore" => true, "nextCursor" => "old-next"}
      })
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id)
    assert_received {:read, first_query, true}
    before_video = Repo.one!(Publication)
    discovery = Repo.get_by!(PublicationSyncState, account_id: ctx.account.id, kind: "discovery")
    assert discovery.cursor == "old-next"
    assert discovery.seen_cursors == ["old-next"]
    assert is_binary(discovery.scan_id)
    assert discovery.completed_at == nil

    assert discovery.query_hash ==
             Publications.query_hash(
               %{
                 account_id: ctx.account.id,
                 profile_id: ctx.profile.id,
                 provider_account_ref: ctx.account.provider_account_ref,
                 provider_profile_ref: ctx.profile.provider_profile_ref
               },
               %{
                 kind: "discovery",
                 from_date: Date.from_iso8601!(first_query["fromDate"]),
                 to_date: Date.from_iso8601!(first_query["toDate"])
               }
             )

    Repo.update!(
      Ecto.Changeset.change(discovery,
        checked_ranges: [%{"from" => "bad", "to" => "2026-11-22"}],
        incomplete_ranges: [%{"from" => "2026-11-01", "to" => "bad"}],
        next_attempt_at: @now
      )
    )

    Repo.insert!(%PublicationSyncState{
      account_id: ctx.account.id,
      kind: "refresh",
      provider_account_ref: ctx.account.provider_account_ref,
      provider_profile_ref: ctx.profile.provider_profile_ref,
      next_attempt_at: DateTime.add(@now, 3600)
    })

    # Force discovery as the next class; no refresh is due before the repair.
    budget = Repo.get!(PublicationOrgBudget, ctx.profile.org_id)
    Repo.update!(Ecto.Changeset.change(budget, next_kind: "discovery"))
    stub(fn conn, query -> Req.Test.json(conn, %{body(query) | "data" => []}) end)
    assert {:ok, :deferred} = step(ctx.profile.org_id, DateTime.add(@now, 61))
    assert_received {:read, %{"cursor" => "old-next"}, true}
    repaired = Repo.get!(PublicationSyncState, discovery.id)
    assert repaired.last_error == "coverage_repaired"
    assert Map.get(repaired, :coverage_repaired_at) == DateTime.add(@now, 61)
    assert repaired.checked_ranges == []
    assert repaired.incomplete_ranges == []
    assert repaired.cursor == nil
    assert repaired.seen_cursors == []
    assert repaired.query_hash == nil
    assert repaired.scan_id == nil
    assert repaired.completed_at == nil
    assert repaired.checked_from == nil
    assert repaired.checked_to == nil
    assert repaired.next_attempt_at == DateTime.add(@now, 361)
    assert Repo.one!(Publication) == before_video
    assert {:ok, :idle} = step(ctx.profile.org_id, DateTime.add(@now, 122))
    refute_received {:read, _, _}
    # Keep other work outside this test's clock window.
    Repo.update_all(
      from(s in PublicationSyncState,
        where: s.account_id == ^ctx.account.id and s.kind == "refresh"
      ),
      set: [next_attempt_at: DateTime.add(@now, 3600)]
    )

    stub(fn conn, query ->
      Req.Test.json(conn, %{
        body(query)
        | "pagination" => %{"hasMore" => true, "nextCursor" => "fresh-next"}
      })
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id, DateTime.add(@now, 362))
    assert_received {:read, query, true}
    refute Map.has_key?(query, "cursor")
    pending = Repo.get!(PublicationSyncState, discovery.id)
    assert pending.checked_ranges == []
    assert Map.get(pending, :coverage_repaired_at) == DateTime.add(@now, 61)
    assert pending.incomplete_ranges != []
    assert pending.cursor == "fresh-next"
    refute pending.scan_id == discovery.scan_id
    stub()
    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(@now, 423))
    assert_received {:read, %{"cursor" => "fresh-next"}, true}
    complete = Repo.get!(PublicationSyncState, discovery.id)
    assert complete.checked_ranges != []
    assert complete.incomplete_ranges == []
    assert complete.last_error == nil
    assert Map.get(complete, :coverage_repaired_at) == nil
  end

  test "same-binding expiry preserves repair provenance until a safe completed scan", ctx do
    {discovery, repaired_at} = repair_then_partial(ctx)
    expires_at = DateTime.add(@now, 90_000)

    stub(fn conn, query ->
      Req.Test.json(conn, %{
        body(query)
        | "pagination" => %{"hasMore" => true, "nextCursor" => "after-expiry"}
      })
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id, expires_at)
    assert_received {:read, query, true}
    refute Map.has_key?(query, "cursor")
    restarted = Repo.get!(PublicationSyncState, discovery.id)
    assert restarted.coverage_repaired_at == repaired_at
    assert restarted.cursor == "after-expiry"
    refute restarted.scan_id == discovery.scan_id
    assert restarted.checked_ranges == []

    stub()
    assert {:ok, :refreshed} = step(ctx.profile.org_id, DateTime.add(expires_at, 61))
    assert_received {:read, %{"cursor" => "after-expiry"}, true}
    complete = Repo.get!(PublicationSyncState, discovery.id)
    assert complete.coverage_repaired_at == nil
    assert complete.checked_ranges != []
  end

  test "an actual provider-binding change clears prior connection repair provenance before a partial page",
       ctx do
    {discovery, _repaired_at} = repair_then_partial(ctx)
    Repo.update!(Ecto.Changeset.change(ctx.account, provider_account_ref: "rebound-account"))

    stub(fn conn, query ->
      Req.Test.json(conn, %{
        body(query)
        | "data" => [],
          "pagination" => %{"hasMore" => true, "nextCursor" => "rebound-next"}
      })
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id, DateTime.add(@now, 423))
    assert_received {:read, %{"accountId" => "rebound-account"} = query, true}
    refute Map.has_key?(query, "cursor")
    rebound = Repo.get!(PublicationSyncState, discovery.id)
    assert rebound.provider_account_ref == "rebound-account"
    assert rebound.coverage_repaired_at == nil
    assert rebound.cursor == "rebound-next"
    assert rebound.completed_at == nil
  end

  defp repair_then_partial(ctx) do
    stub()
    assert {:ok, :refreshed} = step(ctx.profile.org_id)
    assert_received {:read, _, true}
    discovery = Repo.get_by!(PublicationSyncState, account_id: ctx.account.id, kind: "discovery")

    Repo.update!(
      Ecto.Changeset.change(discovery,
        checked_ranges: [%{"from" => "bad", "to" => "2026-11-22"}],
        next_attempt_at: @now
      )
    )

    Repo.insert!(%PublicationSyncState{
      account_id: ctx.account.id,
      kind: "refresh",
      provider_account_ref: ctx.account.provider_account_ref,
      provider_profile_ref: ctx.profile.provider_profile_ref,
      next_attempt_at: DateTime.add(@now, 200_000)
    })

    budget = Repo.get!(PublicationOrgBudget, ctx.profile.org_id)
    Repo.update!(Ecto.Changeset.change(budget, next_kind: "discovery"))
    repaired_at = DateTime.add(@now, 61)
    assert {:ok, :deferred} = step(ctx.profile.org_id, repaired_at)
    assert_received {:read, _, true}
    assert Repo.get!(PublicationSyncState, discovery.id).coverage_repaired_at == repaired_at

    stub(fn conn, query ->
      Req.Test.json(conn, %{
        body(query)
        | "pagination" => %{"hasMore" => true, "nextCursor" => "repair-partial"}
      })
    end)

    assert {:ok, :incomplete} = step(ctx.profile.org_id, DateTime.add(@now, 362))
    assert_received {:read, query, true}
    refute Map.has_key?(query, "cursor")
    partial = Repo.get!(PublicationSyncState, discovery.id)
    assert partial.coverage_repaired_at == repaired_at
    assert partial.cursor == "repair-partial"
    {partial, repaired_at}
  end
end
