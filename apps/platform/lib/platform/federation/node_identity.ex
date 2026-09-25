defmodule Platform.Federation.NodeIdentity do
  @moduledoc """
  Manages Ed25519 device identity for the OpenClaw node connection.

  The Ed25519 primitives live in `Platform.Federation.Ed25519` (hoisted there
  by task 01a0d90f stage 2). This module owns only the on-disk identity file,
  whose format is unchanged: a JSON object with standard-base64
  `public_key` and `private_key`.
  """

  alias Platform.Federation.Ed25519

  @default_identity_path "/data/platform/execution-runs/node_identity.json"

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
  Derives a device ID from the public key: the full lowercase SHA256 hex
  (64 characters), i.e. `Ed25519.fingerprint/1`.
  """
  def device_id(identity), do: Ed25519.fingerprint(identity.public_key)

  @doc """
  Signs a binary payload with the identity's private key using Ed25519.
  """
  def sign(payload, identity) when is_binary(payload) do
    Ed25519.sign(payload, identity.private_key)
  end

  @doc """
  Build the v3 device auth payload string for signing.
  Format: v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily
  """
  def build_auth_payload(params) do
    Enum.join(
      [
        "v3",
        params.device_id,
        params.client_id,
        params.client_mode,
        params.role,
        Map.get(params, :scopes, ""),
        Integer.to_string(params.signed_at_ms),
        params.token || "",
        params.nonce,
        Map.get(params, :platform, "linux"),
        Map.get(params, :device_family, "")
      ],
      "|"
    )
  end

  @doc "Encode bytes as base64url without padding (for gateway protocol)."
  def base64url(bytes), do: Base.url_encode64(bytes, padding: false)

  defp generate_and_persist(path) do
    {pub, priv} = Ed25519.generate()
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
    Application.get_env(:platform, :node_identity_path, @default_identity_path)
  end
end
