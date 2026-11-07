defmodule Platform.GameStream.NativeBuild do
  @moduledoc "Immutable native build registry, shared by native hosts and launchers."
  use Ecto.Schema
  import Ecto.Query
  alias Platform.Repo
  @primary_key {:id, :string, autogenerate: false}
  schema "native_game_builds" do
    field(:project_id, :binary_id)
    field(:manifest, :map)
    field(:published_at, :utc_datetime_usec)
  end

  def register(project_id, manifest) when is_map(manifest) do
    with true <- Platform.UUID.valid?(project_id),
         %Platform.Tasks.Project{repo_url: repo} <- Repo.get(Platform.Tasks.Project, project_id),
         true <- repo == manifest["repo_url"],
         id when is_binary(id) and byte_size(id) in 1..128 <- manifest["id"],
         true <- valid?(manifest) do
      case Repo.insert(
             %__MODULE__{
               id: id,
               project_id: project_id,
               manifest: manifest,
               published_at: DateTime.utc_now()
             },
             on_conflict: :nothing
           ) do
        {:ok, _} ->
          case Repo.get(__MODULE__, id) do
            %__MODULE__{project_id: ^project_id, manifest: ^manifest} = row -> {:ok, row}
            _ -> {:error, :immutable_conflict}
          end

        error ->
          error
      end
    else
      _ -> {:error, :invalid_build}
    end
  end

  def valid?(m) do
    package_valid?(m) and is_binary(m["engine"]) and m["engine"] != "" and
      is_integer(m["protocol_version"]) and m["protocol_version"] > 0 and
      is_integer(m["capacity"]) and m["capacity"] in 1..8 and
      is_binary(m["server_image"]) and
      Regex.match?(~r/\A[a-z0-9][a-z0-9.\/:_-]*@sha256:[0-9a-f]{64}\z/, m["server_image"])
  end

  # Rows and artifacts are immutable. Publication order comes from the signed workflow
  # run_number, not completion time: a delayed older matrix cannot move latest backwards.
  def latest(project_id),
    do:
      Repo.one(
        from(b in __MODULE__,
          where: b.project_id == ^project_id,
          order_by: [
            desc: fragment("COALESCE((?->>'build_number')::bigint, 0)", b.manifest),
            desc: b.published_at,
            desc: b.id
          ],
          limit: 1
        )
      )

  def package_valid?(%{"schema_version" => 1} = m) do
    artifacts = m["artifacts"]

    is_binary(m["source_sha"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, m["source_sha"]) and
      is_integer(m["build_number"]) and m["build_number"] > 0 and
      is_list(artifacts) and Enum.all?(artifacts, &artifact_valid?/1) and
      MapSet.subset?(
        MapSet.new([
          {"windows", "x86_64", "client"},
          {"linux", "x86_64", "client"},
          {"macos", "universal", "client"},
          {"linux", "x86_64", "server"}
        ]),
        MapSet.new(Enum.map(artifacts, &{&1["os"], &1["arch"], &1["role"]}))
      ) and
      length(artifacts) ==
        MapSet.size(MapSet.new(Enum.map(artifacts, &{&1["os"], &1["arch"], &1["role"]})))
  end

  # Existing operator-registered development manifests remain supported. The CI route
  # requires signed source/build claims and only accepts schema v1 package manifests.
  def package_valid?(m),
    do: not Map.has_key?(m, "schema_version") and not Map.has_key?(m, "build_number")

  defp artifact_valid?(a) when is_map(a) do
    is_integer(a["size"]) and a["size"] > 0 and
      is_integer(a["asset_id"]) and a["asset_id"] > 0 and
      is_binary(a["sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, a["sha256"]) and
      safe_path?(a["executable"]) and safe_path?(a["filename"])
  end

  defp artifact_valid?(_), do: false

  defp safe_path?(path) when is_binary(path),
    do:
      path != "" and not String.starts_with?(path, "/") and
        not String.contains?(path, ["..", "\\"])

  defp safe_path?(_), do: false
end
