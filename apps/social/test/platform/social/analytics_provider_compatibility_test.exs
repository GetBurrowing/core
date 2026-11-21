defmodule Platform.Social.AnalyticsProviderCompatibilityTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  import Platform.SocialFixtures
  alias Platform.Social
  alias Platform.Social.{Account, AnalyticsSync, FollowerSnapshot, FollowerSync}
  alias Platform.Social.Analytics.SyncState
  alias Platform.Social.Publisher.{Fake, Zernio}
  @now ~U[2026-11-21 12:00:00.000000Z]

  setup do
    previous = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Zernio)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)

    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "provider-compat-fixture-key",
        scope: {:integration, nil},
        provider: "social"
      )

    org = org_id!()
    {:ok, profile} = Social.create_profile(org, %{name: "Provider compatibility"})
    profile = Repo.update!(Ecto.Changeset.change(profile, provider_profile_ref: "profile-A"))

    {:ok, account} =
      Social.create_account(org, profile, %{
        platform: "youtube",
        status: "connected",
        provider_account_ref: "account-A"
      })

    assert account.provider == nil
    assert account.platform_account_type == nil
    assert Repo.one(from(a in Account, where: a.id == ^account.id, select: is_nil(a.provider)))
    parent = self()

    Req.Test.stub(Zernio, fn conn ->
      q = URI.decode_query(conn.query_string)
      send(parent, {:provider_http, conn.request_path, q})

      platform = Repo.get!(Account, account.id).platform

      value =
        if String.ends_with?(conn.request_path, "/metrics/accounts") do
          %{
            "data" => [
              %{
                "date" => "2026-11-20",
                "accountId" => "account-A",
                "profileId" => "profile-A",
                "platform" => platform,
                "metrics" => %{"followers" => 42}
              }
            ],
            "pagination" => %{"nextCursor" => nil, "hasMore" => false},
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
          }
        else
          %{
            "data" => [
              %{
                "postId" => "analytics-A",
                "accountId" => "account-A",
                "profileId" => "profile-A",
                "platform" => platform,
                "platformPostId" => "platform-A",
                "syncedAt" => "2026-11-20T12:00:00Z",
                "isDeleted" => false,
                "metrics" => %{"views" => 84}
              }
            ],
            "nextCursor" => "C1",
            "hasMore" => false
          }
        end

      Req.Test.json(conn, value)
    end)

    %{org: org, profile: profile, account: account}
  end

  defp sweep(opts \\ []) do
    options =
      Keyword.merge(
        [
          name: :analytics_provider_compat_worker,
          start: true,
          boot_sweep: false,
          pace_ms: 0,
          max_requests: 1,
          now: @now,
          interval_ms: 3_600_000,
          notify: self()
        ],
        opts
      )

    pid = start_supervised!({AnalyticsSync, options})
    Req.Test.allow(Zernio, self(), pid)
    send(pid, :sweep)
    assert_receive {:analytics_swept, ^pid}, 2000
  end

  test "untagged normal connected rows use the authoritative configured Zernio adapter", c do
    assert {:ok, {:refreshed, 1}} = FollowerSync.sync_org(c.org, now: @now, pace_ms: 0)
    assert [%{account_id: id, followers: 42}] = Repo.all(FollowerSnapshot)
    assert id == c.account.id
    assert Repo.get!(Account, id).provider == nil
    assert_received {:provider_http, _, %{"accountId" => "account-A"}}
  end

  for platform <- ["youtube", "linkedin"] do
    @platform platform
    test "the scheduled sweep reaches untagged #{@platform} post accounts with correct follower scope",
         c do
      account = Repo.update!(Ecto.Changeset.change(c.account, platform: @platform))
      post = approved_post!(c.org, account)

      post =
        Repo.update!(
          Ecto.Changeset.change(post,
            status: "published",
            external_id: "publisher-A",
            platform_post_id: "platform-A",
            analytics_external_id: "analytics-A",
            published_at: ~U[2026-11-20 12:00:00.000000Z],
            metrics: %{"views" => 1}
          )
        )

      Repo.insert!(%SyncState{org_id: c.org, cursor: "C0", bootstrap_complete: true})
      sweep()
      assert Repo.get!(Social.Post, post.id).metrics["views"] == 84
      assert_received {:provider_http, "/api/v1/analytics/delta", %{"cursor" => "C0"}}

      if @platform == "linkedin" do
        assert Repo.all(FollowerSnapshot) == []
        refute_received {:provider_http, "/api/v1/metrics/accounts", _}
      else
        assert [%{followers: 42}] = Repo.all(FollowerSnapshot)
        assert_received {:provider_http, "/api/v1/metrics/accounts", _}
      end
    end
  end

  test "explicit Zernio tags retain their existing behavior with an unconfigured publisher", c do
    Repo.update!(Ecto.Changeset.change(c.account, provider: "zernio"))
    Application.put_env(:social, :publisher, nil)
    assert {:error, :publisher_not_configured} = Social.Publisher.impl()
    assert {:ok, {:refreshed, 1}} = FollowerSync.sync_org(c.org, now: @now, pace_ms: 0)
    assert_received {:provider_http, _, _}
  end

  test "an archived untagged account stays excluded", c do
    Repo.update!(Ecto.Changeset.change(c.account, archived_at: @now))
    assert {:ok, :idle} = FollowerSync.sync_org(c.org, now: @now, pace_ms: 0)
    sweep()
    refute_received {:provider_http, _, _}
  end

  for {label, module} <- [{"Fake", Fake}, {"unconfigured", nil}] do
    @adapter module
    test "reference strings do not identify an untagged account under #{label}", c do
      Application.put_env(:social, :publisher, @adapter)
      assert {:ok, :idle} = FollowerSync.sync_org(c.org, now: @now, pace_ms: 0)
      sweep()
      refute_received {:provider_http, _, _}
      assert Repo.aggregate(FollowerSnapshot, :count) == 0
    end
  end

  test "an explicit other provider is excluded even with Zernio configured", c do
    Repo.update!(Ecto.Changeset.change(c.account, provider: "another-provider"))
    assert {:ok, :idle} = FollowerSync.sync_org(c.org, now: @now, pace_ms: 0)
    sweep()
    refute_received {:provider_http, _, _}
  end

  for field <- [:provider_profile_ref, :provider_account_ref] do
    @field field
    test "missing #{@field} cannot trigger the shared org sweep", c do
      row = if @field == :provider_profile_ref, do: c.profile, else: c.account
      Repo.update!(Ecto.Changeset.change(row, [{@field, nil}]))
      assert {:ok, :idle} = FollowerSync.sync_org(c.org, now: @now, pace_ms: 0)
      sweep()
      refute_received {:provider_http, _, _}
    end
  end

  test "configured adapter authority is re-read after candidate discovery before the locked read",
       c do
    parent = self()
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _, _, %{query: query}, _ ->
          if Process.get(:provider_compat_barrier) &&
               String.contains?(query, "LEFT OUTER JOIN \"social_follower_sync_states\"") do
            Process.delete(:provider_compat_barrier)
            send(parent, {:provider_candidate, self(), ref})

            receive do
              {:continue_provider, ^ref} -> :ok
            after
              2000 -> raise "provider recheck barrier timeout"
            end
          end
        end,
        nil
      )

    task =
      Task.async(fn ->
        Process.put(:provider_compat_barrier, true)
        FollowerSync.sync_org(c.org, now: @now, pace_ms: 0)
      end)

    Req.Test.allow(Zernio, self(), task.pid)

    try do
      assert_receive {:provider_candidate, worker, ^ref}, 2000
      Application.put_env(:social, :publisher, Fake)
      send(worker, {:continue_provider, ref})
      assert {:ok, :idle} = Task.await(task, 3000)
      refute_received {:provider_http, _, _}
    after
      send(task.pid, {:continue_provider, ref})
      if Process.alive?(task.pid), do: Task.await(task, 3000)
      :telemetry.detach(handler)
    end
  end

  test "a mixed-provider org requests exactly its Zernio post and follower endpoints", c do
    account = Repo.update!(Ecto.Changeset.change(c.account, provider: "zernio"))

    {:ok, other} =
      Social.create_account(c.org, c.profile, %{
        platform: "youtube",
        provider: "another-provider",
        provider_account_ref: "account-B",
        status: "connected"
      })

    posts =
      for {row, suffix} <- [{account, "A"}, {other, "B"}], into: %{} do
        post = approved_post!(c.org, row)

        post =
          Repo.update!(
            Ecto.Changeset.change(post,
              status: "published",
              published_at: @now,
              external_id: "publisher-#{suffix}",
              platform_post_id: "platform-#{suffix}",
              analytics_external_id: nil,
              metrics: %{"views" => 1}
            )
          )

        {suffix, post}
      end

    Repo.insert!(%SyncState{org_id: c.org, cursor: "C0", bootstrap_complete: true})
    parent = self()

    Req.Test.stub(Zernio, fn conn ->
      q = URI.decode_query(conn.query_string)
      send(parent, {:mixed_provider_http, conn.request_path, q})

      response =
        cond do
          String.ends_with?(conn.request_path, "/delta") ->
            %{"data" => [], "nextCursor" => "C1", "hasMore" => false}

          String.ends_with?(conn.request_path, "/metrics/accounts") ->
            %{
              "data" => [],
              "pagination" => %{"nextCursor" => nil, "hasMore" => false},
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
            }

          true ->
            suffix = if q["postId"] == "publisher-A", do: "A", else: "B"

            %{
              "postId" => "analytics-#{suffix}",
              "latePostId" => q["postId"],
              "platformAnalytics" => [
                %{
                  "platform" => "youtube",
                  "platformPostId" => "platform-#{suffix}",
                  "accountId" => "account-#{suffix}",
                  "syncStatus" => "synced",
                  "analytics" => %{"views" => 84, "lastUpdated" => "2026-11-21T12:00:00Z"}
                }
              ]
            }
        end

      Req.Test.json(conn, response)
    end)

    sweep(max_requests: 4)

    requests =
      Stream.repeatedly(fn ->
        receive do
          {:mixed_provider_http, path, params} -> {path, params}
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert requests == [
             {"/api/v1/analytics", %{"postId" => "publisher-A"}},
             {"/api/v1/analytics/delta", %{"cursor" => "C0"}},
             {"/api/v1/metrics/accounts",
              %{
                "accountId" => "account-A",
                "metrics" => "followers",
                "groupBy" => "account",
                "granularity" => "day",
                "attribution" => "publish",
                "fromDate" => "2026-08-24",
                "toDate" => "2026-11-21",
                "limit" => "100"
              }}
           ]

    assert Repo.get!(Social.Post, posts["A"].id).metrics["views"] == 84
    assert Repo.get!(Social.Post, posts["B"].id).metrics == %{"views" => 1}
    assert Repo.get!(Social.Post, posts["B"].id).analytics_external_id == nil
  end
end
