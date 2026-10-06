defmodule Platform.FCMFixtures do
  @moduledoc """
  Fixtures for the FCM transport (task 01a10d8e stage 1).

  Every credential here is invented for the run: the service-account JSON
  carries a locally generated RSA key, the registration tokens are sentinels
  no Android device holds, and the access token is minted by the `Req.Test`
  stub named `Platform.Push.FCM` (`config/test.exs`). Nothing reaches Google.
  """

  import ExUnit.Assertions

  alias Platform.Mobile.AppSession
  alias Platform.Mobile.FcmDevice
  alias Platform.Repo

  # Invented registration tokens: FCM-shaped (`<id>:<base64url>`), held by
  # no device.
  @sentinel_token "fcmSENTINEL0:APA91b" <> String.duplicate("S3nt1n3l_Tok-", 10)
  @other_token "fcmOTHER0001:APA91b" <> String.duplicate("0th3rT0k3n_-", 10)

  @access_token_prefix "ya29.SENTINEL-ACCESS-"

  @project_id "burrow-test-project"
  @client_email "fcm-sender@burrow-test-project.iam.gserviceaccount.com"
  @token_uri "https://oauth2.example.test/token"

  def sentinel_token, do: @sentinel_token
  def other_token, do: @other_token
  def project_id, do: @project_id
  def client_email, do: @client_email
  def token_uri, do: @token_uri
  def access_token_prefix, do: @access_token_prefix

  @doc "A fresh RSA private key, PKCS#8 PEM, the shape Google issues."
  def generated_rsa_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end

  @doc "A throwaway service-account JSON string (as Vault or env stores it)."
  def service_account_json(pem, overrides \\ %{}) do
    %{
      "type" => "service_account",
      "project_id" => @project_id,
      "private_key_id" => "0123456789abcdef0123456789abcdef01234567",
      "private_key" => pem,
      "client_email" => @client_email,
      "client_id" => "100000000000000000000",
      "token_uri" => @token_uri
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Jason.encode!()
  end

  def configure!(pem, extra \\ []) do
    config = Keyword.merge([service_account: service_account_json(pem)], extra)
    Application.put_env(:platform, :fcm, config)
    config
  end

  def insert_user(name \\ "Fcm User") do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: name,
      email: "fcm-#{n}@example.com",
      oidc_sub: "sub-fcm-#{n}"
    })
  end

  def insert_fcm_device(user, token \\ @sentinel_token) do
    session =
      Repo.insert!(%AppSession{
        user_id: user.id,
        token_hash: :crypto.strong_rand_bytes(32),
        app_install_id: "install-#{System.unique_integer([:positive])}"
      })

    Repo.insert!(%FcmDevice{
      user_id: user.id,
      app_session_id: session.id,
      app_install_id: session.app_install_id,
      token: token,
      package_name: "com.koboai.burrow",
      last_registered_at: DateTime.utc_now()
    })
  end

  @doc """
  Stub both FCM endpoints on the `Platform.Push.FCM` `Req.Test` plug.

  The token endpoint answers a fresh access token per call (`expires_in`
  from `opts`) and reports `{:fcm_token_request, form}`; the send endpoint
  answers `status`/`body` from `responder` (a fun of the attempt number or a
  `{status, body}` tuple) and reports `{:fcm_send, req}`.
  """
  def stub_fcm(test_pid, responder, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3599)
    token_status = Keyword.get(opts, :token_status, 200)
    sends = :counters.new(1, [])
    tokens = :counters.new(1, [])

    Req.Test.stub(Platform.Push.FCM, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      if String.ends_with?(conn.request_path, "/token") do
        :counters.add(tokens, 1, 1)
        form = URI.decode_query(raw)
        send(test_pid, {:fcm_token_request, %{host: conn.host, form: form}})

        if token_status == 200 do
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "access_token" => @access_token_prefix <> Integer.to_string(:counters.get(tokens, 1)),
            "expires_in" => expires_in,
            "token_type" => "Bearer"
          })
        else
          conn
          |> Plug.Conn.put_status(token_status)
          |> Req.Test.json(%{"error" => "invalid_grant"})
        end
      else
        :counters.add(sends, 1, 1)
        attempt = :counters.get(sends, 1)

        send(test_pid, {
          :fcm_send,
          %{
            host: conn.host,
            path: conn.request_path,
            headers: Map.new(conn.req_headers),
            body: if(raw == "", do: nil, else: Jason.decode!(raw))
          }
        })

        case if(is_function(responder, 1), do: responder.(attempt), else: responder) do
          :transport_error ->
            Req.Test.transport_error(conn, :econnrefused)

          {status, body} ->
            conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
        end
      end
    end)
  end

  @doc "An FCM v1 error body (google.rpc.Status) with an FcmError errorCode."
  def fcm_error(code, status, error_code \\ nil, extra_details \\ []) do
    details =
      if(error_code,
        do: [
          %{
            "@type" => "type.googleapis.com/google.firebase.fcm.v1.FcmError",
            "errorCode" => error_code
          }
        ],
        else: []
      ) ++ extra_details

    %{
      "error" => %{
        "code" => code,
        "message" => "invented error message",
        "status" => status,
        "details" => details
      }
    }
  end

  @doc """
  Assert `log` holds none of the secrets: either registration token, any
  access token the stub minted, any PEM line, and anything in `extra`.
  """
  def refute_secrets(log, extra \\ []) do
    for secret <-
          [@sentinel_token, @other_token, @access_token_prefix, "PRIVATE KEY", "-----BEGIN"] ++
            extra do
      refute log =~ secret, "log leaked a secret: #{String.slice(secret, 0, 6)}..."
    end

    :ok
  end
end
