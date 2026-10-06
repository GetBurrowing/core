defmodule Platform.Mobile.VoipDeviceLifecycleTest do
  @moduledoc """
  Task 01a10db7 stage 1: `apns_voip_devices` is the third push-device table,
  and sign-out must clear it like the other two.

  Sign-out REVOKES the `app_sessions` row (stamps `revoked_at`) rather than
  deleting it, so the table's `ON DELETE CASCADE` never fires: a VoIP row
  survives sign-out unless `Mobile.revoke_session/1` and
  `Mobile.unregister_device/2` delete it explicitly. A surviving row would
  keep ringing a signed-out phone.
  """
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, only: [create_user!: 0]

  alias Platform.Mobile
  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.ApnsVoipDevice
  alias Platform.Mobile.FcmDevice

  @alert_token String.duplicate("a1e7", 16)
  @voip_token String.duplicate("b0b0", 16)
  @fcm_token "fcmLifecycle01:APA91b" <> String.duplicate("Lif3_T0k-", 12)

  defp signed_in(user, install_id) do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)

    {:ok, %{session: session}} =
      Mobile.exchange_code(code, verifier, %{app_install_id: install_id})

    session
  end

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  # One row in each of the three tables for one session/install.
  defp register_all!(session, install_id, suffix \\ "") do
    {:ok, _} =
      Mobile.register_device(session, %{
        "token" => @alert_token <> suffix,
        "environment" => "sandbox",
        "bundle_id" => "com.kobo-ai.burrow",
        "app_install_id" => install_id
      })

    {:ok, _} =
      Mobile.register_device(session, %{
        "platform" => "android",
        "token" => @fcm_token <> suffix,
        "package_name" => "com.koboai.burrow",
        "app_install_id" => install_id
      })

    {:ok, _} =
      Mobile.register_voip_device(session, %{
        "token" => @voip_token <> suffix,
        "environment" => "sandbox",
        "bundle_id" => "com.kobo-ai.burrow",
        "app_install_id" => install_id
      })

    :ok
  end

  defp count(schema, field, value) do
    Repo.aggregate(from(d in schema, where: field(d, ^field) == ^value), :count)
  end

  test "revoke_session deletes the session's VoIP device" do
    user = create_user!()
    session = signed_in(user, "install-1")
    register_all!(session, "install-1")

    # A second install of the same user must be untouched (the delete is
    # scoped to the session, not the user).
    other_session = signed_in(user, "install-2")
    register_all!(other_session, "install-2", "00")

    assert count(ApnsVoipDevice, :app_session_id, session.id) == 1
    assert count(ApnsDevice, :app_session_id, session.id) == 1
    assert count(FcmDevice, :app_session_id, session.id) == 1

    assert {:ok, revoked} = Mobile.revoke_session(session)
    assert %DateTime{} = revoked.revoked_at

    assert count(ApnsVoipDevice, :app_session_id, session.id) == 0
    assert count(ApnsDevice, :app_session_id, session.id) == 0
    assert count(FcmDevice, :app_session_id, session.id) == 0

    assert count(ApnsVoipDevice, :app_session_id, other_session.id) == 1
    assert count(ApnsDevice, :app_session_id, other_session.id) == 1
    assert count(FcmDevice, :app_session_id, other_session.id) == 1
  end

  test "unregister_device deletes the install's VoIP device" do
    user = create_user!()
    session = signed_in(user, "install-1")
    register_all!(session, "install-1")

    other_session = signed_in(user, "install-2")
    register_all!(other_session, "install-2", "00")

    assert count(ApnsVoipDevice, :app_install_id, "install-1") == 1

    assert :ok = Mobile.unregister_device(user, "install-1")

    assert count(ApnsVoipDevice, :app_install_id, "install-1") == 0
    assert count(ApnsDevice, :app_install_id, "install-1") == 0
    assert count(FcmDevice, :app_install_id, "install-1") == 0

    assert count(ApnsVoipDevice, :app_install_id, "install-2") == 1
    assert count(ApnsDevice, :app_install_id, "install-2") == 1
    assert count(FcmDevice, :app_install_id, "install-2") == 1
  end
end
