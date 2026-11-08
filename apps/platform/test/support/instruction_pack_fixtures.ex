defmodule Platform.InstructionPackFixtures do
  @moduledoc false
  def manifest(overrides \\ %{}) do
    Map.merge(
      %{
        "pack_id" => "setup-guide",
        "version" => 1,
        "schema_version" => 1,
        "minimum_client_version" => "1.0.0",
        "published_at" => "2026-11-07T16:00:00Z",
        "previous_digest" => nil,
        "changelog" => "Clearer welcome guidance",
        "entries" => [
          %{
            "type" => "setup_dialogue",
            "target" => "welcome.v1",
            "content" => "Welcome. What would you like help with?"
          }
        ]
      },
      overrides
    )
  end

  def keys do
    :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<7>>, 32))
  end

  def envelope(m \\ manifest()) do
    {pub, private} = keys()
    {:ok, envelope} = Platform.InstructionPacks.Signature.sign(m, "test-root", private)
    {envelope, %{"test-root" => pub}}
  end
end
