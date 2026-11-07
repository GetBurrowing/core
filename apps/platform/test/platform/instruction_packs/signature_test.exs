defmodule Platform.InstructionPacks.SignatureTest do
  use ExUnit.Case, async: true
  import Platform.InstructionPackFixtures
  alias Platform.InstructionPacks.Signature

  test "tampered signed text is refused (signature mutation sentinel)" do
    {e, roots} = envelope()
    assert {:ok, _} = Signature.verify(e, roots)
    tampered = put_in(e, ["manifest", "changelog"], "TAMPERED-SIGNATURE-SENTINEL")
    assert {:error, :untrusted_pack} = Signature.verify(tampered, roots)
  end

  test "unknown roots, malformed signatures, envelope extensions and oversized data fail closed" do
    {e, roots} = envelope()
    assert {:error, :untrusted_pack} = Signature.verify(e, %{})

    assert {:error, :untrusted_pack} =
             Signature.verify(Map.put(e, "public_key", "untrusted"), roots)

    assert {:error, :untrusted_pack} = Signature.verify(%{e | "signature" => "garbage"}, roots)
    assert {:error, :pack_too_large} = Signature.decode(String.duplicate("x", 1_100_001), roots)
  end

  test "independent OpenSSL Ed25519 fixture pins canonical bytes and signature" do
    fixture =
      Path.expand("../../fixtures/instruction_pack_vector.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    public = Base.decode64!(fixture["public_key"])
    assert {:ok, m} = Signature.verify(fixture["envelope"], %{"vector-root" => public})
    assert Platform.InstructionPacks.Manifest.canonical(m) == fixture["canonical"]
  end
end
