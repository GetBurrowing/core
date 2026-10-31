defmodule Platform.Installs.HandoverTest do
  @moduledoc """
  Task 01a10315 stage 2: hand-over custody. The credentials are sealed at
  rest, revealed with a fresh link until acknowledged, dropped on
  acknowledgment, purged after 7 days unacknowledged, and never logged.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.InstallsFixtures

  alias Platform.Installs
  alias Platform.Installs.Fake
  alias Platform.Installs.Handover
  alias Platform.Installs.Runner
  alias Platform.Repo

  setup do
    use_fake_backend()
    :ok
  end

  defp ready_install! do
    {install, _} = create_install!()
    assert Runner.run(install.id) == :ready
    Installs.get(install.id)
  end

  defp raw_sealed(install) do
    %{rows: [[raw]]} =
      Repo.query!("SELECT handover_sealed FROM installs WHERE id = $1", [
        Ecto.UUID.dump!(install.id)
      ])

    raw
  end

  defp age!(install, days) do
    then = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)
    Installs.update!(install, %{ready_at: then})
  end

  test "reveal works before acknowledgment and fails after; sealed is nil after" do
    install = ready_install!()

    assert {:ok, handover} = Installs.reveal_handover(install)
    assert handover.burrow_url == "https://#{install.primary_host}"
    assert handover.admin_email == install.owner_email
    assert handover.sign_in_link ==
             "https://#{install.primary_host}/auth/handover?code=FAKECODE"
    assert handover.ssh.host == install.droplet_ip
    assert handover.ssh.user == "root"
    assert handover.ssh.private_key =~ "-----BEGIN OPENSSH PRIVATE KEY-----"

    # Each reveal mints again; nothing from it is stored.
    assert {:ok, _} = Installs.reveal_handover(install)
    refute raw_sealed(install) =~ "FAKECODE"

    assert {:ok, acked} = Installs.acknowledge_handover(install)
    assert acked.handover_acknowledged_at
    assert Installs.get(install.id).handover_sealed == nil
    assert raw_sealed(install) == nil
    assert {:error, :already_handed_over} = Installs.reveal_handover(install)
    assert {:ok, _} = Installs.acknowledge_handover(install)
  end

  test "an install that is not ready has nothing to reveal or acknowledge" do
    {install, _} = create_install!()
    assert {:error, :not_ready} = Installs.reveal_handover(install)
    assert {:error, :not_ready} = Installs.acknowledge_handover(install)
  end

  test "the raw column is ciphertext, not the key or the API key" do
    install = ready_install!()
    {:ok, sealed} = Installs.unseal(install)
    raw = raw_sealed(install)

    assert is_binary(raw) and byte_size(raw) > 0
    refute raw =~ "OPENSSH"
    refute raw =~ "ssh_private_key"
    refute raw =~ Handover.fetch(sealed, "static_api_key")
    refute raw =~ Handover.fetch(sealed, "oidc_client_secret")
  end

  test "no key material reaches the log, at any level" do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        {install, _} = create_install!()
        Fake.inject_failure("install", 1)
        assert Runner.run(install.id) == :failed
        {:ok, _} = Installs.retry(Installs.get(install.id), admin!())
        assert Runner.run(install.id) == :ready
        send(self(), {:sealed, Installs.unseal(Installs.get(install.id))})
        {:ok, _} = Installs.reveal_handover(Installs.get(install.id))
        {:ok, _} = Installs.acknowledge_handover(Installs.get(install.id))
      end)

    assert_received {:sealed, {:ok, sealed}}
    private_body = Handover.fetch(sealed, "ssh_private_key") |> String.split("\n") |> Enum.at(1)

    # Positive control: the log was captured at debug and is not empty.
    assert log =~ "[installs]"
    refute log =~ private_body
    refute log =~ "OPENSSH"
    refute log =~ Handover.fetch(sealed, "static_api_key")
    refute log =~ Handover.fetch(sealed, "oidc_client_secret")
    refute log =~ "FAKECODE"
  end

  describe "expiry" do
    test "a hand-over unacknowledged for 7 days is purged by the sweep" do
      old = ready_install!() |> age!(8)
      fresh = ready_install!() |> age!(6)

      assert Installs.expire_handovers() == 1

      old = Installs.get(old.id)
      assert old.handover_sealed == nil
      assert old.handover_expired_at
      assert raw_sealed(old) == nil
      assert {:error, :handover_expired} = Installs.reveal_handover(old)

      assert Installs.get(fresh.id).handover_sealed
      assert {:ok, _} = Installs.reveal_handover(fresh)
      assert Installs.expire_handovers() == 0
    end

    test "reveal expires a due hand-over itself, without waiting for the sweep" do
      install = ready_install!() |> age!(8)

      assert {:error, :handover_expired} = Installs.reveal_handover(install)
      assert Installs.get(install.id).handover_sealed == nil
    end

    test "an acknowledged hand-over is never 'expired'" do
      install = ready_install!()
      {:ok, _} = Installs.acknowledge_handover(install)
      Installs.get(install.id) |> age!(30)

      assert Installs.expire_handovers() == 0
      assert Installs.get(install.id).handover_expired_at == nil
      assert {:error, :already_handed_over} = Installs.reveal_handover(install)
    end

    test "the sweeper purges at start and then on its interval" do
      install = ready_install!() |> age!(8)
      start_supervised!({Platform.Installs.Sweeper, interval_ms: 60_000})

      wait_until(fn -> Installs.get(install.id).handover_sealed == nil end)
      assert Installs.get(install.id).handover_expired_at
    end
  end

  describe "the decrypted hand-over is never printable (stage 6 round 2)" do
    # The secret strings of a real (fake-backend) install, read through the
    # one accessor, so each refute below has a demonstrated positive: the
    # value exists and is non-empty.
    defp secrets_of(install) do
      {:ok, sealed} = Installs.unseal(install)
      values = for key <- ~w(ssh_private_key static_api_key oidc_client_secret), do: Handover.fetch(sealed, key)
      assert Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 8))
      # The key's base64 body, not just its armour.
      [Enum.at(String.split(hd(values), "\n"), 1) | values]
    end

    defp refute_holds(text, secrets) do
      for secret <- secrets, do: refute(String.contains?(text, secret))
    end

    test "inspect/1 of a loaded install, its hand-over and its map form hold no secret" do
      install = ready_install!()
      secrets = secrets_of(install)

      assert inspect(install.handover_sealed) == "#Handover<redacted>"

      for text <- [
            inspect(install),
            inspect(install, structs: false),
            inspect(install.handover_sealed, structs: false),
            inspect(Map.from_struct(install)),
            inspect(Installs.unseal(install)),
            inspect(Ecto.Changeset.change(install, %{handover_sealed: install.handover_sealed}))
          ] do
        refute_holds(text, secrets)
      end

      # Positive control: the same strings ARE found by the same check.
      assert String.contains?(Handover.to_json(install.handover_sealed), hd(secrets))
    end

    test "an exception raised with the install in scope holds no secret" do
      install = ready_install!()
      secrets = secrets_of(install)

      {kind, error, stack} =
        try do
          # A match failure prints the unsealed result it could not match.
          {:error, _} = Installs.unseal(install)
        catch
          kind, error -> {kind, error, __STACKTRACE__}
        end

      formatted = Exception.format(kind, error, stack)
      assert formatted =~ "Handover<redacted>"
      refute_holds(formatted, secrets)

      # A key error and a function clause error whose arguments carry the
      # hand-over, formatted with blame (as a crash report formats them).
      for fun <- [
            fn -> Map.fetch!(install.handover_sealed, :nope) end,
            fn -> Handover.fetch(install.handover_sealed, :not_a_string_key) end
          ] do
        formatted =
          try do
            fun.()
          rescue
            error ->
              {error, stack} = Exception.blame(:error, error, __STACKTRACE__)
              Exception.format(:error, error, stack)
          end

        assert formatted =~ "Handover<redacted>"
        refute_holds(formatted, secrets)
      end
    end
  end
end
