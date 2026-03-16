defmodule Platform.Artifacts.Artifact do
  @moduledoc """
  Value struct describing a produced artifact.

  Artifacts are intentionally provider-agnostic: execution runs, chat flows,
  and canvas sessions can all register outputs through the same contract.
  Publication is tracked separately via `Platform.Artifacts.Publication` so the
  artifact record stays distinct from destination-specific delivery history.
  """

  @valid_kinds ~w(generic code_output file screenshot document canvas deck)a
  @valid_sources ~w(execution chat canvas system generic)a

  @enforce_keys [:id, :task_id]
  defstruct id: nil,
            project_id: nil,
            epic_id: nil,
            task_id: nil,
            run_id: nil,
            kind: :generic,
            source: :generic,
            name: nil,
            locator: nil,
            content_type: nil,
            byte_size: nil,
            metadata: %{},
            publications: [],
            latest_publication: nil,
            inserted_at: nil,
            updated_at: nil

  @type kind :: :generic | :code_output | :file | :screenshot | :document | :canvas | :deck
  @type source :: :execution | :chat | :canvas | :system | :generic

  @type t :: %__MODULE__{
          id: String.t(),
          project_id: String.t() | nil,
          epic_id: String.t() | nil,
          task_id: String.t(),
          run_id: String.t() | nil,
          kind: kind(),
          source: source(),
          name: String.t() | nil,
          locator: term(),
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          metadata: map(),
          publications: list(),
          latest_publication: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Builds and validates an artifact struct from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> new()

  def new(attrs) when is_map(attrs) do
    id = string_or_nil(Map.get(attrs, :id) || Map.get(attrs, "id")) || Ecto.UUID.generate()
    task_id = string_or_nil(Map.get(attrs, :task_id) || Map.get(attrs, "task_id"))
    kind = normalize_atom(Map.get(attrs, :kind) || Map.get(attrs, "kind"), :generic)
    source = normalize_atom(Map.get(attrs, :source) || Map.get(attrs, "source"), :generic)
    byte_size = Map.get(attrs, :byte_size) || Map.get(attrs, "byte_size")

    cond do
      is_nil(task_id) ->
        {:error, :task_id_required}

      kind not in @valid_kinds ->
        {:error, {:invalid_kind, kind}}

      source not in @valid_sources ->
        {:error, {:invalid_source, source}}

      not is_nil(byte_size) and (not is_integer(byte_size) or byte_size < 0) ->
        {:error, {:invalid_byte_size, byte_size}}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        {:ok,
         %__MODULE__{
           id: id,
           project_id: string_or_nil(Map.get(attrs, :project_id) || Map.get(attrs, "project_id")),
           epic_id: string_or_nil(Map.get(attrs, :epic_id) || Map.get(attrs, "epic_id")),
           task_id: task_id,
           run_id: string_or_nil(Map.get(attrs, :run_id) || Map.get(attrs, "run_id")),
           kind: kind,
           source: source,
           name: string_or_nil(Map.get(attrs, :name) || Map.get(attrs, "name")),
           locator: Map.get(attrs, :locator) || Map.get(attrs, "locator"),
           content_type:
             string_or_nil(Map.get(attrs, :content_type) || Map.get(attrs, "content_type")),
           byte_size: byte_size,
           metadata: normalize_map(Map.get(attrs, :metadata) || Map.get(attrs, "metadata")),
           inserted_at:
             timestamp(Map.get(attrs, :inserted_at) || Map.get(attrs, "inserted_at")) || now,
           updated_at:
             timestamp(Map.get(attrs, :updated_at) || Map.get(attrs, "updated_at")) || now
         }}
    end
  end

  @doc "Returns the small artifact snapshot stored in task/run context items."
  @spec to_ref(t()) :: map()
  def to_ref(%__MODULE__{} = artifact) do
    %{
      "artifact_id" => artifact.id,
      "task_id" => artifact.task_id,
      "run_id" => artifact.run_id,
      "kind" => Atom.to_string(artifact.kind),
      "source" => Atom.to_string(artifact.source),
      "name" => artifact.name,
      "locator" => artifact.locator,
      "content_type" => artifact.content_type,
      "byte_size" => artifact.byte_size,
      "metadata" => artifact.metadata,
      "latest_publication" => publication_ref(artifact.latest_publication),
      "updated_at" => iso8601(artifact.updated_at)
    }
  end

  @doc "Attaches publication history to the artifact for read-side responses."
  @spec with_publications(t(), list()) :: t()
  def with_publications(%__MODULE__{} = artifact, publications) when is_list(publications) do
    publications = Enum.sort_by(publications, & &1.attempt, :asc)
    latest_publication = List.last(publications)

    %__MODULE__{
      artifact
      | publications: publications,
        latest_publication: publication_ref(latest_publication)
    }
  end

  @doc "Valid kinds accepted by the artifact substrate."
  @spec valid_kinds() :: [kind()]
  def valid_kinds, do: @valid_kinds

  @doc "Valid artifact sources accepted by the artifact substrate."
  @spec valid_sources() :: [source()]
  def valid_sources, do: @valid_sources

  defp publication_ref(nil), do: nil

  defp publication_ref(publication)
       when is_map(publication) and is_map_key(publication, "publication_id"), do: publication

  defp publication_ref(publication) do
    %{
      "publication_id" => publication.id,
      "destination" => Atom.to_string(publication.destination),
      "status" => Atom.to_string(publication.status),
      "attempt" => publication.attempt,
      "external_ref" => publication.external_ref,
      "error" => publication.error,
      "finished_at" => iso8601(publication.finished_at)
    }
  end

  defp normalize_atom(value, _default) when is_atom(value), do: value

  defp normalize_atom(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> default
      trimmed -> String.to_existing_atom(trimmed)
    end
  rescue
    ArgumentError -> default
  end

  defp normalize_atom(_, default), do: default

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp string_or_nil(nil), do: nil

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(value), do: to_string(value)

  defp timestamp(%DateTime{} = value), do: value
  defp timestamp(_), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
