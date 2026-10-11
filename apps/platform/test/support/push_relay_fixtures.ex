defmodule Platform.PushRelayFixtures do
  @moduledoc """
  Fixtures for the push relay (task 01a1261e stage 2).

  Every credential is invented for the run: the APNs `.p8` is a P-256 key
  generated here, the FCM service account comes from `Platform.FCMFixtures`,
  device tokens are sentinels no device holds. APNs, FCM and the
  install-to-relay hop are all `Req.Test` stubs (`config/test.exs`), so
  nothing leaves the VM.

  `forward_to_relay/2` makes ONE VM play both installs: the install-side
  `Platform.Push.Relay` request is captured, then dispatched into this
  endpoint's relay route with relay mode and the relay's provider config
  switched on for exactly the duration of that call, so the install side
  still sees itself as having no direct credentials.
  """

  import ExUnit.Assertions

  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.AppSession
  alias Platform.Mobile.FcmDevice
  alias Platform.Push.Seal
  alias Platform.Repo

  @apns_token String.duplicate("5e771e0d", 8)
  @apns_token_2 String.duplicate("0badc0de", 8)

  def apns_token, do: @apns_token
  def apns_token_2, do: @apns_token_2

  @doc "A throwaway APNs config; `overrides` replace keys (sentinels in tests)."
  def apns_config(overrides \\ []) do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, ec_key)])

    Keyword.merge(
      [key_id: "TESTKEY001", team_id: "TESTTEAM01", topic: "com.kobo-ai.burrow", auth_key: pem],
      overrides
    )
  end

  @doc "Snapshot the app env and env vars a relay test touches; restore on exit."
  def isolate_push_env! do
    keys = [:apns, :fcm, :push_relay, :push_relay_server, Platform.Push]

    vars =
      ~w(APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC APNS_AUTH_KEY FCM_SERVICE_ACCOUNT_JSON FCM_PROJECT_ID PUSH_RELAY_URL PUSH_RELAY_CREDENTIAL)

    saved = Map.new(keys, &{&1, Application.get_env(:platform, &1)})
    saved_vars = Map.new(vars, &{&1, System.get_env(&1)})

    Enum.each(keys, &Application.delete_env(:platform, &1))
    Enum.each(vars, &System.delete_env/1)
    erase_caches()
    Platform.Push.RelayRateLimit.reset()

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(:platform, k)
        {k, v} -> Application.put_env(:platform, k, v)
      end)

      Enum.each(saved_vars, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      erase_caches()
    end)

    :ok
  end

  defp erase_caches do
    :persistent_term.erase({Platform.Push.APNs, :provider_jwt})
    :persistent_term.erase({Platform.Push.FCM, :access_token})
  end

  @doc "Stub APNs: answer `responder` (status or fun of the token), report `{:apns, req}`."
  def stub_apns(test_pid, responder \\ 200) do
    Req.Test.stub(Platform.Push.APNs, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      "/3/device/" <> token = conn.request_path

      send(test_pid, {
        :apns,
        %{token: token, headers: Map.new(conn.req_headers), raw: raw, body: Jason.decode!(raw)}
      })

      status = if is_function(responder, 1), do: responder.(token), else: responder
      body = if status == 410, do: %{"reason" => "Unregistered"}, else: %{}
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  @doc "An app session plus an APNs device row, optionally with an X25519 key."
  def insert_apns_device!(user, opts \\ []) do
    session = session!(user)

    Repo.insert!(%ApnsDevice{
      user_id: user.id,
      app_session_id: session.id,
      app_install_id: session.app_install_id,
      token: Keyword.get(opts, :token, @apns_token),
      environment: Keyword.get(opts, :environment, "production"),
      bundle_id: "com.kobo-ai.burrow",
      push_public_key: opts[:push_public_key],
      last_registered_at: DateTime.utc_now()
    })
  end

  @doc "An app session plus an FCM device row, optionally with an X25519 key."
  def insert_fcm_device!(user, opts \\ []) do
    session = session!(user)

    Repo.insert!(%FcmDevice{
      user_id: user.id,
      app_session_id: session.id,
      app_install_id: session.app_install_id,
      token: Keyword.get(opts, :token, Platform.FCMFixtures.sentinel_token()),
      package_name: "com.koboai.burrow",
      push_public_key: opts[:push_public_key],
      last_registered_at: DateTime.utc_now()
    })
  end

  defp session!(user) do
    Repo.insert!(%AppSession{
      user_id: user.id,
      token_hash: :crypto.strong_rand_bytes(32),
      app_install_id: "install-#{System.unique_integer([:positive])}"
    })
  end

  @doc "A device keypair: `{stored public key, raw private key}`."
  def device_keypair do
    {pk, sk} = Seal.generate_keypair()
    {Seal.encode_key(pk), sk}
  end

  @doc """
  Stub the install-to-relay hop with a responder fun `fn raw_body, decoded ->
  {status, body} end`, reporting `{:relay_request, %{raw, body, headers}}`.
  """
  def stub_relay(test_pid, responder) do
    Req.Test.stub(Platform.Push.Relay, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(raw)

      send(test_pid, {
        :relay_request,
        %{raw: raw, body: decoded, headers: Map.new(conn.req_headers), path: conn.request_path}
      })

      {status, body} = responder.(raw, decoded)
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  @doc """
  Responder for `stub_relay/2` that dispatches the captured request into this
  endpoint's relay route, as the relay R would receive it, with relay mode
  and `relay_provider_env` (a keyword of `:apns` / `:fcm` app env) switched
  on only for the duration of the call. Reports `{:relay_response, status,
  raw_body}`.
  """
  def forward_to_relay(test_pid, credential, relay_provider_env) do
    fn raw, _decoded ->
      Application.put_env(:platform, :push_relay_server, enabled: true)
      Enum.each(relay_provider_env, fn {k, v} -> Application.put_env(:platform, k, v) end)

      try do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> credential)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            PlatformWeb.Endpoint,
            :post,
            "/api/push-relay/v1/notifications",
            raw
          )

        send(test_pid, {:relay_response, conn.status, conn.resp_body})
        {conn.status, Jason.decode!(conn.resp_body)}
      after
        Application.delete_env(:platform, :push_relay_server)
        Enum.each(relay_provider_env, fn {k, _} -> Application.delete_env(:platform, k) end)
      end
    end
  end

  @doc "Assert none of `needles` occurs in `haystack` (named in the failure, not printed whole)."
  def refute_contains(haystack, needles, where) do
    for needle <- needles do
      refute haystack =~ needle, "#{where} contains the sentinel #{inspect(needle)}"
    end

    :ok
  end
end
