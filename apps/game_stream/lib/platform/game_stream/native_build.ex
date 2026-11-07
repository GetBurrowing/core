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
    is_binary(m["engine"]) and m["engine"] != "" and
      is_integer(m["protocol_version"]) and m["protocol_version"] > 0 and
      is_integer(m["capacity"]) and m["capacity"] in 1..8 and
      is_binary(m["server_image"]) and
      Regex.match?(~r/\A[a-z0-9][a-z0-9.\/:_-]*@sha256:[0-9a-f]{64}\z/, m["server_image"])
  end

  def latest(project_id),
    do:
      Repo.one(
        from(b in __MODULE__,
          where: b.project_id == ^project_id,
          order_by: [desc: b.published_at, desc: b.id],
          limit: 1
        )
      )
end
