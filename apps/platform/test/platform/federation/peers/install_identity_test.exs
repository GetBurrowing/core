defmodule Platform.Federation.Peers.InstallIdentityTest do
  @moduledoc """
  Task 01a0d90f stage 2 (ADR 0054 section 1): the install identity, its
  Vault-held private key, rotation, and the promise that private-key bytes
  reach neither the descriptor nor the logs.
  """

  # async: false — ensure!/rotate! take a transaction-scoped advisory lock,
  # which inside the sandbox is held until the test's transaction ends, and
  # the log-capture describe lowers the global Logger level.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.InstallKey
  alias Platform.Repo
  alias Platform.Vault

  defp private_key!(kid) do
    {:ok, priv} = Vault.get(InstallIdentity.vault_slug(kid), accessor: {:system, nil})
    priv
  end

  # Every textual form a 32-byte private key could take in a log line or a
  # JSON document, plus the raw bytes themselves.
  defp encodings(priv) do
    [
      priv,
      Base.encode64(priv),
      Base.encode64(priv, padding: false),
      Base.url_encode64(priv),
      Base.url_encode64(priv, padding: false),
      Base.encode16(priv, case: :lower),
      Base.encode16(priv, case: :upper),
      inspect(priv)
    ]
  end

  defp refute_contains_key(haystack, priv) do
    for form <- encodings(priv) do
      refute String.contains?(haystack, form),
             "found a private-key encoding in the output (form length #{byte_size(form)})"
    end
  end

  describe "ensure!/0" do
    test "creates the identity once and reuses it" do
      assert InstallIdentity.current() == nil

      first = InstallIdentity.ensure!()
      second = InstallIdentity.ensure!()

      assert first == second
      assert {:ok, _} = Ecto.UUID.cast(first.install_id)
      assert Repo.aggregate(InstallKey, :count) == 1
      assert InstallIdentity.current() == first
    end

    test "the Vault holds the private key, and it matches the advertised public key" do
      %{kid: kid, public_key: pub} = InstallIdentity.ensure!()

      priv = private_key!(kid)
      assert byte_size(priv) == 32
      assert {^pub, ^priv} = :crypto.generate_key(:eddsa, :ed25519, priv)

      key = Repo.get_by!(InstallKey, kid: kid)
      assert key.vault_slug == "peer-federation-key-" <> kid
      assert key.status == "current"
      refute key.public_key == priv
    end

    test "sign/1 signs with the current key" do
      %{kid: kid, public_key: pub} = InstallIdentity.ensure!()

      assert {:ok, %{kid: ^kid, signature: signature}} = InstallIdentity.sign("payload")
      assert Ed25519.verify("payload", signature, pub)
    end

    test "sign/1 without an identity is an error, not a crash" do
      assert {:error, :no_install_identity} = InstallIdentity.sign("payload")
    end
  end

  describe "rotate!/0" do
    test "the new kid becomes current and the old one previous for 7 days" do
      old = InstallIdentity.ensure!()
      new = InstallIdentity.rotate!()

      refute new.kid == old.kid
      assert new.install_id == old.install_id

      old_key = Repo.get_by!(InstallKey, kid: old.kid)
      assert old_key.status == "previous"

      overlap = DateTime.diff(old_key.valid_until, DateTime.utc_now(), :second)
      assert overlap > InstallIdentity.overlap_seconds() - 60
      assert overlap <= InstallIdentity.overlap_seconds()

      assert {:ok, %{kid: kid}} = InstallIdentity.sign("x")
      assert kid == new.kid

      # Both private keys are still in the Vault during the overlap.
      assert byte_size(private_key!(old.kid)) == 32
      assert byte_size(private_key!(new.kid)) == 32
    end

    test "the rotated descriptor lists both kids" do
      old = InstallIdentity.ensure!()
      new = InstallIdentity.rotate!()

      keys = InstallIdentity.descriptor().keys
      assert Enum.map(keys, & &1.kid) == [new.kid, old.kid]
      assert Enum.map(keys, & &1.status) == ["current", "previous"]
    end

    test "a previous key past its overlap is retired and its private key deleted" do
      old = InstallIdentity.ensure!()
      new = InstallIdentity.rotate!()

      Repo.get_by!(InstallKey, kid: old.kid)
      |> InstallKey.changeset(%{valid_until: DateTime.add(DateTime.utc_now(), -1, :second)})
      |> Repo.update!()

      assert Enum.map(InstallIdentity.descriptor().keys, & &1.kid) == [new.kid]
      assert Repo.get_by!(InstallKey, kid: old.kid).status == "retired"

      assert {:error, :not_found} =
               Vault.get(InstallIdentity.vault_slug(old.kid), accessor: {:system, nil})

      # Positive control: the current key's private half is untouched.
      assert byte_size(private_key!(new.kid)) == 32
    end
  end

  describe "the descriptor never carries private-key bytes" do
    test "decoded, no string in the descriptor is or contains a private key" do
      old = InstallIdentity.ensure!()
      new = InstallIdentity.rotate!()
      privs = [private_key!(old.kid), private_key!(new.kid)]

      json = Jason.encode!(InstallIdentity.descriptor())
      decoded = Jason.decode!(json)

      # Each advertised key decodes to the PUBLIC key on record, not the private.
      for %{"kid" => kid, "public_key" => b64, "alg" => "ed25519"} <- decoded["keys"] do
        raw = Base.url_decode64!(b64, padding: false)
        assert raw == Repo.get_by!(InstallKey, kid: kid).public_key
        refute raw in privs
      end

      assert length(decoded["keys"]) == 2

      # Every string leaf, decoded under every encoding it parses as, is
      # neither equal to nor contains a private key. Raw bytes are checked
      # against the serialised document as well.
      leaves = string_leaves(decoded)
      assert leaves != []

      for leaf <- leaves, bytes <- decodings(leaf), priv <- privs do
        refute bytes == priv
        refute String.contains?(bytes, priv)
      end

      for priv <- privs, do: refute_contains_key(json, priv)
    end
  end

  describe "logs never carry private-key material" do
    setup do
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)
      :ok
    end

    test "ensure!/0 and rotate!/0 log no key material, and the capture is live" do
      {{first, second}, log} =
        with_log([level: :info], fn ->
          first = InstallIdentity.ensure!()
          second = InstallIdentity.rotate!()
          {first, second}
        end)

      # POSITIVE CONTROL: the same capture sees the known lines, so an empty
      # capture cannot pass the refutations below vacuously.
      assert log =~ "[federation] install identity created install_id=#{first.install_id}"
      assert log =~ "[federation] install key created kid=#{first.kid}"
      assert log =~ "fingerprint=#{first.fingerprint}"
      assert log =~ "[federation] install key rotated"
      assert log =~ "new_kid=#{second.kid}"

      for kid <- [first.kid, second.kid], do: refute_contains_key(log, private_key!(kid))
    end
  end

  describe "mix platform.gen_install_identity" do
    test "prints only the fingerprint, and the same one on a second run" do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Platform.GenInstallIdentity.run([])
      assert_received {:mix_shell, :info, [line]}

      %{fingerprint: fingerprint, kid: kid} = InstallIdentity.current()
      assert line == fingerprint
      assert line =~ ~r/\A[0-9a-f]{64}\z/
      refute_contains_key(line, private_key!(kid))

      Mix.Tasks.Platform.GenInstallIdentity.run([])
      assert_received {:mix_shell, :info, [^fingerprint]}
      refute_received {:mix_shell, _, _}
    end
  end

  defp string_leaves(value) when is_binary(value), do: [value]

  defp string_leaves(value) when is_map(value),
    do: Enum.flat_map(value, fn {_, v} -> string_leaves(v) end)

  defp string_leaves(value) when is_list(value), do: Enum.flat_map(value, &string_leaves/1)
  defp string_leaves(_), do: []

  defp decodings(leaf) do
    [
      {:raw, {:ok, leaf}},
      {:b64url, Base.url_decode64(leaf, padding: false)},
      {:b64url_padded, Base.url_decode64(leaf)},
      {:b64, Base.decode64(leaf)},
      {:b64_unpadded, Base.decode64(leaf, padding: false)},
      {:hex, Base.decode16(leaf, case: :mixed)}
    ]
    |> Enum.flat_map(fn
      {_, {:ok, bytes}} -> [bytes]
      _ -> []
    end)
  end
end
