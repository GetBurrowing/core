defmodule Platform.InstructionPacks do
  @moduledoc "Publisher-side immutable releases. No agent tool or HTTP upload can publish a pack."
  import Ecto.Query
  alias Platform.Repo
  alias Platform.InstructionPacks.{Manifest, Pack, Release, Signature}

  def publish(envelope, roots) do
    with {:ok, manifest} <- Signature.verify(envelope, roots) do
      Repo.transaction(fn ->
        id = manifest["pack_id"]
        # Serialize even the first publication; no race between missing rows.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "instruction_pack:" <> id
        ])

        previous =
          Repo.one(
            from(r in Release, where: r.pack_id == ^id, order_by: [desc: r.version], limit: 1)
          )

        valid =
          case previous do
            nil -> manifest["version"] == 1 and is_nil(manifest["previous_digest"])
            r -> manifest["version"] == r.version + 1 and manifest["previous_digest"] == r.digest
          end

        unless valid, do: Repo.rollback(:invalid_release_chain)
        Repo.insert!(%Pack{id: id}, on_conflict: :nothing)

        Repo.insert!(%Release{
          pack_id: id,
          version: manifest["version"],
          digest: Manifest.digest(manifest),
          envelope: Jason.encode!(envelope)
        })
      end)
    end
  end

  def get_release(pack_id, version) when is_integer(version) and version > 0,
    do: Repo.get_by(Release, pack_id: pack_id, version: version)

  def get_release(_, _), do: nil
end
