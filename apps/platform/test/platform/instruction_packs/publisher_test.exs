defmodule Platform.InstructionPacks.PublisherTest do
  use Platform.DataCase, async: true
  import Platform.InstructionPackFixtures
  alias Platform.InstructionPacks
  alias Platform.InstructionPacks.Manifest

  test "immutable versions require the exact preceding digest and sequential version" do
    {e, roots} = envelope()
    assert {:ok, first} = InstructionPacks.publish(e, roots)
    assert InstructionPacks.get_release("setup-guide", 1).envelope == Jason.encode!(e)
    assert {:error, :invalid_release_chain} = InstructionPacks.publish(e, roots)

    {bad, _} =
      envelope(manifest(%{"version" => 2, "previous_digest" => String.duplicate("0", 64)}))

    assert {:error, :invalid_release_chain} = InstructionPacks.publish(bad, roots)

    {next, _} =
      envelope(manifest(%{"version" => 2, "previous_digest" => Manifest.digest(e["manifest"])}))

    assert {:ok, second} = InstructionPacks.publish(next, roots)
    assert second.version == 2
    assert first.envelope == InstructionPacks.get_release("setup-guide", 1).envelope
    {tampered, _} = envelope()

    assert {:error, :untrusted_pack} =
             InstructionPacks.publish(put_in(tampered, ["manifest", "changelog"], "bad"), roots)
  end

  test "database rejects mutation of release bytes" do
    {e, roots} = envelope()
    {:ok, r} = InstructionPacks.publish(e, roots)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Platform.Repo.query!("UPDATE instruction_pack_releases SET envelope = $1 WHERE id = $2", [
        "bad",
        Ecto.UUID.dump!(r.id)
      ])
    end
  end
end
