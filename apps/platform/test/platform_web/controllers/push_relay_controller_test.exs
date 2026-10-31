defmodule PlatformWeb.PushRelayControllerTest do
  @moduledoc """
  Task 01a1261e stage 2: the push relay's endpoint,
  `POST /api/push-relay/v1/notifications`, relay side.

  Binding properties under test: relay mode off is a 404; a bad or revoked
  credential is a 401; each item is a strict allow-list (an unknown key is a
  422 naming the key, and its VALUE reaches neither the response nor the
  log); batches are capped and rate limited; the provider bodies are built by
  the relay (constant APNs alert, data-only FCM) byte for byte; and no
  response ever carries a relay credential or config value.
  """
  # async: false: swaps app env (relay mode, APNs/FCM config), raises the
  # global Logger level, and the provider token caches are VM-wide.
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Platform.FCMFixtures, only: [configure!: 1, generated_rsa_pem: 0, stub_fcm: 2]
  import Platform.PushRelayFixtures

  alias Platform.Push.RelayInstall
  alias Platform.Push.RelayServer
  alias Platform.Repo

  @path "/api/push-relay/v1/notifications"
  @host "suite-b.localhost"

  setup_all do
    %{pem: generated_rsa_pem()}
  end

  setup %{pem: pem} do
    isolate_push_env!()
    Application.put_env(:platform, :push_relay_server, enabled: true)
    Application.put_env(:platform, :apns, apns_config())
    configure!(pem)
    stub_apns(self())
    stub_fcm(self(), {200, %{"name" => "projects/p/messages/1"}})

    {:ok, install, credential} = RelayServer.create_install("B", @host)
    %{install: install, credential: credential}
  end

  defp ios_item(overrides \\ %{}) do
    Map.merge(
      %{
        "platform" => "ios",
        "token" => apns_token(),
        "environment" => "production",
        "install_host" => @host,
        "unread_count" => 3,
        "unread_as_of" => "2026-10-10T15:00:00Z",
        "sealed" => Base.url_encode64(:crypto.strong_rand_bytes(80), padding: false),
        "collapse_id" => String.duplicate("a", 64)
      },
      overrides
    )
  end

  defp android_item(overrides \\ %{}) do
    Map.merge(
      %{
        "platform" => "android",
        "token" => Platform.FCMFixtures.sentinel_token(),
        "install_host" => @host,
        "unread_count" => 0,
        "unread_as_of" => "2026-10-10T15:00:00Z",
        "sealed" => nil,
        "collapse_id" => String.duplicate("b", 64)
      },
      overrides
    )
  end

  defp relay(conn, credential, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> credential)
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(body))
  end

  describe "access" do
    test "relay mode off: 404 even with a valid credential", %{conn: conn, credential: cred} do
      Application.put_env(:platform, :push_relay_server, enabled: false)

      conn = relay(conn, cred, %{"notifications" => [ios_item()]})
      assert json_response(conn, 404) == %{"error" => "not_found"}
      refute_received {:apns, _}
    end

    test "no, malformed or unknown credential: 401", %{conn: conn} do
      body = Jason.encode!(%{"notifications" => [ios_item()]})

      no_bearer =
        conn |> put_req_header("content-type", "application/json") |> post(@path, body)

      assert json_response(no_bearer, 401) == %{"error" => "unauthorized"}

      assert relay(build_conn(), "made-up-credential", %{"notifications" => []})
             |> json_response(401) == %{"error" => "unauthorized"}

      basic =
        build_conn()
        |> put_req_header("authorization", "Basic abc")
        |> put_req_header("content-type", "application/json")
        |> post(@path, body)

      assert json_response(basic, 401) == %{"error" => "unauthorized"}
      refute_received {:apns, _}
    end

    test "a revoked install's credential: 401", %{conn: conn, install: install, credential: cred} do
      # Positive control first: the credential works.
      assert %{"results" => []} =
               relay(conn, cred, %{"notifications" => []}) |> json_response(200)

      {:ok, _} = RelayServer.revoke_install(install.id)

      assert relay(build_conn(), cred, %{"notifications" => []}) |> json_response(401) ==
               %{"error" => "unauthorized"}
    end

    test "only the credential's hash is stored", %{install: install, credential: cred} do
      row = Repo.get!(RelayInstall, install.id)
      assert row.credential_hash == :crypto.hash(:sha256, cred)
      refute inspect(Map.from_struct(row)) =~ cred
      refute inspect(row) =~ Base.encode16(row.credential_hash)
    end
  end

  describe "the strict allow-list" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "an unknown key is a 422 naming the key, and its value is in no response or log",
         %{conn: conn, credential: cred} do
      log =
        capture_log([level: :debug], fn ->
          conn = relay(conn, cred, %{"notifications" => [ios_item(%{"body" => "ZEBRA-9999"})]})
          body = response(conn, 422)

          assert Jason.decode!(body) == %{"error" => "unknown_field", "field" => "body"}
          refute body =~ "ZEBRA-9999"
        end)

      # Positive control for the capture: the request itself was logged at
      # debug (Plug's request line), so an empty capture cannot pass this.
      assert log =~ "POST"
      refute log =~ "ZEBRA-9999"
      refute_received {:apns, _}
    end

    test "an unknown TOP-LEVEL key is refused the same way", %{conn: conn, credential: cred} do
      conn = relay(conn, cred, %{"notifications" => [], "title" => "ZEBRA-1"})
      assert json_response(conn, 422) == %{"error" => "unknown_field", "field" => "title"}
    end

    test "a sealed blob is filtered from Phoenix parameter logging" do
      filtered =
        Phoenix.Logger.filter_values(%{"sealed" => "BLOB", "token" => "TOK", "kind" => "k"})

      assert filtered == %{"sealed" => "[FILTERED]", "token" => "[FILTERED]", "kind" => "k"}
    end

    test "a successful batch logs counts only: no token, blob, host or body",
         %{conn: conn, credential: cred, install: install} do
      item = ios_item()

      log =
        capture_log([level: :debug], fn ->
          assert relay(conn, cred, %{"notifications" => [item]}) |> json_response(200)
        end)

      assert log =~ "[PushRelay] install #{install.id} batch=1"
      refute log =~ item["token"]
      refute log =~ item["sealed"]
      refute log =~ item["collapse_id"]
    end

    test "every allowed field is validated; a bad one is a 422 naming field and index",
         %{conn: conn, credential: cred} do
      cases = [
        {"platform", %{"platform" => "windows"}},
        {"token", %{"token" => "not hex"}},
        {"environment", %{"environment" => "staging"}},
        {"install_host", %{"install_host" => "has space"}},
        {"unread_count", %{"unread_count" => -1}},
        {"unread_as_of", %{"unread_as_of" => "yesterday"}},
        {"sealed", %{"sealed" => String.duplicate("A", 3_073)}},
        {"sealed", %{"sealed" => "not+base64url/"}},
        {"collapse_id", %{"collapse_id" => String.duplicate("c", 65)}}
      ]

      for {field, bad} <- cases do
        body = %{"notifications" => [ios_item(), ios_item(bad)]}

        assert relay(build_conn(), cred, body) |> json_response(422) ==
                 %{"error" => "invalid_field", "field" => field, "index" => 1},
               "expected #{field} to be refused"
      end

      _ = conn
      refute_received {:apns, _}
    end

    test "101 items is a 422; 100 is accepted", %{conn: conn, credential: cred} do
      assert relay(conn, cred, %{"notifications" => List.duplicate(android_item(), 101)})
             |> json_response(422) == %{"error" => "too_many", "max" => 100}

      %{"results" => results} =
        relay(build_conn(), cred, %{"notifications" => List.duplicate(android_item(), 100)})
        |> json_response(200)

      assert length(results) == 100
    end
  end

  describe "rate limit" do
    test "a batch larger than the per-minute budget is always a 429",
         %{conn: conn, credential: cred} do
      Application.put_env(:platform, :push_relay_server, enabled: true, rate_per_minute: 3)

      # Four items exceed the entire budget even if the minute rolls over.
      assert relay(conn, cred, %{"notifications" => List.duplicate(android_item(), 4)})
             |> json_response(429) == %{"error" => "rate_limited"}

      refute_received {:fcm_send, _}
      refute_received {:apns, _}

      # Discriminating refusal-refund and cumulative-budget proof live in
      # relay_rate_limit_test.exs using check/4. This 200 alone cannot prove
      # refund across a minute rollover.
      assert relay(build_conn(), cred, %{"notifications" => List.duplicate(android_item(), 3)})
             |> json_response(200) == %{
               "results" => [
                 %{"status" => "sent"},
                 %{"status" => "sent"},
                 %{"status" => "sent"}
               ]
             }

      assert_received {:fcm_send, _}
      assert_received {:fcm_send, _}
      assert_received {:fcm_send, _}
      refute_received {:fcm_send, _}
      refute_received {:apns, _}
    end

    test "the budget is per install", %{conn: conn, credential: cred} do
      Application.put_env(:platform, :push_relay_server, enabled: true, rate_per_minute: 1)
      {:ok, _other, other_cred} = RelayServer.create_install("A", "suite-a.localhost")

      assert relay(conn, cred, %{"notifications" => [android_item()]}) |> json_response(200)

      assert relay(build_conn(), other_cred, %{"notifications" => [android_item()]})
             |> json_response(200)
    end
  end

  describe "provider bodies are built by the relay" do
    test "APNs: constant alert plus the four routing keys, the relay's topic, byte for byte",
         %{conn: conn, credential: cred} do
      item = ios_item()

      assert relay(conn, cred, %{"notifications" => [item]}) |> json_response(200) ==
               %{"results" => [%{"status" => "sent"}]}

      assert_received {:apns, req}
      assert req.token == item["token"]

      assert req.body == %{
               "aps" => %{
                 "alert" => %{"title" => "Burrow", "body" => "New notification"},
                 "mutable-content" => 1,
                 "sound" => "default"
               },
               "install_host" => @host,
               "unread_count" => 3,
               "unread_as_of" => "2026-10-10T15:00:00Z",
               "sealed" => item["sealed"]
             }

      refute Map.has_key?(req.body["aps"], "badge"), "the NSE sets the summed badge"
      assert req.headers["apns-topic"] == "com.kobo-ai.burrow"
      assert req.headers["apns-push-type"] == "alert"
      assert req.headers["apns-collapse-id"] == item["collapse_id"]
    end

    test "APNs: a null sealed is omitted, never sent as null", %{conn: conn, credential: cred} do
      relay(conn, cred, %{"notifications" => [ios_item(%{"sealed" => nil})]})
      |> json_response(200)

      assert_received {:apns, req}
      refute Map.has_key?(req.body, "sealed")
      refute req.raw =~ "null"
    end

    test "FCM: data-only with string values, high priority, collapse_key",
         %{conn: conn, credential: cred} do
      item = android_item(%{"sealed" => "c2VhbGVk"})

      assert relay(conn, cred, %{"notifications" => [item]}) |> json_response(200) ==
               %{"results" => [%{"status" => "sent"}]}

      assert_received {:fcm_send, req}

      assert req.body["message"] == %{
               "token" => item["token"],
               "data" => %{
                 "install_host" => @host,
                 "unread_count" => "0",
                 "unread_as_of" => "2026-10-10T15:00:00Z",
                 "sealed" => "c2VhbGVk"
               },
               "android" => %{"priority" => "high", "collapse_key" => item["collapse_id"]}
             }
    end

    test "results come back in request order, 410 -> unregistered, and the relay DB is unchanged",
         %{conn: conn, credential: cred} do
      dead = apns_token_2()
      stub_apns(self(), fn token -> if token == dead, do: 410, else: 200 end)
      before = Repo.all(RelayInstall) |> Enum.map(&Map.drop(Map.from_struct(&1), [:last_used_at]))

      body = %{
        "notifications" => [ios_item(), ios_item(%{"token" => dead}), android_item()]
      }

      {results, log} =
        with_log(fn -> relay(conn, cred, body) |> json_response(200) |> Map.fetch!("results") end)

      assert results == [
               %{"status" => "sent"},
               %{"status" => "unregistered"},
               %{"status" => "sent"}
             ]

      after_rows =
        Repo.all(RelayInstall) |> Enum.map(&Map.drop(Map.from_struct(&1), [:last_used_at]))

      assert after_rows == before
      refute log =~ dead
    end

    test "a platform the relay has no credentials for fails that item only",
         %{conn: conn, credential: cred} do
      Application.delete_env(:platform, :apns)

      assert relay(conn, cred, %{"notifications" => [ios_item(), android_item()]})
             |> json_response(200) == %{
               "results" => [%{"status" => "failed"}, %{"status" => "sent"}]
             }
    end
  end

  describe "credentials never leave the relay" do
    test "no response, success or refusal, carries any relay config value",
         %{conn: conn, credential: cred, pem: pem} do
      sentinels = %{
        key_id: "SENTINELKEYID",
        team_id: "SENTINELTEAM",
        topic: "com.sentinel.relaytopic"
      }

      Application.put_env(:platform, :apns, apns_config(Map.to_list(sentinels)))
      configure!(pem)

      responses = [
        relay(conn, cred, %{"notifications" => [ios_item(), android_item()]}) |> response(200),
        relay(build_conn(), cred, %{"notifications" => [ios_item(%{"x" => 1})]})
        |> response(422),
        relay(build_conn(), "bad", %{"notifications" => []}) |> response(401)
      ]

      Application.put_env(:platform, :push_relay_server, enabled: false)

      responses = [
        relay(build_conn(), cred, %{"notifications" => []}) |> response(404) | responses
      ]

      # Positive control: the sentinel topic really was in use.
      assert_received {:apns, req}
      assert req.headers["apns-topic"] == sentinels.topic

      needles =
        Map.values(sentinels) ++
          [Platform.FCMFixtures.client_email(), Platform.FCMFixtures.project_id(), "PRIVATE KEY"]

      for body <- responses, do: refute_contains(body, needles, "relay response")
    end
  end
end
