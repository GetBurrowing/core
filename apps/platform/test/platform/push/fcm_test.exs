defmodule Platform.Push.FCMTest do
  @moduledoc """
  Task 01a10d8e stage 1: the FCM HTTP v1 transport.

  Both the OAuth token endpoint and `messages:send` are the `Req.Test` stub
  named `Platform.Push.FCM` (`config/test.exs`), so nothing reaches Google.
  The service-account key is generated per run, the registration tokens are
  invented sentinels, and the access token is minted by the stub. Every path
  runs under `capture_log/2` and asserts the log holds neither registration
  token, nor the access token, nor any PEM line, nor the signed JWT.
  """
  # async: false: swaps `:platform, :fcm` app env and FCM_* env vars, and the
  # access-token cache is a VM-wide `:persistent_term`.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.FCMFixtures

  alias Platform.Mobile.FcmDevice
  alias Platform.Push.FCM
  alias Platform.Push.Notification
  alias Platform.Repo

  @env_vars ~w(FCM_SERVICE_ACCOUNT_JSON FCM_PROJECT_ID)
  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"

  setup_all do
    %{pem: generated_rsa_pem()}
  end

  setup do
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Application.get_env(:platform, :fcm)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:platform, :fcm)
    :persistent_term.erase({FCM, :access_token})

    on_exit(fn ->
      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      if saved_app,
        do: Application.put_env(:platform, :fcm, saved_app),
        else: Application.delete_env(:platform, :fcm)

      :persistent_term.erase({FCM, :access_token})
    end)

    :ok
  end

  defp notification do
    Notification.new(%{
      kind: "chat_mention",
      title: "Sam in Design",
      body: "hi @Robin",
      url: "/chat/design",
      space_id: "01a10d8e-0000-7000-8000-00000000000a",
      message_id: "01a10d8e-0000-7000-8000-00000000000b",
      author_name: "Sam",
      space_name: "Design",
      collapse_id: String.duplicate("c", 80)
    })
  end

  defp device_exists?(device), do: Repo.get(FcmDevice, device.id) != nil

  defp bearer_from(%{headers: %{"authorization" => "Bearer " <> token}}), do: token

  defp decode_segment(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp drain_sends(acc \\ 0) do
    receive do
      {:fcm_send, _} -> drain_sends(acc + 1)
    after
      0 -> acc
    end
  end

  # ── Responses ──────────────────────────────────────────────────────────────

  describe "deliver_to_user/2 responses" do
    test "200 posts a data-only v1 message to the project and keeps the row", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)
      stub_fcm(self(), {200, %{"name" => "projects/p/messages/1"}})
      n = notification()

      log = capture_log(fn -> assert :ok = FCM.deliver_to_user(user.id, n) end)

      assert_received {:fcm_token_request, %{form: form}}
      assert_received {:fcm_send, req}

      assert req.host == "fcm.googleapis.com"
      assert req.path == "/v1/projects/#{project_id()}/messages:send"
      assert bearer_from(req) =~ access_token_prefix()

      message = req.body["message"]
      assert message["token"] == sentinel_token()
      assert Map.delete(message, "token") == Notification.to_fcm_payload(n)
      refute Map.has_key?(message, "notification"), "must be data-only"
      assert message["android"]["priority"] == "high"
      assert message["android"]["collapse_key"] == String.duplicate("c", 64)
      assert Enum.all?(message["data"], fn {_k, v} -> is_binary(v) end)
      assert message["data"]["author_name"] == "Sam"
      assert message["data"]["space_name"] == "Design"

      assert device_exists?(device)
      refute_secrets(log, [form["assertion"]])
    end

    # Task 01a14ba1: per-device category id, as in APNs.
    test "each device gets the category id for the scheme it registered", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      insert_fcm_device(user)

      user
      |> insert_fcm_device(other_token())
      |> Ecto.Changeset.change(push_category_scheme: "burrow")
      |> Repo.update!()

      stub_fcm(self(), {200, %{"name" => "projects/p/messages/1"}})
      n = notification()

      log = capture_log(fn -> assert :ok = FCM.deliver_to_user(user.id, n) end)

      assert_received {:fcm_send, first}
      assert_received {:fcm_send, second}
      by_token = Map.new([first, second], &{&1.body["message"]["token"], &1.body["message"]})

      legacy = by_token[sentinel_token()]
      burrow = by_token[other_token()]

      assert legacy["data"]["category"] == "SUITE_MENTION"
      assert burrow["data"]["category"] == "BURROW_MENTION"
      assert Map.delete(legacy, "token") == Notification.to_fcm_payload(n)
      assert Map.delete(burrow, "token") == Notification.to_fcm_payload(n, :burrow)
      refute_secrets(log)
    end

    test "404 UNREGISTERED deletes the device row", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)
      stub_fcm(self(), {404, fcm_error(404, "NOT_FOUND", "UNREGISTERED")})

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert_received {:fcm_send, _}
      refute device_exists?(device), "UNREGISTERED must prune the row"
      refute_secrets(log)
    end

    test "400 INVALID_ARGUMENT naming the token deletes the device row", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)

      bad_request = %{
        "@type" => "type.googleapis.com/google.rpc.BadRequest",
        "fieldViolations" => [
          %{"field" => "message.token", "description" => "Invalid registration token"}
        ]
      }

      stub_fcm(
        self(),
        {400, fcm_error(400, "INVALID_ARGUMENT", "INVALID_ARGUMENT", [bad_request])}
      )

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      refute device_exists?(device)
      refute_secrets(log)
    end

    test "400 INVALID_ARGUMENT about anything else keeps the row", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)

      bad_request = %{
        "@type" => "type.googleapis.com/google.rpc.BadRequest",
        "fieldViolations" => [%{"field" => "message.data", "description" => "too big"}]
      }

      stub_fcm(
        self(),
        {400, fcm_error(400, "INVALID_ARGUMENT", "INVALID_ARGUMENT", [bad_request])}
      )

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert device_exists?(device)
      assert log =~ "INVALID_ARGUMENT"
      refute_secrets(log)
    end

    test "a 404 that is not UNREGISTERED keeps the row (a wrong project is not a dead token)",
         %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)
      stub_fcm(self(), {404, fcm_error(404, "NOT_FOUND")})

      capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert device_exists?(device)
    end

    for status <- [429, 500, 503] do
      test "#{status} keeps the row, logs row id and status only, and is not retried",
           %{pem: pem} do
        configure!(pem)
        user = insert_user()
        device = insert_fcm_device(user)
        stub_fcm(self(), {unquote(status), fcm_error(unquote(status), "UNAVAILABLE")})

        log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

        assert drain_sends() == 1, "an HTTP status is final, never retried"
        assert device_exists?(device)
        assert log =~ device.id
        assert log =~ "#{unquote(status)}"
        refute log =~ "invented error message", "the free-text message is never logged"
        refute_secrets(log)
      end
    end

    test "a cold pool (three transport errors, then 200) delivers in four attempts",
         %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)

      stub_fcm(self(), fn
        attempt when attempt <= 3 -> :transport_error
        _ -> {200, %{"name" => "projects/p/messages/2"}}
      end)

      log = capture_log(fn -> assert :ok = FCM.deliver_to_user(user.id, notification()) end)

      assert drain_sends() == 4
      refute log =~ "transport_error", "the fourth attempt delivered, so nothing failed"
      assert device_exists?(device)
      refute_secrets(log)
    end

    test "past the retry budget: exactly four attempts, then dropped with the reason atom",
         %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)
      stub_fcm(self(), fn _ -> :transport_error end)

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert drain_sends() == 4
      assert log =~ "transport_error (econnrefused)"
      assert log =~ device.id
      refute log =~ "Req.", "never the exception struct, which can carry the request"
      assert device_exists?(device)
      refute_secrets(log)
    end

    test "a user with no devices makes no request at all", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      stub_fcm(self(), {200, %{}})

      assert :ok = FCM.deliver_to_user(user.id, notification())
      refute_received {:fcm_token_request, _}
      refute_received {:fcm_send, _}
    end

    test "base_url and token_url overrides route to a local stub", %{pem: pem} do
      configure!(pem,
        base_url: "http://fcm-stub.test:8089",
        token_url: "http://fcm-stub.test:8089/token"
      )

      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert_received {:fcm_token_request, %{host: "fcm-stub.test"}}
      assert_received {:fcm_send, %{host: "fcm-stub.test"}}
    end
  end

  # ── Auth ───────────────────────────────────────────────────────────────────

  describe "OAuth access token" do
    test "the assertion is an RS256 JWT for the service account, verifiable with its key",
         %{pem: pem} do
      configure!(pem)
      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert_received {:fcm_token_request, %{form: form}}
      assert form["grant_type"] == @jwt_bearer
      jwt = form["assertion"]

      [header, claims, _sig] = String.split(jwt, ".")
      assert %{"alg" => "RS256", "typ" => "JWT"} = decode_segment(header)

      assert %{
               "iss" => iss,
               "scope" => @scope,
               "aud" => aud,
               "iat" => iat,
               "exp" => exp
             } = decode_segment(claims)

      assert iss == client_email()
      assert aud == token_uri()
      assert exp - iat == 3600

      public = pem |> JOSE.JWK.from_pem() |> JOSE.JWK.to_public()
      assert {true, _, _} = JOSE.JWT.verify_strict(public, ["RS256"], jwt)

      refute_secrets(log, [jwt])
    end

    test "the access token is cached across sends", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      capture_log(fn ->
        FCM.deliver_to_user(user.id, notification())
        FCM.deliver_to_user(user.id, notification())
      end)

      assert_received {:fcm_token_request, _}
      refute_received {:fcm_token_request, _}
      assert_received {:fcm_send, first}
      assert_received {:fcm_send, second}
      assert bearer_from(first) == bearer_from(second)
    end

    test "a token within five minutes of expiry is not reused", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}}, expires_in: 240)

      capture_log(fn ->
        FCM.deliver_to_user(user.id, notification())
        FCM.deliver_to_user(user.id, notification())
      end)

      assert_received {:fcm_token_request, _}
      assert_received {:fcm_token_request, _}
    end

    test "a 401 erases the cached token, so the next send fetches a fresh one", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)
      stub_fcm(self(), {401, fcm_error(401, "UNAUTHENTICATED", "THIRD_PARTY_AUTH_ERROR")})

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert_received {:fcm_token_request, _}
      assert_received {:fcm_send, first}
      assert device_exists?(device), "a 401 is our credential, never the device's"

      stub_fcm(self(), {200, %{}})
      capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert_received {:fcm_token_request, _}, "the 401 erased the cache, so it re-fetched"
      assert_received {:fcm_send, second}
      assert bearer_from(first) =~ access_token_prefix()
      assert bearer_from(second) =~ access_token_prefix()
      refute_secrets(log)
    end

    test "a refused token exchange sends nothing and logs no secret", %{pem: pem} do
      configure!(pem)
      user = insert_user()
      device = insert_fcm_device(user)
      stub_fcm(self(), {200, %{}}, token_status: 400)

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert_received {:fcm_token_request, %{form: form}}
      refute_received {:fcm_send, _}
      assert device_exists?(device)
      assert log =~ "400"
      refute_secrets(log, [form["assertion"]])
    end
  end

  # ── Resolver ───────────────────────────────────────────────────────────────

  describe "fcm_config/0 is all-or-nothing" do
    test "a service account alone is complete: project_id comes from its JSON", %{pem: pem} do
      configure!(pem)

      assert [
               project_id: "burrow-test-project",
               client_email: _,
               private_key: ^pem,
               token_uri: "https://oauth2.example.test/token"
             ] = FCM.fcm_config()

      assert FCM.configured?()
    end

    test "an explicit project_id wins over the JSON's", %{pem: pem} do
      configure!(pem, project_id: "explicit-project")
      assert FCM.fcm_config()[:project_id] == "explicit-project"
    end

    test "nothing configured yields nil, one quiet line, and sends nothing", %{pem: _pem} do
      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      assert FCM.fcm_config() == nil
      refute FCM.configured?()

      log =
        capture_log(fn ->
          assert {:error, :not_configured} = FCM.deliver_to_user(user.id, notification())
        end)

      refute log =~ "half-configured", "an install with no FCM at all is not an error"
      refute_received {:fcm_token_request, _}
      refute_received {:fcm_send, _}
    end

    test "a project id with no service account is half-configured and names the missing key" do
      Application.put_env(:platform, :fcm, project_id: "lonely-project")
      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      assert FCM.fcm_config() == nil

      log =
        capture_log(fn ->
          assert {:error, :not_configured} = FCM.deliver_to_user(user.id, notification())
        end)

      assert log =~ "missing service_account"
      refute log =~ "lonely-project", "the half-config log printed a value"
      refute_received {:fcm_send, _}
    end

    test "a service account missing a field names the field, never a value", %{pem: pem} do
      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      for field <- ~w(private_key client_email token_uri) do
        Application.put_env(:platform, :fcm,
          service_account: service_account_json(pem, %{field => nil})
        )

        assert FCM.fcm_config() == nil, "#{field} missing must yield nil"

        log =
          capture_log(fn ->
            assert {:error, :not_configured} = FCM.deliver_to_user(user.id, notification())
          end)

        assert log =~ "missing service_account.#{field}"
        refute log =~ client_email()
        refute_secrets(log)
      end

      Application.put_env(:platform, :fcm,
        service_account: service_account_json(pem, %{"project_id" => nil})
      )

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)
      assert log =~ "missing project_id"
      refute_received {:fcm_send, _}
    end

    test "an unparseable service account is refused without echoing it" do
      Application.put_env(:platform, :fcm,
        service_account: "{\"private_key\": \"-----BEGIN PRIVATE KEY-----\\nnot-json"
      )

      user = insert_user()
      insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      assert FCM.fcm_config() == nil

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      assert log =~ "service_account"
      refute log =~ "not-json"
      refute_secrets(log)
    end

    test "env wins over app env, and Vault fills what neither has", %{pem: pem} do
      Application.put_env(:platform, :fcm, project_id: "app-env-project")
      System.put_env("FCM_PROJECT_ID", "env-project")

      assert FCM.fcm_config() == nil, "service_account still missing"

      {:ok, _} =
        Platform.Vault.put("fcm-service-account", :api_key, service_account_json(pem),
          scope: {:platform, nil},
          name: "Test fcm-service-account (invented)"
        )

      config = FCM.fcm_config()
      assert config[:project_id] == "env-project"
      assert config[:client_email] == client_email()
      assert config[:private_key] == pem
    end

    test "an unusable private key logs without echoing it and sends nothing", %{pem: _pem} do
      Application.put_env(:platform, :fcm,
        service_account:
          service_account_json(
            "-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----\n"
          )
      )

      user = insert_user()
      device = insert_fcm_device(user)
      stub_fcm(self(), {200, %{}})

      log = capture_log(fn -> FCM.deliver_to_user(user.id, notification()) end)

      refute_received {:fcm_token_request, _}
      refute_received {:fcm_send, _}
      assert device_exists?(device)
      refute_secrets(log, ["not-a-key"])
    end
  end
end
