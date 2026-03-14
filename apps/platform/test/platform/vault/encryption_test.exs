defmodule Platform.Vault.EncryptionTest do
  use ExUnit.Case, async: false

  alias Platform.Vault.Encryption

  describe "encrypt!/1 and decrypt!/1" do
    test "round-trip: encrypts and decrypts a binary" do
      plaintext = "super secret value"
      ciphertext = Encryption.encrypt!(plaintext)
      assert Encryption.decrypt!(ciphertext) == plaintext
    end

    test "round-trip: works with binary data" do
      plaintext = <<0, 1, 2, 3, 4, 255>>
      ciphertext = Encryption.encrypt!(plaintext)
      assert Encryption.decrypt!(ciphertext) == plaintext
    end

    test "ciphertext is different from plaintext" do
      plaintext = "not encrypted yet"
      ciphertext = Encryption.encrypt!(plaintext)
      refute ciphertext == plaintext
    end

    test "different plaintexts produce different ciphertexts" do
      ct1 = Encryption.encrypt!("value one")
      ct2 = Encryption.encrypt!("value two")
      refute ct1 == ct2
    end

    test "same plaintext produces different ciphertexts (random IV)" do
      plaintext = "same value"
      ct1 = Encryption.encrypt!(plaintext)
      ct2 = Encryption.encrypt!(plaintext)
      # AES-GCM with random IV should produce different ciphertexts each time
      refute ct1 == ct2
    end
  end

  describe "decrypt!/1 with wrong key" do
    test "decryption with wrong key does not return original plaintext" do
      plaintext = "sensitive data"
      ciphertext = Encryption.encrypt!(plaintext)

      # Configure a second vault with a different key
      wrong_key = :crypto.strong_rand_bytes(32)

      Application.put_env(:platform, Platform.Vault.WrongKeyTest,
        ciphers: [
          default: {
            Cloak.Ciphers.AES.GCM,
            tag: "AES.GCM.V1", key: wrong_key, iv_length: 12
          }
        ]
      )

      {:ok, _pid} = Platform.Vault.WrongKeyTest.start_link([])

      # AES-GCM authentication failure: wrong key yields a non-plaintext result
      result = Platform.Vault.WrongKeyTest.decrypt!(ciphertext)

      refute result == plaintext,
             "Expected wrong-key decryption to NOT return the original plaintext"

      GenServer.stop(Platform.Vault.WrongKeyTest)
    end

    test "missing cipher tag raises Cloak.MissingCipherError" do
      # A ciphertext with no recognized tag should raise
      garbage = "not-a-real-ciphertext"

      assert_raise Cloak.MissingCipher, fn ->
        Encryption.decrypt!(garbage)
      end
    end
  end
end

# Inline test vault used only for the wrong-key test
defmodule Platform.Vault.WrongKeyTest do
  @moduledoc false
  use Cloak.Vault, otp_app: :platform
end
