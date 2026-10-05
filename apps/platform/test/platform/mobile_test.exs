defmodule Platform.MobileTest do
  @moduledoc """
  Task 01a10882 stage 1: app sessions, login codes, APNs devices and counts.
  """
  # async: false: the log test raises the global Logger level.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.ExternalUserFixtures, only: [create_user!: 0]

  alias Platform.Accounts
  alias Platform.Inbox
  alias Platform.Mobile
  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.AppLoginCode
  alias Platform.Mobile.AppSession
  alias Platform.Tasks.Task

  @device_token String.duplicate("5e17", 16)

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp signed_in(user \\ create_user!()) do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)

    {:ok, result} =
      Mobile.exchange_code(code, verifier, %{app_install_id: "install-1", device_name: "Phone"})

    {user, result}
  end

  describe "begin_app_login/1" do
    test "accepts an S256 challenge and refuses anything else" do
      {_verifier, challenge} = pkce()
      assert {:ok, ^challenge} = Mobile.begin_app_login(challenge)
      assert {:error, :invalid_challenge} = Mobile.begin_app_login("short")
      assert {:error, :invalid_challenge} = Mobile.begin_app_login(nil)
      assert {:error, :invalid_challenge} = Mobile.begin_app_login(challenge <> "=")
    end
  end

  describe "exchange_code/3" do
    test "returns a bearer once, stores only its hash, and the bearer verifies" do
      {user, %{token: token, session: session, handoff_code: handoff}} = signed_in()

      assert byte_size(token) >= 43
      assert is_binary(handoff)

      row = Repo.get!(AppSession, session.id)
      assert row.token_hash == :crypto.hash(:sha256, token)
      refute row.token_hash == token
      refute inspect(row) =~ token
      assert row.app_install_id == "install-1"

      raw_rows =
        Repo.query!("SELECT token_hash FROM app_sessions WHERE id = $1", [
          Ecto.UUID.dump!(session.id)
        ])

      refute Enum.any?(raw_rows.rows, fn [hash] -> hash == token end)

      assert {:ok, %{id: user_id}, %AppSession{id: session_id}} = Mobile.verify_bearer(token)
      assert user_id == user.id
      assert session_id == session.id
    end

    test "login codes are stored only as hashes" do
      user = create_user!()
      {_verifier, challenge} = pkce()
      {:ok, code} = Mobile.issue_exchange_code(user, challenge)

      [row] = Repo.all(from(c in AppLoginCode, where: c.user_id == ^user.id))
      assert row.code_hash == :crypto.hash(:sha256, code)
      refute inspect(row) =~ code
      assert row.purpose == "exchange"
      assert row.code_challenge == challenge
    end

    test "a wrong code_verifier is rejected and burns the code" do
      user = create_user!()
      {verifier, challenge} = pkce()
      {wrong, _} = pkce()
      {:ok, code} = Mobile.issue_exchange_code(user, challenge)

      assert {:error, :invalid_code} = Mobile.exchange_code(code, wrong)
      assert {:error, :invalid_code} = Mobile.exchange_code(code, verifier)
      assert Repo.aggregate(AppSession, :count) == 0
    end

    test "a reused code is rejected" do
      user = create_user!()
      {verifier, challenge} = pkce()
      {:ok, code} = Mobile.issue_exchange_code(user, challenge)

      assert {:ok, _} = Mobile.exchange_code(code, verifier)
      assert {:error, :invalid_code} = Mobile.exchange_code(code, verifier)
    end

    test "an expired code is rejected" do
      user = create_user!()
      {verifier, challenge} = pkce()
      {:ok, code} = Mobile.issue_exchange_code(user, challenge)

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      Repo.update_all(from(c in AppLoginCode, where: c.user_id == ^user.id),
        set: [expires_at: past]
      )

      assert {:error, :invalid_code} = Mobile.exchange_code(code, verifier)
    end

    test "codes expire after 60 seconds" do
      user = create_user!()
      {_verifier, challenge} = pkce()
      before = DateTime.utc_now()
      {:ok, _code} = Mobile.issue_exchange_code(user, challenge)

      [row] = Repo.all(from(c in AppLoginCode, where: c.user_id == ^user.id))
      assert DateTime.diff(row.expires_at, before, :second) in 59..60
    end

    test "a handoff code cannot be redeemed as an exchange code, and vice versa" do
      {_user, %{handoff_code: handoff}} = signed_in()
      {verifier, _} = pkce()
      assert {:error, :invalid_code} = Mobile.exchange_code(handoff, verifier)

      user = create_user!()
      {_v, challenge} = pkce()
      {:ok, exchange} = Mobile.issue_exchange_code(user, challenge)
      assert {:error, :invalid_code} = Mobile.consume_handoff_code(exchange)
    end

    test "an archived user cannot exchange a code" do
      user = create_user!()
      {verifier, challenge} = pkce()
      {:ok, code} = Mobile.issue_exchange_code(user, challenge)
      {:ok, _} = Accounts.archive_user(user)

      assert {:error, :invalid_code} = Mobile.exchange_code(code, verifier)
    end

    test "garbage input is rejected" do
      assert {:error, :invalid_code} = Mobile.exchange_code(nil, nil)
      assert {:error, :invalid_code} = Mobile.exchange_code("", "")
      assert {:error, :invalid_code} = Mobile.exchange_code("nope", String.duplicate("a", 43))
    end
  end

  describe "consume_handoff_code/1" do
    test "is single use" do
      {user, %{handoff_code: handoff}} = signed_in()
      assert {:ok, %{id: id}} = Mobile.consume_handoff_code(handoff)
      assert id == user.id
      assert {:error, :invalid_code} = Mobile.consume_handoff_code(handoff)
    end
  end

  describe "issue_handoff_code/1" do
    test "mints a single-use handoff code for the session's user" do
      {user, %{session: session}} = signed_in()
      assert {:ok, code} = Mobile.issue_handoff_code(session)
      assert {:ok, %{id: id}} = Mobile.consume_handoff_code(code)
      assert id == user.id
      assert {:error, :invalid_code} = Mobile.consume_handoff_code(code)
    end

    test "is stored only as a hash, with the 60-second expiry" do
      {_user, %{session: session}} = signed_in()
      before = DateTime.utc_now()
      {:ok, code} = Mobile.issue_handoff_code(session)
      row = Repo.get_by!(AppLoginCode, code_hash: Mobile.hash(code))
      assert row.purpose == "handoff"
      # expires_at and inserted_at are truncated to the second separately,
      # so their difference is 59 when a second boundary falls between them.
      assert DateTime.diff(row.expires_at, before, :second) in 59..60
      refute Repo.get_by(AppLoginCode, code_hash: code)
    end
  end

  describe "safe_return_path/1" do
    test "keeps a local path and refuses everything else" do
      assert Mobile.safe_return_path("/chat/design") == "/chat/design"
      assert Mobile.safe_return_path("/tasks/t1?tab=plan") == "/tasks/t1?tab=plan"

      for bad <- [
            nil,
            "",
            "chat",
            "//evil.example",
            "/\\evil.example",
            "/a\\b",
            "https://evil.example/x",
            "/auth/logout",
            "/x\r\nSet-Cookie: a=b",
            123
          ] do
        assert Mobile.safe_return_path(bad) == "/", inspect(bad)
      end
    end
  end

  describe "verify_bearer/1" do
    test "refuses garbage, revoked sessions and archived users" do
      assert :error = Mobile.verify_bearer("garbage")
      assert :error = Mobile.verify_bearer("")
      assert :error = Mobile.verify_bearer(nil)

      {_user, %{token: token, session: session}} = signed_in()
      {:ok, _} = Mobile.revoke_session(session)
      assert :error = Mobile.verify_bearer(token)

      {user, %{token: token2}} = signed_in()
      {:ok, _} = Accounts.archive_user(user)
      assert :error = Mobile.verify_bearer(token2)
    end
  end

  describe "touch_session/1" do
    test "bumps last_used_at at most once a minute" do
      {_user, %{session: session}} = signed_in()
      recent = DateTime.add(DateTime.utc_now(), -10, :second)
      old = DateTime.add(DateTime.utc_now(), -120, :second)

      Repo.update_all(from(s in AppSession, where: s.id == ^session.id),
        set: [last_used_at: recent]
      )

      :ok = Mobile.touch_session(session)
      assert Repo.get!(AppSession, session.id).last_used_at == recent

      Repo.update_all(from(s in AppSession, where: s.id == ^session.id), set: [last_used_at: old])
      :ok = Mobile.touch_session(session)
      assert DateTime.compare(Repo.get!(AppSession, session.id).last_used_at, old) == :gt
    end
  end

  describe "devices" do
    defp device_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          "token" => @device_token,
          "environment" => "sandbox",
          "bundle_id" => "com.kobo-ai.burrow",
          "app_install_id" => "install-1"
        },
        overrides
      )
    end

    test "inspect of a device struct never shows the token" do
      refute inspect(%ApnsDevice{token: "tok-SENTINEL"}) =~ "tok-SENTINEL"

      changeset = ApnsDevice.changeset(%ApnsDevice{}, %{token: "tok-SENTINEL"})
      refute inspect(changeset) =~ "tok-SENTINEL"
    end

    test "register upserts on token and never duplicates it" do
      {user, %{session: session}} = signed_in()

      assert {:ok, d1} = Mobile.register_device(session, device_attrs())

      assert {:ok, d2} =
               Mobile.register_device(session, device_attrs(%{"environment" => "production"}))

      assert d1.id == d2.id
      assert [%ApnsDevice{environment: "production"}] = Mobile.list_devices(user)
    end

    test "a token that moves to another user is reassigned, not duplicated" do
      {user_a, %{session: session_a}} = signed_in()
      {user_b, %{session: session_b}} = signed_in()

      {:ok, _} = Mobile.register_device(session_a, device_attrs())
      {:ok, _} = Mobile.register_device(session_b, device_attrs())

      assert Mobile.list_devices(user_a) == []
      assert [%ApnsDevice{app_session_id: sid}] = Mobile.list_devices(user_b)
      assert sid == session_b.id
      assert Repo.aggregate(ApnsDevice, :count) == 1
    end

    test "a new token for the same install replaces the old one" do
      {user, %{session: session}} = signed_in()
      {:ok, _} = Mobile.register_device(session, device_attrs())

      {:ok, _} =
        Mobile.register_device(session, device_attrs(%{"token" => String.duplicate("ab", 32)}))

      assert [%ApnsDevice{token: token}] = Mobile.list_devices(user)
      assert token == String.duplicate("ab", 32)
    end

    test "invalid environment is refused" do
      {_user, %{session: session}} = signed_in()

      assert {:error, %Ecto.Changeset{}} =
               Mobile.register_device(session, device_attrs(%{"environment" => "voip"}))
    end

    test "unregister removes the install's device; revoke removes the session's devices" do
      {user, %{session: session}} = signed_in()
      {:ok, _} = Mobile.register_device(session, device_attrs())
      :ok = Mobile.unregister_device(user, "install-1")
      assert Mobile.list_devices(user) == []

      {:ok, _} = Mobile.register_device(session, device_attrs())
      {:ok, revoked} = Mobile.revoke_session(session)
      assert revoked.revoked_at
      assert Mobile.list_devices(user) == []
    end
  end

  describe "counts_for_user/1" do
    test "counts approval inbox kinds and the user's open assigned tasks" do
      user = create_user!()
      other = create_user!()

      for kind <- ~w(task_plan_review review_request_pending chat_mention) do
        {:ok, _} =
          Inbox.emit(%{
            user_id: user.id,
            kind: kind,
            source_type: if(kind == "chat_mention", do: "chat_message", else: "task"),
            source_id: Ecto.UUID.generate(),
            title: "t",
            body: "b",
            url: "/inbox"
          })
      end

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Mobile Counts #{System.unique_integer([:positive])}"
        })

      for {status, assignee} <- [
            {"in_progress", user},
            {"backlog", user},
            {"done", user},
            {"cancelled", user},
            {"in_progress", other}
          ] do
        Repo.insert!(%Task{
          project_id: project.id,
          title: "T #{status}",
          status: status,
          assignee_type: "user",
          assignee_id: assignee.id
        })
      end

      assert %{approvals: 2, tasks: 2, as_of: %DateTime{}} = Mobile.counts_for_user(user)
    end
  end

  describe "secrets never reach the log" do
    test "exchange, verify and register log neither the bearer nor the device token" do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      {bearer, log} =
        with_log([level: :debug], fn ->
          {_user, %{token: token, session: session}} = signed_in()
          {:ok, _} = Mobile.register_device(session, device_attrs())
          _ = Mobile.verify_bearer(token)
          _ = Mobile.verify_bearer("not-a-real-token")
          token
        end)

      refute log =~ bearer
      refute log =~ @device_token
    end
  end
end
