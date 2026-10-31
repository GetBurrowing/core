defmodule Platform.Installs.SshKey do
  @moduledoc """
  An ed25519 key pair for an install's root login (task 01a10315 stage 2).

  The public half goes into the manifest (`host.ssh_authorized_key`); the
  private half lives only in the install's `handover_sealed` until the
  customer acknowledges the hand-over. It is never registered as a
  DigitalOcean account `ssh_key` object (those would accumulate).

  OTP's `:ssh_file.encode(_, :openssh_key_v1)` writes an ed25519 private key
  `ssh-keygen` refuses ("invalid format", measured on OTP 28 / ssh 5.4.1,
  2026-10-30), so both halves are encoded here, following OpenSSH's
  PROTOCOL.key: an unencrypted `openssh-key-v1` container with one key.
  """

  @key_type "ssh-ed25519"
  @block 8

  @doc """
  Generate a key pair. Returns `%{public: "ssh-ed25519 <b64> <comment>",
  private: "-----BEGIN OPENSSH PRIVATE KEY-----..."}`.
  """
  @spec generate(String.t()) :: %{public: String.t(), private: String.t()}
  def generate(comment \\ "burrow-install") do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    encode(pub, priv, comment)
  end

  @doc false
  def encode(pub, priv, comment) when byte_size(pub) == 32 and byte_size(priv) == 32 do
    blob = str(@key_type) <> str(pub)
    check = :crypto.strong_rand_bytes(4)

    section =
      check <> check <> str(@key_type) <> str(pub) <> str(priv <> pub) <> str(comment)

    section = section <> padding(byte_size(section))

    body =
      "openssh-key-v1\0" <>
        str("none") <> str("none") <> str("") <> <<1::32>> <> str(blob) <> str(section)

    lines =
      body
      |> Base.encode64()
      |> chunks(70)
      |> Enum.join("\n")

    %{
      public: "#{@key_type} #{Base.encode64(blob)} #{comment}",
      private:
        "-----BEGIN OPENSSH PRIVATE KEY-----\n" <>
          lines <> "\n-----END OPENSSH PRIVATE KEY-----\n"
    }
  end

  defp str(bin), do: <<byte_size(bin)::32, bin::binary>>

  defp padding(size) do
    n = rem(@block - rem(size, @block), @block)
    :binary.list_to_bin(Enum.take(1..@block, n))
  end

  defp chunks(<<chunk::binary-size(70), rest::binary>>, 70) when rest != "",
    do: [chunk | chunks(rest, 70)]

  defp chunks(rest, _), do: [rest]
end
