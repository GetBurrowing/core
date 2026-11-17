defmodule Mix.Tasks.InstructionPacks.Publish do
  use Mix.Task
  @shortdoc "Publish a signed text instruction pack from an operator-owned manifest"
  @moduledoc "Local operator-only command; requires configured publisher credentials. No HTTP upload exists."
  def run([path]) do
    Mix.Task.run("app.start")
    config = Application.get_env(:platform, :instruction_pack_publisher, [])

    unless Keyword.get(config, :enabled, false) and Platform.Feedback.BrokerServer.enabled?(),
      do: Mix.raise("instruction pack publisher is disabled")

    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= Platform.InstructionPacks.Manifest.max_bytes(),
         {:ok, manifest} <- Jason.decode(bytes),
         {:ok, envelope} <-
           Platform.InstructionPacks.Signature.sign(
             manifest,
             Keyword.get(config, :key_id),
             Keyword.get(config, :private_key)
           ),
         {:ok, release} <-
           Platform.InstructionPacks.publish(envelope, Keyword.get(config, :trusted_keys, %{})) do
      Mix.shell().info(
        "Published #{release.pack_id} version #{release.version} digest #{release.digest}"
      )
    else
      _ -> Mix.raise("instruction pack publication refused")
    end
  end

  def run(_), do: Mix.raise("usage: mix instruction_packs.publish MANIFEST.json")
end
