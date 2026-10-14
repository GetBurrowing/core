defmodule Platform.Push.UnreadStampTest do
  @moduledoc """
  Task 01a1261e stage 1: `Platform.Push` stamps the recipient's Chat unread
  total (`Platform.Chat.total_unread_for_viewer/1`) and the time it was read
  onto the native-push copy, for USER recipients only, and a failing count
  never costs the push.

  Driven end to end through `Push.send_to_user/2` and
  `Push.send_notification/2` into the `Req.Test` APNs and FCM stubs, so what
  is asserted is the body each provider would receive.
  """
  # async: false: swaps `:platform, :apns` / `:fcm` / `Platform.Push` app env;
  # the APNs JWT and FCM token caches are VM-wide `:persistent_term`s.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.FCMFixtures

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.AppSession
  alias Platform.Push
  alias Platform.Push.APNs
  alias Platform.Push.FCM
  alias Platform.Push.Notification
  alias Platform.Repo

  @apns_token String.duplicate("5e771e0d", 8)

  setup do
    saved =
      for key <- [:apns, :fcm, Push], into: %{}, do: {key, Application.get_env(:platform, key)}

    saved_env =
      for k <-
            ~w(APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC APNS_AUTH_KEY FCM_SERVICE_ACCOUNT_JSON FCM_PROJECT_ID),
          into: %{},
          do: {k, System.get_env(k)}

    Enum.each(saved_env, fn {k, _} -> System.delete_env(k) end)
    Application.delete_env(:platform, Push)
    :persistent_term.erase({APNs, :provider_jwt})
    :persistent_term.erase({FCM, :access_token})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:platform, key)
        {key, value} -> Application.put_env(:platform, key, value)
      end)

      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      :persistent_term.erase({APNs, :provider_jwt})
      :persistent_term.erase({FCM, :access_token})
    end)

    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    p8 = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, ec_key)])

    Application.put_env(:platform, :apns,
      key_id: "TESTKEY001",
      team_id: "TESTTEAM01",
      topic: "com.kobo-ai.burrow",
      auth_key: p8
    )

    configure!(generated_rsa_pem())

    test_pid = self()

    Req.Test.stub(APNs, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:apns_body, Jason.decode!(raw)})
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
    end)

    stub_fcm(test_pid, {200, %{"name" => "projects/p/messages/1"}})

    :ok
  end

  # ── counter seams (config :platform, Platform.Push, unread_counter:) ──────

  @doc false
  def spy_count(%{id: user_id}) do
    send(self(), {:unread_counted, user_id})
    5
  end

  @doc false
  def raising_count(_viewer), do: raise(RuntimeError, "count exploded")

  defp use_counter(fun),
    do: Application.put_env(:platform, Push, unread_counter: {__MODULE__, fun})

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp devices!(user) do
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
      token: @apns_token,
      environment: "production",
      bundle_id: "com.kobo-ai.burrow",
      last_registered_at: DateTime.utc_now()
    })

    insert_fcm_device(user)
  end

  defp channel! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Chan #{n}", slug: "chan-#{n}", kind: "channel"})
    space
  end

  defp seat!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post_unread!(space, count) do
    author = seat!(space, insert_user("Author"))

    for i <- 1..count do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "message #{i}"
        })
    end
  end

  defp notification do
    Notification.new(%{kind: "chat_mention", title: "Dana in launch", body: "hi", url: "/chat/x"})
  end

  # ── tests ────────────────────────────────────────────────────────────────

  test "send_to_user stamps the real Chat unread total on APNs and FCM" do
    user = insert_user()
    devices!(user)
    space = channel!()
    seat!(space, user)
    post_unread!(space, 2)

    # Precondition: the number the push must carry, read the canonical way.
    assert Chat.total_unread_for_viewer(user) == 2

    before = DateTime.utc_now()
    capture_log(fn -> assert :ok = Push.send_to_user(user.id, notification()) end)

    assert_received {:apns_body, apns}
    assert apns["unread_count"] == 2
    assert {:ok, as_of, 0} = DateTime.from_iso8601(apns["unread_as_of"])
    assert DateTime.compare(as_of, before) in [:gt, :eq]

    assert_received {:fcm_send, %{body: %{"message" => %{"data" => data}}}}
    assert data["unread_count"] == "2"
    assert data["unread_as_of"] == apns["unread_as_of"]
  end

  test "a user with nothing unread gets an explicit 0, not an absent key" do
    user = insert_user()
    devices!(user)

    capture_log(fn -> Push.send_to_user(user.id, notification()) end)

    assert_received {:apns_body, apns}
    assert apns["unread_count"] == 0
    assert_received {:fcm_send, %{body: %{"message" => %{"data" => data}}}}
    assert data["unread_count"] == "0"
  end

  test "send_notification: a user row is counted and stamped, an agent row never is" do
    use_counter(:spy_count)
    user = insert_user()
    devices!(user)
    space = channel!()
    user_row = seat!(space, user)

    # An AGENT row whose participant_id equals the user's id: only the row
    # TYPE may decide.
    agent_row =
      Repo.insert!(%Participant{
        space_id: space.id,
        participant_type: "agent",
        participant_id: user.id,
        display_name: "Agent",
        joined_at: DateTime.utc_now()
      })

    capture_log(fn -> Push.send_notification(agent_row.id, notification()) end)
    refute_received {:unread_counted, _}
    refute_received {:apns_body, _}
    refute_received {:fcm_send, _}

    # Positive control, same body: the user row is counted and stamped.
    capture_log(fn -> Push.send_notification(user_row.id, notification()) end)
    user_id = user.id
    assert_received {:unread_counted, ^user_id}
    assert_received {:apns_body, %{"unread_count" => 5}}
    assert_received {:fcm_send, %{body: %{"message" => %{"data" => %{"unread_count" => "5"}}}}}
  end

  test "a raising count still delivers on both transports, without a count" do
    use_counter(:raising_count)
    user = insert_user()
    devices!(user)

    log = capture_log(fn -> assert :ok = Push.send_to_user(user.id, notification()) end)

    assert_received {:apns_body, apns}
    assert apns["aps"]["alert"]["title"] == "Dana in launch"
    refute Map.has_key?(apns, "unread_count")
    refute Map.has_key?(apns, "unread_as_of")

    assert_received {:fcm_send, %{body: %{"message" => %{"data" => data}}}}
    assert data["title"] == "Dana in launch"
    refute Map.has_key?(data, "unread_count")

    assert log =~ "unread count failed"
    refute log =~ "count exploded", "the failure is named by type, never its message"
  end
end
