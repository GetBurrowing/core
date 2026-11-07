defmodule Platform.GameStream.NativeAssets do
  @moduledoc "Authenticated short-lived GitHub asset handoff. Repository credentials stay on the server."
  alias Platform.GameStream.{GameChannels, NativeBuild}
  alias Platform.Repo

  def manifest(user, channel_id, build_id) do
    with {:ok, binding} <- GameChannels.authorize(user, channel_id),
         %NativeBuild{project_id: project_id} = build <- Repo.get(NativeBuild, build_id),
         true <- project_id == binding.project_id do
      {:ok, build.manifest}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def download(user, channel_id, build_id, index) do
    with {:ok, manifest} <- manifest(user, channel_id, build_id),
         {number, ""} <- Integer.parse(index),
         true <- number >= 0,
         artifact when is_map(artifact) <- Enum.at(manifest["artifacts"] || [], number),
         asset when is_integer(asset) and asset > 0 <- artifact["asset_id"],
         repository when is_binary(repository) <- manifest["repository"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repository),
         {:ok, token} <- credential(repository),
         {:ok, %{status: 302, headers: headers}} <-
           Req.get("https://api.github.com/repos/#{repository}/releases/assets/#{asset}",
             headers: [
               {"authorization", "Bearer " <> token},
               {"accept", "application/octet-stream"}
             ],
             redirect: false,
             retry: false,
             decode_body: false,
             receive_timeout: 10_000
           ),
         [url] <- headers["location"],
         true <- signed_asset_url?(url) do
      {:ok, %{url: url, expires_in: 60, sha256: artifact["sha256"], size: artifact["size"]}}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def signed_asset_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) ->
        host == "release-assets.githubusercontent.com" or host == "objects.githubusercontent.com"

      _ ->
        false
    end
  end

  defp credential(repository) do
    with path when is_binary(path) <- System.get_env("GAME_NATIVE_ASSET_CREDENTIALS_FILE"),
         {:ok, %{mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, body} <- File.read(path),
         {:ok, credentials} <- Jason.decode(body),
         token when is_binary(token) and token != "" <- credentials[repository] do
      {:ok, token}
    else
      _ -> {:error, :unavailable}
    end
  end
end
