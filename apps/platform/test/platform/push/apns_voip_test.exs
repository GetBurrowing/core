defmodule Platform.Push.APNsVoipTest do
  @moduledoc """
  Task 01a10db7 stage 1: `Platform.Push.APNs.deliver_voip_to_user/2`, the
  PushKit VoIP send that rings a device through CallKit.

  Every request goes to the `Req.Test` stub named `Platform.Push.APNs`
  (`:apns_req_options` in `config/test.exs`), so nothing reaches Apple. Key
  material is generated per run; device tokens are invented sentinels.
  """
  # async: false — swaps `:platform, :apns` app env and APNS_* env vars, and
  # the provider-JWT cache is a VM-wide `:persistent_term`.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.ApnsVoipDevice
  alias Platform.Mobile.AppSession
  alias Platform.Push.APNs
  alias Platform.Push.Notification

  @voip_token String.duplicate("5ca1ab1e", 8)
  @alert_token String.duplicate("a1e27000", 8)
  @ring_id "01a10db7-0000-7000-8000-00000000c0de"

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

  defp configure! do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, ec_key)])

    Application.put_env(:platform, :apns,
      key_id: "TESTKEY001",
      team_id: "TESTTEAM01",
      topic: "com.kobo-ai.burrow",
      auth_key: pem
    )
  end

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Voip User",
      email: "voip-#{n}@example.com",
      oidc_sub: "sub-voip-#{n}"
    })
  end

  defp insert_session(user, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %AppSession{
          user_id: user.id,
          token_hash: :crypto.strong_rand_bytes(32),
          app_install_id: "install-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  defp insert_voip_device(user, session, token \\ @voip_token) do
    Repo.insert!(%ApnsVoipDevice{
      user_id: user.id,
      app_session_id: session.id,
      app_install_id: session.app_install_id,
      token: token,
      environment: "production",
      bundle_id: "com.kobo-ai.burrow",
      last_registered_at: DateTime.utc_now()
    })
  end

  defp insert_alert_device(user, session) do
    Repo.insert!(%ApnsDevice{
      user_id: user.id,
      app_session_id: session.id,
      app_install_id: session.app_install_id,
      token: @alert_token,
      environment: "production",
      bundle_id: "com.kobo-ai.burrow",
      last_registered_at: DateTime.utc_now()
    })
  end

  defp stub(status, body \\ %{}) do
    test_pid = self()

    Req.Test.stub(APNs, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {
        :apns_request,
        %{path: conn.request_path, headers: Map.new(conn.req_headers), body: Jason.decode!(raw)}
      })

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp payload do
    %{ring_id: @ring_id, meeting_id: "m-1", caller_name: "Ada"}
  end

  test "sends a voip push to the .voip topic with VoIP headers and routing body" do
    configure!()
    user = insert_user()
    session = insert_session(user)
    insert_voip_device(user, session)
    stub(200)

    log = capture_log(fn -> assert :ok = APNs.deliver_voip_to_user(user.id, payload()) end)

    assert_received {:apns_request, req}
    assert req.path == "/3/device/" <> @voip_token
    assert req.headers["apns-topic"] == "com.kobo-ai.burrow.voip"
    assert req.headers["apns-push-type"] == "voip"
    assert req.headers["apns-priority"] == "10"
    assert req.headers["apns-expiration"] == "0"
    assert req.headers["apns-collapse-id"] == @ring_id
    assert "bearer " <> _ = req.headers["authorization"]

    assert req.body["aps"] == %{}
    assert req.body["ring_id"] == @ring_id
    assert req.body["meeting_id"] == "m-1"
    assert req.body["caller_name"] == "Ada"
    assert req.body["install_host"] == Notification.install_host()

    refute_received {:apns_request, _}
    refute log =~ @voip_token
  end

  test "an install_host in the payload wins over the default" do
    configure!()
    user = insert_user()
    insert_voip_device(user, insert_session(user))
    stub(200)

    capture_log(fn ->
      APNs.deliver_voip_to_user(user.id, Map.put(payload(), "install_host", "a.example"))
    end)

    assert_received {:apns_request, %{body: %{"install_host" => "a.example"}}}
  end

  test "a device whose app session is revoked is not rung" do
    configure!()
    user = insert_user()
    live = insert_session(user)
    revoked = insert_session(user, %{revoked_at: DateTime.utc_now()})
    insert_voip_device(user, live)
    insert_voip_device(user, revoked, String.duplicate("de1e7ed0", 8))
    stub(200)

    capture_log(fn -> assert :ok = APNs.deliver_voip_to_user(user.id, payload()) end)

    assert_received {:apns_request, %{path: path}}
    assert path == "/3/device/" <> @voip_token
    refute_received {:apns_request, _}
  end

  test "only VoIP devices are rung, never the alert device" do
    configure!()
    user = insert_user()
    session = insert_session(user)
    insert_alert_device(user, session)
    stub(200)

    assert :ok = APNs.deliver_voip_to_user(user.id, payload())
    refute_received {:apns_request, _}
  end

  test "410 prunes the VoIP row and leaves the install's alert row" do
    configure!()
    user = insert_user()
    session = insert_session(user)
    voip = insert_voip_device(user, session)
    alert = insert_alert_device(user, session)
    stub(410, %{"reason" => "Unregistered"})

    log = capture_log(fn -> APNs.deliver_voip_to_user(user.id, payload()) end)

    assert Repo.get(ApnsVoipDevice, voip.id) == nil
    assert Repo.get(ApnsDevice, alert.id) != nil
    refute log =~ @voip_token
  end

  test "400 BadDeviceToken and DeviceTokenNotForTopic prune the VoIP row" do
    configure!()

    for reason <- ~w(BadDeviceToken DeviceTokenNotForTopic) do
      user = insert_user()
      voip = insert_voip_device(user, insert_session(user))
      stub(400, %{"reason" => reason})

      capture_log(fn -> APNs.deliver_voip_to_user(user.id, payload()) end)

      assert Repo.get(ApnsVoipDevice, voip.id) == nil, reason
    end
  end

  test "an unconfigured install refuses and sends nothing" do
    user = insert_user()
    insert_voip_device(user, insert_session(user))
    stub(200)

    capture_log(fn ->
      assert {:error, :not_configured} = APNs.deliver_voip_to_user(user.id, payload())
    end)

    refute_received {:apns_request, _}
  end
end
