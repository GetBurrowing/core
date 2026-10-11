defmodule Platform.Push.RelayTest do
  @moduledoc """
  Task 01a1261e stage 2: the push relay, install side, and transport
  selection in `Platform.Push`.

  The sentinel test is the binding one: a distinctive author, space and
  message sent through `Push.send_to_user/2` on a relay-mode install appears
  NOWHERE in the request the relay receives, the provider bodies the relay
  sends, the log, or the relay's table, while the device's private key opens
  the sealed blob to exactly that text (positive control: the sentinel was
  really sent).
  """
  # async: false: swaps app env and env vars; provider token caches are
  # VM-wide `:persistent_term`s.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.FCMFixtures, only: [configure!: 1, generated_rsa_pem: 0, stub_fcm: 2]
  import Platform.PushRelayFixtures

  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.FcmDevice
  alias Platform.Push
  alias Platform.Push.Notification
  alias Platform.Push.Relay
  alias Platform.Push.RelayInstall
  alias Platform.Push.RelayServer
  alias Platform.Push.Seal
  alias Platform.Repo

  @relay_url "https://relay.example.test"
  @credential "install-credential-SENTINEL-0001"
  @host "suite-b.localhost"

  setup_all do
    %{pem: generated_rsa_pem()}
  end

  setup do
    isolate_push_env!()
    :ok
  end

  defp relay_mode! do
    Application.put_env(:platform, :push_relay, url: @relay_url, credential: @credential)
  end

  defp insert_user(name \\ "Marlowe") do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: name,
      email: "relay-#{n}@example.com",
      oidc_sub: "sub-relay-#{n}"
    })
  end

  defp notification(attrs \\ %{}) do
    Notification.new(
      Map.merge(
        %{
          kind: "chat_mention",
          title: "Dana in launch",
          body: "@Marlowe can you check the deck before 3?",
          url: "/chat/launch?message=m1",
          space_id: "01a1261e-0000-7000-8000-00000000000a",
          message_id: "01a1261e-0000-7000-8000-00000000000b",
          author_name: "Dana",
          space_name: "launch",
          install_host: @host,
          collapse_id: "01a1261e-0000-7000-8000-00000000000b"
        },
        attrs
      )
    )
  end

  defp ok_relay(test_pid) do
    stub_relay(test_pid, fn _raw, %{"notifications" => items} ->
      {200, %{"results" => Enum.map(items, fn _ -> %{"status" => "sent"} end)}}
    end)
  end

  describe "relay_config/0 (all-or-nothing)" do
    test "nil with nothing configured" do
      assert Relay.relay_config() == nil
      refute Relay.configured?()
    end

    test "app env, then env vars win" do
      relay_mode!()
      assert Relay.relay_config() == [url: @relay_url, credential: @credential]

      System.put_env("PUSH_RELAY_URL", "https://env.example.test")
      assert Relay.relay_config()[:url] == "https://env.example.test"
    end

    test "a half configuration is nil and logs the missing key, never a value" do
      Application.put_env(:platform, :push_relay, credential: @credential)

      log = capture_log(fn -> assert Relay.relay_config() == nil end)
      assert log =~ "missing url"
      refute log =~ @credential
    end
  end

  describe "items sent to the relay" do
    test "a keyed device gets a sealed blob that opens to the FCM data map; a keyless one gets null" do
      relay_mode!()
      user = insert_user()
      {pub, priv} = device_keypair()
      insert_apns_device!(user, push_public_key: pub)
      insert_apns_device!(user, token: apns_token_2(), environment: "sandbox")
      ok_relay(self())

      n = %Notification{notification() | unread_count: 3, unread_as_of: ~U[2026-10-10 15:00:00Z]}
      assert :ok = Relay.deliver_to_user(user.id, n, :ios)

      assert_received {:relay_request, req}
      assert req.path == "/api/push-relay/v1/notifications"
      assert req.headers["authorization"] == "Bearer " <> @credential

      [keyed, keyless] = Enum.sort_by(req.body["notifications"], &is_nil(&1["sealed"]))

      for item <- [keyed, keyless] do
        assert Map.keys(item) -- RelayServer.allowed_fields() == []
        assert item["platform"] == "ios"
        assert item["install_host"] == @host
        assert item["unread_count"] == 3
        assert item["unread_as_of"] == "2026-10-10T15:00:00Z"
        assert item["collapse_id"] == Relay.collapse_id(@host, n.collapse_id)
        assert item["collapse_id"] =~ ~r/\A[0-9a-f]{64}\z/
      end

      assert keyed["token"] == apns_token()
      assert keyed["environment"] == "production"
      assert keyless["environment"] == "sandbox"
      assert keyless["sealed"] == nil

      assert {:ok, json} = Seal.open(priv, keyed["sealed"], @host)
      assert Jason.decode!(json) == Notification.to_fcm_payload(n)["data"]

      refute req.raw =~ "Dana"
      refute req.raw =~ "check the deck"
      refute req.raw =~ n.collapse_id
    end

    test "the collapse id is a host-bound SHA-256, never the raw id" do
      assert Relay.collapse_id("a.example", "x") ==
               :crypto.hash(:sha256, "a.example|x") |> Base.encode16(case: :lower)

      refute Relay.collapse_id("a.example", "x") == Relay.collapse_id("b.example", "x")
      assert Relay.collapse_id("a.example", nil) == nil
    end

    test "android items carry no environment" do
      relay_mode!()
      user = insert_user()
      insert_fcm_device!(user)
      ok_relay(self())

      Relay.deliver_to_user(user.id, notification(), :android)

      assert_received {:relay_request, %{body: %{"notifications" => [item]}}}
      assert item["platform"] == "android"
      refute Map.has_key?(item, "environment")
    end

    test "more than 100 devices go in batches of at most 100" do
      relay_mode!()
      user = insert_user()

      for i <- 1..101 do
        insert_apns_device!(user, token: String.pad_leading(Integer.to_string(i, 16), 64, "0"))
      end

      ok_relay(self())
      Relay.deliver_to_user(user.id, notification(), :ios)

      assert_received {:relay_request, %{body: %{"notifications" => first}}}
      assert_received {:relay_request, %{body: %{"notifications" => second}}}
      assert length(first) == 100
      assert length(second) == 1
    end

    test "a device the relay reports unregistered is deleted; the others stay" do
      relay_mode!()
      user = insert_user()
      live = insert_apns_device!(user)
      dead = insert_apns_device!(user, token: apns_token_2())
      dead_token = dead.token

      stub_relay(self(), fn _raw, %{"notifications" => items} ->
        {200,
         %{
           "results" =>
             Enum.map(items, fn
               %{"token" => ^dead_token} -> %{"status" => "unregistered"}
               _ -> %{"status" => "sent"}
             end)
         }}
      end)

      capture_log(fn -> Relay.deliver_to_user(user.id, notification(), :ios) end)

      assert Repo.get(ApnsDevice, live.id)
      refute Repo.get(ApnsDevice, dead.id)
    end

    test "a relay error or a 500 deletes nothing and logs no secret" do
      relay_mode!()
      user = insert_user()
      device = insert_apns_device!(user)
      stub_relay(self(), fn _raw, _ -> {500, %{"error" => "boom"}} end)

      log =
        capture_log(fn -> assert :ok = Relay.deliver_to_user(user.id, notification(), :ios) end)

      assert Repo.get(ApnsDevice, device.id)
      assert log =~ "relay answered 500"
      refute_contains(log, [@credential, @relay_url, apns_token()], "install log")
    end
  end

  describe "transport selection in Platform.Push" do
    test "direct APNs/FCM configured: direct is used and the relay is never called", %{pem: pem} do
      relay_mode!()
      Application.put_env(:platform, :apns, apns_config())
      configure!(pem)
      user = insert_user()
      insert_apns_device!(user)
      insert_fcm_device!(user)
      stub_apns(self())
      stub_fcm(self(), {200, %{"name" => "projects/p/messages/1"}})
      ok_relay(self())

      capture_log(fn -> assert :ok = Push.send_to_user(user.id, notification()) end)

      assert_received {:apns, %{body: %{"aps" => %{"alert" => %{"title" => "Dana in launch"}}}}}
      assert_received {:fcm_send, _}
      refute_received {:relay_request, _}
    end

    test "per platform: direct APNs and relayed FCM in the same push", %{pem: _pem} do
      relay_mode!()
      Application.put_env(:platform, :apns, apns_config())
      user = insert_user()
      insert_apns_device!(user)
      insert_fcm_device!(user)
      stub_apns(self())
      ok_relay(self())

      capture_log(fn -> Push.send_to_user(user.id, notification()) end)

      assert_received {:apns, _}

      assert_received {:relay_request,
                       %{body: %{"notifications" => [%{"platform" => "android"}]}}}
    end

    test "neither configured: today's not-configured log, no relay call" do
      user = insert_user()
      insert_apns_device!(user)
      insert_fcm_device!(user)
      ok_relay(self())

      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :info], fn ->
          assert :ok = Push.send_to_user(user.id, notification())
        end)

      assert log =~ "[APNs] not configured"
      assert log =~ "[FCM]"
      refute_received {:relay_request, _}
    end

    test "a relay that raises never takes the push down" do
      relay_mode!()
      user = insert_user()
      insert_apns_device!(user)
      stub_relay(self(), fn _raw, _ -> raise "relay exploded" end)

      capture_log(fn -> assert :ok = Push.send_to_user(user.id, notification()) end)
    end
  end

  describe "no plaintext crosses the relay (sentinel)" do
    test "the sentinel reaches the device only inside the sealed blob", %{pem: pem} do
      relay_mode!()
      {:ok, install, relay_credential} = RelayServer.create_install("B", @host)

      user = insert_user("Marlowe")
      {apns_pub, apns_priv} = device_keypair()
      {fcm_pub, fcm_priv} = device_keypair()
      insert_apns_device!(user, push_public_key: apns_pub)
      insert_fcm_device!(user, push_public_key: fcm_pub)

      stub_apns(self())
      stub_fcm(self(), {200, %{"name" => "projects/p/messages/1"}})

      relay_env = [apns: apns_config(), fcm: [service_account: service_account(pem)]]
      stub_relay(self(), forward_to_relay(self(), relay_credential, relay_env))

      sentinels = ["ZEBRA-7731", "Sentinelson", "launch-sentinel"]

      n =
        notification(%{
          title: "Dana Sentinelson in launch-sentinel",
          body: "@Marlowe ZEBRA-7731 quarterly numbers",
          author_name: "Dana Sentinelson",
          space_name: "launch-sentinel",
          url: "/chat/launch-sentinel?message=m1"
        })

      previous = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug], fn -> assert :ok = Push.send_to_user(user.id, n) end)
        after
          Logger.configure(level: previous)
        end

      # What the relay received, what it sent to APNs and FCM, its responses.
      assert_received {:relay_request, ios_req}
      assert_received {:relay_request, android_req}
      assert_received {:relay_response, 200, ios_resp}
      assert_received {:relay_response, 200, android_resp}
      assert_received {:apns, apns}
      assert_received {:fcm_send, fcm}

      refute_contains(ios_req.raw, sentinels, "install->relay request (ios)")
      refute_contains(android_req.raw, sentinels, "install->relay request (android)")
      refute_contains(apns.raw, sentinels, "relay->APNs body")
      refute_contains(Jason.encode!(fcm.body), sentinels, "relay->FCM body")
      refute_contains(ios_resp <> android_resp, sentinels, "relay responses")
      refute_contains(log, sentinels, "log")

      relay_rows = Repo.all(RelayInstall) |> inspect(limit: :infinity, printable_limit: :infinity)
      refute_contains(relay_rows, sentinels, "push_relay_installs")
      assert [%RelayInstall{id: id}] = Repo.all(RelayInstall)
      assert id == install.id

      # Positive control: the devices open exactly what was sent.
      assert {:ok, ios_json} = Seal.open(apns_priv, apns.body["sealed"], @host)
      assert ios_json =~ "ZEBRA-7731"
      assert Jason.decode!(ios_json)["author_name"] == "Dana Sentinelson"

      assert {:ok, android_json} =
               Seal.open(fcm_priv, fcm.body["message"]["data"]["sealed"], @host)

      assert android_json =~ "Sentinelson"

      # And the relay carried the per-install routing data.
      assert apns.body["install_host"] == @host
      assert is_integer(apns.body["unread_count"])
    end

    test "a 410 from APNs at the relay deletes the install's row; the relay DB is unchanged",
         %{pem: _pem} do
      relay_mode!()
      {:ok, _install, relay_credential} = RelayServer.create_install("B", @host)
      before = Repo.all(RelayInstall) |> Enum.map(&Map.drop(Map.from_struct(&1), [:last_used_at]))

      user = insert_user()
      device = insert_apns_device!(user)
      stub_apns(self(), 410)
      stub_relay(self(), forward_to_relay(self(), relay_credential, apns: apns_config()))

      capture_log(fn -> Push.send_to_user(user.id, notification()) end)

      assert_received {:relay_response, 200, body}
      assert Jason.decode!(body) == %{"results" => [%{"status" => "unregistered"}]}
      refute Repo.get(ApnsDevice, device.id)

      after_rows =
        Repo.all(RelayInstall) |> Enum.map(&Map.drop(Map.from_struct(&1), [:last_used_at]))

      assert after_rows == before
      assert Repo.all(FcmDevice) == []
    end
  end

  defp service_account(pem), do: Platform.FCMFixtures.service_account_json(pem)
end
