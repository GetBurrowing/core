defmodule Platform.Push.APNsTest do
  @moduledoc """
  Task 01a10882 stage 2: the APNs transport.

  Every request goes to the `Req.Test` stub named `Platform.Push.APNs`
  (`config/test.exs`), so nothing reaches Apple. All key material is generated
  per run; the device token is an invented sentinel. Every path runs under
  `capture_log/2` and asserts the log holds neither the token, nor PEM key
  text, nor the provider JWT.
  """
  # async: false — swaps `:platform, :apns` app env and APNS_* env vars, and
  # the provider-JWT cache is a VM-wide `:persistent_term`.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.AppSession
  alias Platform.Push
  alias Platform.Push.APNs
  alias Platform.Push.Notification
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  # Invented, not a device token: 64 hex chars that no Apple device holds.
  @sentinel_token String.duplicate("5e771e0d", 8)
  @sandbox_token String.duplicate("0badc0de", 8)

  @env_vars ~w(APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC APNS_AUTH_KEY)
  setup do
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Application.get_env(:platform, :apns)

    Enum.each(@env_vars, &System.delete_env/1)
    :persistent_term.erase({APNs, :provider_jwt})

    on_exit(fn ->
      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      if saved_app,
        do: Application.put_env(:platform, :apns, saved_app),
        else: Application.delete_env(:platform, :apns)

      :persistent_term.erase({APNs, :provider_jwt})
    end)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  # A fresh P-256 key in the PKCS#8 PEM shape of an Apple `.p8` file,
  # generated for this run only.
  defp generated_p8 do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, ec_key)])
  end

  defp full_config(pem \\ generated_p8()) do
    [
      key_id: "TESTKEY001",
      team_id: "TESTTEAM01",
      topic: "com.kobo-ai.burrow",
      auth_key: pem
    ]
  end

  defp configure!(config \\ full_config()) do
    Application.put_env(:platform, :apns, config)
    config
  end

  defp insert_user(name \\ "Apns User") do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: name,
      email: "apns-#{n}@example.com",
      oidc_sub: "sub-apns-#{n}"
    })
  end

  defp insert_device(user, token \\ @sentinel_token, environment \\ "production") do
    session =
      Repo.insert!(%AppSession{
        user_id: user.id,
        token_hash: :crypto.strong_rand_bytes(32),
        app_install_id: "install-#{System.unique_integer([:positive])}"
      })

    Repo.insert!(%ApnsDevice{
      user_id: user.id,
      app_session_id: session.id,
      app_install_id: session.app_install_id,
      token: token,
      environment: environment,
      bundle_id: "com.kobo-ai.burrow",
      last_registered_at: DateTime.utc_now()
    })
  end

  defp notification do
    Notification.new(%{
      kind: "task_plan_review",
      title: "Plan ready to approve",
      body: "Suite iOS app v1",
      url: "/tasks/t1",
      task_id: Ecto.UUID.generate(),
      inbox_item_id: "01a10890-0000-7000-8000-000000000001",
      collapse_id: "01a10890-0000-7000-8000-000000000001"
    })
  end

  # Stub answering `status` with `body`, recording every request.
  defp stub(status, body \\ %{}) do
    test_pid = self()

    Req.Test.stub(APNs, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {
        :apns_request,
        %{
          host: conn.host,
          path: conn.request_path,
          headers: Map.new(conn.req_headers),
          body: Jason.decode!(raw)
        }
      })

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp jwt_from(%{headers: %{"authorization" => "bearer " <> jwt}}), do: jwt

  defp refute_secrets(log, extra \\ []) do
    for secret <- [@sentinel_token, @sandbox_token, "PRIVATE KEY" | extra] do
      refute log =~ secret, "log leaked a secret: #{String.slice(secret, 0, 6)}..."
    end
  end

  defp device_exists?(device), do: Repo.get(ApnsDevice, device.id) != nil

  # ── Responses ──────────────────────────────────────────────────────────────

  describe "deliver_to_user/2 responses" do
    test "200 delivers with the right headers and payload, and keeps the row" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub(200)
      n = notification()

      log = capture_log(fn -> assert :ok = APNs.deliver_to_user(user.id, n) end)

      assert_received {:apns_request, req}
      assert req.host == "api.push.apple.com"
      assert req.path == "/3/device/" <> @sentinel_token
      assert req.headers["apns-topic"] == "com.kobo-ai.burrow"
      assert req.headers["apns-push-type"] == "alert"
      assert req.headers["apns-priority"] == "10"
      assert req.headers["apns-collapse-id"] == n.inbox_item_id
      assert req.body == Notification.to_apns_payload(n)
      assert req.body["aps"]["alert"] == %{"title" => n.title, "body" => n.body}
      assert req.body["aps"]["category"] == "SUITE_OPEN"
      assert req.body["aps"]["thread-id"] == "approvals"

      # A well-formed ES256 provider token, signed for this team and key.
      jwt = jwt_from(req)
      [header, claims, _sig] = String.split(jwt, ".")
      assert %{"alg" => "ES256", "kid" => "TESTKEY001"} = decode_segment(header)
      assert %{"iss" => "TESTTEAM01", "iat" => iat} = decode_segment(claims)
      assert is_integer(iat)

      assert device_exists?(device)
      refute_secrets(log, [jwt])
    end

    test "a sandbox device is sent to the sandbox host" do
      configure!()
      user = insert_user()
      insert_device(user, @sandbox_token, "sandbox")
      stub(200)

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert_received {:apns_request, %{host: "api.sandbox.push.apple.com"} = req}
      refute_secrets(log, [jwt_from(req)])
    end

    test "the provider token is cached across sends" do
      configure!()
      user = insert_user()
      insert_device(user)
      stub(200)

      log =
        capture_log(fn ->
          APNs.deliver_to_user(user.id, notification())
          APNs.deliver_to_user(user.id, notification())
        end)

      assert_received {:apns_request, first}
      assert_received {:apns_request, second}
      assert jwt_from(first) == jwt_from(second)
      refute_secrets(log, [jwt_from(first)])
    end

    test "410 deletes the device row" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub(410, %{"reason" => "Unregistered"})

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert_received {:apns_request, req}
      refute device_exists?(device), "a 410 must prune the device row"
      refute_secrets(log, [jwt_from(req)])
    end

    test "400 BadDeviceToken deletes the device row" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub(400, %{"reason" => "BadDeviceToken"})

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert_received {:apns_request, req}
      refute device_exists?(device)
      refute_secrets(log, [jwt_from(req)])
    end

    test "400 DeviceTokenNotForTopic deletes the device row" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub(400, %{"reason" => "DeviceTokenNotForTopic"})

      capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      refute device_exists?(device)
    end

    test "400 with any other reason keeps the row" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub(400, %{"reason" => "PayloadTooLarge"})

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert device_exists?(device)
      assert log =~ "PayloadTooLarge"
    end

    test "500 keeps the row and logs the row id and reason only" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub(500, %{"reason" => "InternalServerError"})

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert_received {:apns_request, req}
      assert device_exists?(device)
      assert log =~ device.id
      assert log =~ "InternalServerError"
      refute_secrets(log, [jwt_from(req)])
    end

    test "a transport error keeps the row and logs no request detail" do
      configure!()
      user = insert_user()
      device = insert_device(user)

      Req.Test.stub(APNs, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert device_exists?(device)
      assert log =~ device.id
      refute_secrets(log)
    end

    test "a transport error is retried once, and the retry delivers" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      test_pid = self()
      calls = :counters.new(1, [])

      Req.Test.stub(APNs, fn conn ->
        :counters.add(calls, 1, 1)
        send(test_pid, :apns_attempt)

        if :counters.get(calls, 1) == 1 do
          Req.Test.transport_error(conn, :closed)
        else
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
        end
      end)

      log = capture_log(fn -> assert :ok = APNs.deliver_to_user(user.id, notification()) end)

      assert_received :apns_attempt
      assert_received :apns_attempt
      refute_received :apns_attempt
      refute log =~ "transport_error", "the retry delivered, so nothing failed"
      assert device_exists?(device)
      refute_secrets(log)
    end

    test "a transport error is retried at most the backoff budget, then logs its kind" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      test_pid = self()

      Req.Test.stub(APNs, fn conn ->
        send(test_pid, :apns_attempt)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      # 1 attempt + 3 retries (config/test.exs: three zero-delay backoffs).
      for _ <- 1..4, do: assert_received(:apns_attempt)
      refute_received :apns_attempt
      assert log =~ "transport_error"
      assert log =~ "econnrefused", "the error KIND must be logged"
      assert log =~ device.id
      refute_secrets(log)
    end

    # The production failure of 2026-10-05: the HTTP/2 pool had no live
    # connection (first push after boot, or after an idle drop), Req answered
    # `%Req.HTTPError{protocol: :http2, reason: :pool_not_available}` at once,
    # the single immediate retry failed the same way, and the push was lost.
    # `Req.Test.transport_error/2` only builds `Req.TransportError`s, so the
    # stub puts the exact `Req.HTTPError` where `Req.Test` puts its own.
    defp pool_not_available(conn) do
      Plug.Conn.put_private(
        conn,
        :req_test_exception,
        %Req.HTTPError{protocol: :http2, reason: :pool_not_available}
      )
    end

    # A stub whose first `failures` calls find a cold pool, then 200.
    defp stub_cold_pool(failures) do
      test_pid = self()
      calls = :counters.new(1, [])

      Req.Test.stub(APNs, fn conn ->
        :counters.add(calls, 1, 1)
        send(test_pid, :apns_attempt)

        if :counters.get(calls, 1) <= failures do
          pool_not_available(conn)
        else
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
        end
      end)
    end

    test "a cold pool (pool_not_available x3) is retried with backoff and the push is delivered" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub_cold_pool(3)

      log = capture_log(fn -> assert :ok = APNs.deliver_to_user(user.id, notification()) end)

      for _ <- 1..4, do: assert_received(:apns_attempt)
      refute_received :apns_attempt
      refute log =~ "failed", "the 4th attempt delivered, so nothing failed"
      assert device_exists?(device)
      refute_secrets(log)
    end

    test "a cold pool that outlasts the retry budget drops the push and logs pool_not_available" do
      configure!()
      user = insert_user()
      device = insert_device(user)
      stub_cold_pool(4)

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      for _ <- 1..4, do: assert_received(:apns_attempt)
      refute_received :apns_attempt, "the retry budget is bounded"
      assert log =~ "[APNs] request for device #{device.id} failed: transport_error"
      assert log =~ "pool_not_available"
      refute log =~ "Req.HTTPError", "the error struct is never inspected"
      assert device_exists?(device)
      refute_secrets(log)
    end

    test "the backoff schedule is the retry budget" do
      configure!()
      user = insert_user()
      insert_device(user)
      stub_cold_pool(1)
      Application.put_env(:platform, :apns_retry_backoff_ms, [])
      on_exit(fn -> Application.put_env(:platform, :apns_retry_backoff_ms, [0, 0, 0]) end)

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert_received :apns_attempt
      refute_received :apns_attempt, "an empty schedule means no retry"
      assert log =~ "pool_not_available"
    end

    test "the default backoff is ~150/500/1500 ms" do
      assert APNs.default_retry_backoff_ms() == [150, 500, 1500]
    end

    test "an HTTP error from APNs is never retried" do
      configure!()
      user = insert_user()
      insert_device(user)
      stub(429, %{"reason" => "TooManyRequests"})

      capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      assert_received {:apns_request, _}
      refute_received {:apns_request, _}
    end

    test "a user with no devices makes no request" do
      configure!()
      user = insert_user()
      stub(200)

      assert :ok = APNs.deliver_to_user(user.id, notification())
      refute_received {:apns_request, _}
    end
  end

  # ── Resolver ───────────────────────────────────────────────────────────────

  describe "apns_config/0 is all-or-nothing" do
    test "all four keys resolve to a complete config" do
      config = configure!()
      assert APNs.apns_config() == config
      assert APNs.configured?()
    end

    test "each single missing key yields nil, names that key, and sends nothing" do
      user = insert_user()
      insert_device(user)
      stub(200)
      full = full_config()

      for missing <- Keyword.keys(full) do
        configure!(Keyword.delete(full, missing))

        assert APNs.apns_config() == nil, "#{missing} missing must yield nil"
        refute APNs.configured?()

        log =
          capture_log(fn ->
            assert {:error, :not_configured} = APNs.deliver_to_user(user.id, notification())
          end)

        assert log =~ "missing #{missing}"
        refute_received {:apns_request, _}
        refute_secrets(log)

        for {k, v} <- full, k != missing, k != :auth_key do
          refute log =~ v, "the half-config log printed the value of #{k}"
        end
      end
    end

    test "nothing configured yields nil and sends nothing" do
      Application.delete_env(:platform, :apns)
      user = insert_user()
      insert_device(user)
      stub(200)

      assert APNs.apns_config() == nil

      capture_log(fn ->
        assert {:error, :not_configured} = APNs.deliver_to_user(user.id, notification())
      end)

      refute_received {:apns_request, _}
    end

    test "env vars win over app env, and Vault fills what neither has" do
      [key_id: _, team_id: team_id, topic: topic, auth_key: pem] = full_config()

      Application.put_env(:platform, :apns, key_id: "APPENVKEY1", team_id: team_id)
      System.put_env("APNS_KEY_ID", "ENVKEY0001")

      {:ok, _} =
        Platform.Vault.put("apns-topic", :api_key, topic,
          scope: {:platform, nil},
          name: "Test apns-topic (invented)"
        )

      assert APNs.apns_config() == nil, "auth_key is still missing, so still nil"

      {:ok, _} =
        Platform.Vault.put("apns-auth-key", :api_key, pem,
          scope: {:platform, nil},
          name: "Test apns-auth-key (invented)"
        )

      assert APNs.apns_config() == [
               key_id: "ENVKEY0001",
               team_id: team_id,
               topic: topic,
               auth_key: pem
             ]
    end

    test "an unusable key logs without echoing it and sends nothing" do
      configure!(
        full_config("-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----\n")
      )

      user = insert_user()
      device = insert_device(user)
      stub(200)

      log = capture_log(fn -> APNs.deliver_to_user(user.id, notification()) end)

      refute_received {:apns_request, _}
      assert device_exists?(device)
      refute_secrets(log, ["not-a-key"])
    end
  end

  # ── Through Platform.Push ──────────────────────────────────────────────────

  describe "Platform.Push routes APNs" do
    test "send_to_user delivers the same notification to APNs" do
      configure!()
      user = insert_user()
      insert_device(user)
      stub(200)
      n = notification()

      log = capture_log(fn -> assert :ok = Push.send_to_user(user.id, n) end)

      assert_received {:apns_request, req}
      assert req.body == Notification.to_apns_payload(n)
      refute_secrets(log, [jwt_from(req)])
    end

    test "send_to_user accepts a legacy map" do
      configure!()
      user = insert_user()
      insert_device(user)
      stub(200)

      capture_log(fn ->
        Push.send_to_user(user.id, %{title: "Legacy", body: "b", url: "/meetings/m"})
      end)

      assert_received {:apns_request, req}
      assert req.body["kind"] == "generic"
      assert req.body["aps"]["alert"] == %{"title" => "Legacy", "body" => "b"}
      refute Map.has_key?(req.body["aps"], "category")
    end

    test "an external user's APNs push carries the redacted copy" do
      configure!()
      user = insert_user("Xavier External")

      {:ok, _} =
        Tenancy.mark_membership_external(%{
          user_id: user.id,
          org_id: TenancyFixtures.fabrikam_org_id()
        })

      insert_device(user)
      stub(200)
      n = notification()

      capture_log(fn -> Push.send_to_user(user.id, n) end)

      assert_received {:apns_request, req}

      assert req.body["aps"]["alert"] == %{
               "title" => "New message",
               "body" => "You have a new message"
             }

      assert req.body["url"] == "/chat"
      refute Map.has_key?(req.body, "task_id")
      refute req.body |> Jason.encode!() =~ "Suite iOS app v1"
      assert req.body == Notification.to_apns_payload(Push.preview_for_user(user.id, n))
    end

    test "an archived user gets no APNs push" do
      configure!()
      user = insert_user()
      insert_device(user)
      user |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
      stub(200)

      Push.send_to_user(user.id, notification())

      refute_received {:apns_request, _}
    end

    test "send_notification to a user row delivers APNs; an agent row never does" do
      configure!()
      user = insert_user()
      insert_device(user)
      stub(200)

      {:ok, space} =
        Chat.create_space(%{
          name: "Apns",
          slug: "apns-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, user_row} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      # An AGENT-typed row whose participant_id happens to equal the user's id:
      # only the row TYPE may decide, never the id.
      agent_row =
        Repo.insert!(%Participant{
          space_id: space.id,
          participant_type: "agent",
          participant_id: user.id,
          display_name: "Agent",
          joined_at: DateTime.utc_now()
        })

      capture_log(fn -> Push.send_notification(agent_row.id, notification()) end)
      refute_received {:apns_request, _}

      capture_log(fn -> Push.send_notification(user_row.id, notification()) end)
      assert_received {:apns_request, _}
    end
  end

  defp decode_segment(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end
end
