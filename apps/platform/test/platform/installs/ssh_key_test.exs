defmodule Platform.Installs.SshKeyTest do
  @moduledoc """
  Task 01a10315 stage 2: the install's ed25519 root key pair. The private
  half is parsed back out of its `openssh-key-v1` container and proven to
  sign for the public half; where `ssh-keygen` exists it must agree too.
  """
  use ExUnit.Case, async: true

  alias Platform.Installs.SshKey

  @keygen System.find_executable("ssh-keygen")

  defp str(<<len::32, value::binary-size(len), rest::binary>>), do: {value, rest}

  defp parse_private(pem) do
    body =
      pem
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "-----"))
      |> Enum.join()
      |> Base.decode64!()

    "openssh-key-v1\0" <> rest = body
    {"none", rest} = str(rest)
    {"none", rest} = str(rest)
    {"", rest} = str(rest)
    <<1::32, rest::binary>> = rest
    {blob, rest} = str(rest)
    {section, ""} = str(rest)
    <<c1::32, c2::32, section::binary>> = section
    {"ssh-ed25519", section} = str(section)
    {pub, section} = str(section)
    {priv_pub, section} = str(section)
    {comment, padding} = str(section)
    %{blob: blob, check: {c1, c2}, pub: pub, priv_pub: priv_pub, comment: comment, padding: padding}
  end

  test "the public line and the private container describe one key that signs" do
    %{public: public, private: private} = SshKey.generate("burrow-install")

    assert ["ssh-ed25519", b64, "burrow-install"] = String.split(public, " ")
    assert private =~ ~r/\A-----BEGIN OPENSSH PRIVATE KEY-----\n/
    assert private =~ ~r/\n-----END OPENSSH PRIVATE KEY-----\n\z/

    for line <- String.split(private, "\n", trim: true), not String.starts_with?(line, "-----") do
      assert byte_size(line) <= 70
    end

    parsed = parse_private(private)
    assert parsed.blob == Base.decode64!(b64)
    assert {c, c} = parsed.check
    assert parsed.comment == "burrow-install"
    assert byte_size(parsed.pub) == 32
    <<seed::binary-size(32), pub::binary-size(32)>> = parsed.priv_pub
    assert pub == parsed.pub
    assert parsed.padding == :binary.list_to_bin(Enum.take(1..8, byte_size(parsed.padding)))

    signature = :crypto.sign(:eddsa, :none, "burrow", [seed, :ed25519])
    assert :crypto.verify(:eddsa, :none, "burrow", signature, [pub, :ed25519])
    refute :crypto.verify(:eddsa, :none, "other", signature, [pub, :ed25519])
  end

  test "two keys differ" do
    refute SshKey.generate().public == SshKey.generate().public
  end

  @tag skip: if(@keygen, do: false, else: "ssh-keygen is not on PATH here")
  @tag :tmp_dir
  test "ssh-keygen reads the private key and derives the same public key", %{tmp_dir: dir} do
    %{public: public, private: private} = SshKey.generate()
    path = Path.join(dir, "id")
    File.write!(path, private)
    File.chmod!(path, 0o600)

    {out, 0} = System.cmd(@keygen, ["-y", "-f", path], stderr_to_stdout: true)
    assert out |> String.split(" ") |> Enum.take(2) == public |> String.split(" ") |> Enum.take(2)
  end
end
