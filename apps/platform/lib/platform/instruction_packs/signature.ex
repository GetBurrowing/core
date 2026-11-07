defmodule Platform.InstructionPacks.Signature do
  @moduledoc "Ed25519 envelopes; trust roots come from owner/installer configuration, never the pack."
  alias Platform.InstructionPacks.Manifest
  @fields ~w(manifest key_id signature)

  def sign(manifest, key_id, private_key) do
    with {:ok, m} <- Manifest.validate(manifest),
         true <- valid_key_id?(key_id) do
      signature = :crypto.sign(:eddsa, :none, Manifest.canonical(m), [private_key, :ed25519])
      {:ok, %{"manifest" => m, "key_id" => key_id, "signature" => Base.encode64(signature)}}
    else
      _ -> {:error, :invalid_manifest}
    end
  rescue
    _ -> {:error, :signing_failed}
  end

  def verify(envelope, roots) when is_map(envelope) and is_map(roots) do
    with true <- Enum.sort(Map.keys(envelope)) == Enum.sort(@fields),
         true <- valid_key_id?(envelope["key_id"]),
         {:ok, public_key} <- Map.fetch(roots, envelope["key_id"]),
         true <- is_binary(public_key) and byte_size(public_key) == 32,
         {:ok, manifest} <- Manifest.validate(envelope["manifest"]),
         {:ok, signature} <- Base.decode64(envelope["signature"] || ""),
         true <- byte_size(signature) == 64,
         true <-
           :crypto.verify(:eddsa, :none, Manifest.canonical(manifest), signature, [
             public_key,
             :ed25519
           ]) do
      {:ok, manifest}
    else
      _ -> {:error, :untrusted_pack}
    end
  rescue
    _ -> {:error, :untrusted_pack}
  end

  def verify(_, _), do: {:error, :untrusted_pack}

  def decode(bytes, roots) when is_binary(bytes) and byte_size(bytes) <= 1_100_000 do
    with {:ok, envelope} <- Jason.decode(bytes), do: verify(envelope, roots)
  end

  def decode(_, _), do: {:error, :pack_too_large}

  defp valid_key_id?(id) when is_binary(id), do: Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,64}\z/, id)
  defp valid_key_id?(_), do: false
end
