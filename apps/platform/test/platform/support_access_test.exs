defmodule Platform.SupportAccessTest do
  # Not async: the support access config is global application env.
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SupportAccessFixtures

  alias Platform.Accounts
  alias Platform.Audit.Event
  alias Platform.Repo
  alias Platform.SupportAccess
  alias Platform.SupportAccess.Config
  alias Platform.SupportAccess.Session
  alias Platform.SupportAccess.Settings
  alias Platform.SupportAccess.ShellEvents
  alias Platform.SupportAccess.StateFile
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  setup ctx do
    ctx = setup_support_access(ctx)
    set_enabled!(true)
    ctx
  end

  defp events(type) do
    Repo.all(from(e in Event, where: e.event_type == ^type, order_by: [asc: e.id]))
  end

  defp grant!(ctx, overrides \\ %{}) do
    {raw, headers} = sign(grant_body(overrides), ctx)
    {:ok, response} = SupportAccess.request_grant(raw, headers)
    response
  end

  defp request(ctx, overrides, opts \\ []) do
    {raw, headers} = sign(grant_body(overrides), ctx, opts)
    SupportAccess.request_grant(raw, headers)
  end

  describe "Config" do
    test "parse_keys reads kid:base64 pairs and drops malformed ones" do
      {pub1, _} = :crypto.generate_key(:eddsa, :ed25519)
      {pub2, _} = :crypto.generate_key(:eddsa, :ed25519)

      raw =
        "a:#{Base.encode64(pub1)}, b:#{Base.url_encode64(pub2, padding: false)},bad,c:AAAA"

      assert Config.parse_keys(raw) == %{"a" => pub1, "b" => pub2}
      assert Config.parse_keys(nil) == %{}
    end
  end

  describe "Settings" do
    test "the migration seeds the switch OFF when SUPPORT_ACCESS_DEFAULT is not 'on'" do
      # The test database is migrated without SUPPORT_ACCESS_DEFAULT, so the
      # seeded row is off; the setup above flipped it for the other tests.
      source = File.read!("priv/repo/migrations/20261107010000_create_support_access.exs")
      assert source =~ ~s|System.get_env("SUPPORT_ACCESS_DEFAULT") == "on"|
      refute System.get_env("SUPPORT_ACCESS_DEFAULT") == "on"

      %{rows: [[seeded]]} =
        Repo.query!("SELECT column_default FROM information_schema.columns
          WHERE table_name = 'install_support_access_settings' AND column_name = 'enabled'")

      assert seeded == "false"
    end

    test "update/2 refuses a non-admin and a vendor support user" do
      member = Platform.Repo.insert!(%Accounts.User{email: "m@acme.test", name: "M", oidc_sub: "m-1"})
      assert {:error, :unauthorized} = Settings.update(member, %{enabled: false})
      assert {:error, :unauthorized} = Settings.update(nil, %{enabled: false})

      %Accounts.User{} = admin = TenancyFixtures.root_admin!()
      support = %{admin | support_vendor: true}
      assert {:error, :unauthorized} = Settings.update(support, %{enabled: false})
      assert Settings.enabled?()
    end

    test "toggling writes support.access_changed with actor, from and to", ctx do
      admin = TenancyFixtures.root_admin!()
      assert {:ok, %Settings{enabled: false}} = Settings.update(admin, %{enabled: false})

      [event] = events("support.access_changed")
      assert event.actor_id == admin.id
      assert event.metadata["from"] == true
      assert event.metadata["to"] == false
      assert Settings.get().updated_by_user_id == admin.id
      assert %{"enabled" => false} = state(ctx)
    end

    test "toggle-off with a live admin session and a repair session ends both, " <>
           "and the state file shows enabled:false and no repair sessions",
         ctx do
      admin_resp = grant!(ctx)
      repair_resp = grant!(ctx, %{"kind" => "repair"})
      assert [%{"id" => repair_id}] = state(ctx)["repair_sessions"]
      assert repair_id == repair_resp.session_id

      PlatformWeb.Endpoint.subscribe(SupportAccess.live_socket_id(admin_resp.session_id))

      owner = TenancyFixtures.root_admin!()
      assert {:ok, _} = Settings.update(owner, %{enabled: false})

      for id <- [admin_resp.session_id, repair_resp.session_id] do
        session = Repo.get!(Session, id)
        assert session.ended_at
        assert session.end_reason == "access_turned_off"
      end

      assert %{"enabled" => false, "repair_sessions" => []} = state(ctx)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      support_user = Repo.get_by!(Accounts.User, email: "pat.operator@support.test")
      assert support_user.archived_at
      refute Tenancy.root_admin?(support_user)
    end

    test "a failed state file write still commits the toggle and is recorded", ctx do
      Application.put_env(
        :platform,
        :support_access,
        Keyword.put(Application.get_env(:platform, :support_access), :state_path, "/nonexistent-dir/x/state.json")
      )

      owner = TenancyFixtures.root_admin!()
      assert {:ok, settings} = Settings.update(owner, %{enabled: false})
      refute settings.enabled
      assert settings.state_file_error =~ "nonexistent-dir"

      # The sweeper's retry clears the error once the path is writable again.
      Application.put_env(
        :platform,
        :support_access,
        Keyword.put(Application.get_env(:platform, :support_access), :state_path, ctx.state_path)
      )

      :ok = SupportAccess.sweep()
      assert Settings.get().state_file_error == nil
      assert %{"enabled" => false} = state(ctx)
    end
  end

  describe "grant refusals, in order" do
    test "no keys configured: :not_found", ctx do
      Application.put_env(
        :platform,
        :support_access,
        Keyword.put(Application.get_env(:platform, :support_access), :vendor_keys, %{})
      )

      assert {:error, :not_found} = request(ctx, %{})
      assert events("support.grant_requested") == []
    end

    test "bad signature: :bad_signature, and nothing is audited", ctx do
      {_pub, other} = :crypto.generate_key(:eddsa, :ed25519)
      assert {:error, :bad_signature} = request(ctx, %{}, key: other)

      {raw, headers} = sign(grant_body(), ctx)
      tampered = String.replace(raw, "Pat Operator", "Pat Operatos")
      assert {:error, :bad_signature} = SupportAccess.request_grant(tampered, headers)

      assert events("support.grant_requested") == []
      assert events("support.grant_refused") == []
    end

    test "unknown kid: :bad_signature", ctx do
      assert {:error, :bad_signature} = request(ctx, %{"kid" => "not-a-configured-kid"})
    end

    test "wrong install id with a valid signature: :wrong_install, audited", ctx do
      assert {:error, :wrong_install} =
               request(ctx, %{"install_id" => "99999999-2222-4333-8444-555555555555"})

      assert [_] = events("support.grant_requested")
      assert [refused] = events("support.grant_refused")
      assert refused.metadata["reason"] == "wrong_install"
    end

    test "expired, or valid for more than 300 s: :grant_expired", ctx do
      now = System.os_time(:second)

      assert {:error, :grant_expired} =
               request(ctx, %{"issued_at" => now - 200, "expires_at" => now - 1})

      assert {:error, :grant_expired} =
               request(ctx, %{"issued_at" => now, "expires_at" => now + 301})
    end

    test "replay of a used nonce: :replayed_nonce", ctx do
      {raw, headers} = sign(grant_body(%{"kind" => "repair"}), ctx)
      assert {:ok, _} = SupportAccess.request_grant(raw, headers)
      assert {:error, :replayed_nonce} = SupportAccess.request_grant(raw, headers)

      assert Enum.map(events("support.grant_refused"), & &1.metadata["reason"]) == [
               "replayed_nonce"
             ]
    end

    test "duration over the 4 h cap: :duration_too_long", ctx do
      assert {:error, :duration_too_long} = request(ctx, %{"duration_s" => 14_401})
      assert {:ok, _} = request(ctx, %{"duration_s" => 14_400, "kind" => "repair"})
    end

    test "off means off: switch off refuses with :support_access_off", ctx do
      set_enabled!(false)
      assert {:error, :support_access_off} = request(ctx, %{})
      assert {:error, :support_access_off} = request(ctx, %{"kind" => "repair"})
      assert Repo.aggregate(Session, :count) == 0

      reasons = Enum.map(events("support.grant_refused"), & &1.metadata["reason"])
      assert reasons == ["support_access_off", "support_access_off"]
    end

    test "a real user's email is never taken over", ctx do
      Repo.insert!(%Accounts.User{email: "owner@support.test", name: "Owner", oidc_sub: "o-1"})

      assert {:error, :operator_email_taken} =
               request(ctx, %{"operator" => %{"name" => "X", "email" => "owner@support.test"}})
    end
  end

  describe "grants" do
    test "an admin grant creates one support user, admin only for the session", ctx do
      resp = grant!(ctx)
      assert resp.sign_in_url =~ "/auth/support?code="
      user = Repo.get_by!(Accounts.User, email: "pat.operator@support.test")
      assert user.support_vendor
      assert Tenancy.root_admin?(user)
      assert user.name =~ "(vendor support)"
      refute Enum.any?(Accounts.install_admins(), &(&1.id == user.id))

      # The audit rows never carry the code or the URL.
      [code] = Regex.run(~r/code=(.+)$/, resp.sign_in_url, capture: :all_but_first)
      dump = Repo.all(Event) |> Enum.map_join(" ", &Jason.encode!(&1.metadata))
      refute dump =~ code

      # A second grant for the same operator reuses (and unarchives) the user.
      SupportAccess.end_expired(DateTime.add(DateTime.utc_now(), 7200, :second))
      assert Repo.get!(Accounts.User, user.id).archived_at
      grant!(ctx)
      again = Repo.get!(Accounts.User, user.id)
      assert again.archived_at == nil
      assert Repo.aggregate(from(u in Accounts.User, where: u.support_vendor), :count) == 1
    end

    test "the sign-in code is single use and expires after 60 s", ctx do
      resp = grant!(ctx)
      [code] = Regex.run(~r/code=(.+)$/, resp.sign_in_url, capture: :all_but_first)

      later = DateTime.add(DateTime.utc_now(), 61, :second)
      assert {:error, :invalid_code} = SupportAccess.consume_sign_in_code(code, later)
      assert {:ok, user, session} = SupportAccess.consume_sign_in_code(code)
      assert user.support_vendor
      assert session.id == resp.session_id
      assert {:error, :invalid_code} = SupportAccess.consume_sign_in_code(code)
      assert {:error, :invalid_code} = SupportAccess.consume_sign_in_code("nope")
    end

    test "a repair grant writes the state file", ctx do
      resp = grant!(ctx, %{"kind" => "repair", "duration_s" => 600})
      assert resp.principal == "support-" <> install_id()

      assert %{
               "version" => 1,
               "enabled" => true,
               "principal" => principal,
               "repair_sessions" => [%{"id" => id, "not_after" => not_after}]
             } = state(ctx)

      assert principal == "support-" <> install_id()
      assert id == resp.session_id
      assert {:ok, _, _} = DateTime.from_iso8601(not_after)
      refute File.read!(ctx.state_path) =~ ctx.kid

      # An expired repair session drops out on the next sweep.
      SupportAccess.sweep(DateTime.add(DateTime.utc_now(), 601, :second))
      assert %{"repair_sessions" => []} = state(ctx)
      assert Repo.get!(Session, id).end_reason == "expired"
    end

    test "end_session/2 is the owner's, and ends with ended_by_owner", ctx do
      resp = grant!(ctx, %{"kind" => "repair"})
      owner = TenancyFixtures.root_admin!()
      assert {:error, :unauthorized} = SupportAccess.end_session(nil, resp.session_id)
      assert {:ok, ended} = SupportAccess.end_session(owner, resp.session_id)
      assert ended.end_reason == "ended_by_owner"
      assert {:error, :already_ended} = SupportAccess.end_session(owner, resp.session_id)
      assert %{"repair_sessions" => []} = state(ctx)
      assert [ev] = events("support.session_ended")
      assert ev.actor_id == owner.id
    end

    test "StateFile.document/1 lists no repair session while off", ctx do
      grant!(ctx, %{"kind" => "repair"})
      set_enabled!(false)
      assert %{"enabled" => false, "repair_sessions" => []} = StateFile.document()
    end
  end

  describe "shell event ingest" do
    test "writes one audit row per complete line and persists the offset", ctx do
      %{session_id: sid} = grant!(ctx, %{"kind" => "repair"})
      long = String.duplicate("x", 600)

      File.write!(ctx.events_path, [
        Jason.encode!(%{event: "shell_opened", session_id: sid, ts: "2026-11-07T00:00:00Z"}),
        "\n",
        Jason.encode!(%{event: "shell_command", session_id: sid, command: long}),
        "\n",
        Jason.encode!(%{event: "shell_command", session_id: Ecto.UUID.generate(), command: "ls"}),
        "\n",
        "not json\n",
        Jason.encode!(%{event: "shell_closed", session_id: sid}),
        "\n",
        ~s|{"event":"shell_opened","session_id":"partial|
      ])

      assert ShellEvents.ingest() == 5
      assert [opened] = events("support.shell_opened")
      assert opened.resource_id == sid
      assert opened.metadata["support_session_id"] == sid
      assert [command] = events("support.shell_command")
      assert String.length(command.metadata["command"]) == 500
      assert [_] = events("support.shell_closed")
      assert length(events("support.shell_unmatched")) == 2
      refute Enum.any?(events("support.shell_unmatched"), &Map.has_key?(&1.metadata, "command"))

      # Nothing new: nothing re-ingested. The partial line completes later.
      assert ShellEvents.ingest() == 0
      File.write!(ctx.events_path, ~s|"}\n|, [:append])
      assert ShellEvents.ingest() == 1
      assert length(events("support.shell_unmatched")) == 3
    end
  end

  describe "audit" do
    test "support.action carries a params hash and never the values", ctx do
      grant!(ctx)
      user = Repo.get_by!(Accounts.User, email: "pat.operator@support.test")
      params = %{"password" => "hunter2-secret-value", "nested" => %{"token" => "tok-secret"}}

      :ok =
        SupportAccess.record_action(user, "sid", %{kind: "http", route: "/x", params: params})

      [action] = events("support.action")
      assert action.metadata["params_sha256"] == SupportAccess.params_hash(params)
      assert byte_size(action.metadata["params_sha256"]) == 64
      encoded = inspect(action, limit: :infinity, printable_limit: :infinity)
      refute encoded =~ "hunter2-secret-value"
      refute encoded =~ "tok-secret"
      refute Map.has_key?(action.metadata, "params")
    end

    test "support rows are hash-chained and an edit breaks the chain", ctx do
      grant!(ctx, %{"kind" => "repair"})
      grant!(ctx)
      assert :ok = SupportAccess.verify_audit_chain()

      [first | _] = Repo.all(from(e in Event, where: like(e.event_type, "support.%"), order_by: [asc: e.id]))

      Repo.query!("UPDATE audit_events SET metadata = jsonb_set(metadata, '{kind}', '\"admin\"') WHERE id = $1", [
        first.id
      ])

      assert {:error, {:broken_at, id}} = SupportAccess.verify_audit_chain()
      assert id == first.id
    end
  end
end
