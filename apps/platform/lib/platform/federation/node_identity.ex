defmodule Platform.Federation.NodeIdentity do
  @moduledoc """
  Manages Ed25519 device identity for the OpenClaw node connection.
  """

  @identity_path Application.compile_env(
                   :platform,
                   :node_identity_path,
                   "/data/platform/node_identity.json"
                 )

  @doc """
  Loads an existing identity from disk or generates a new Ed25519 keypair.
  Returns `%{public_key: binary(), private_key: binary()}`.
  """
  def load_or_create do
    path = identity_path()

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"public_key" => pub_b64, "private_key" => priv_b64}} ->
            with {:ok, pub} <- Base.decode64(pub_b64),
                 {:ok, priv} <- Base.decode64(priv_b64) do
              %{public_key: pub, private_key: priv}
            else
              _ -> generate_and_persist(path)
            end

          _ ->
            generate_and_persist(path)
        end

      {:error, _} ->
        generate_and_persist(path)
    end
  end

  @doc """
  Derives a device ID from the public key: SHA256 hex, first 32 chars.
  """
  def device_id(identity) do
    :crypto.hash(:sha256, identity.public_key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc """
  Signs a binary nonce with the identity's private key using Ed25519.
  """
  def sign_challenge(nonce_binary, identity) when is_binary(nonce_binary) do
    :crypto.sign(:eddsa, :none, nonce_binary, [identity.private_key, :ed25519])
  end

  defp generate_and_persist(path) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    identity = %{public_key: pub, private_key: priv}

    json =
      Jason.encode!(%{
        public_key: Base.encode64(pub),
        private_key: Base.encode64(priv)
      })

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json)
    identity
  end

  defp identity_path do
    Application.get_env(:platform, :node_identity_path, @identity_path)
  end
end
