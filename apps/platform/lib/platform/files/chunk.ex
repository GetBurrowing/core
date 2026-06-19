defmodule Platform.Files.Chunk do
  @moduledoc """
  Ecto schema for the `platform_file_chunks` table.

  Each row records one chunk that the memory-service produced for a given
  `Platform.Files.File`. The `chunk_external_id` is whatever opaque id the
  remote vector store assigned (we don't introspect it; we just keep the
  mapping so dedup can copy linkage between two `platform_files` rows
  that share `content_hash` within a project).

  Stage 3 of ADR 0042. See the companion migration for column constraints.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "platform_file_chunks" do
    belongs_to(:file, Platform.Files.File)

    field(:chunk_external_id, :string)
    field(:page, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(file_id chunk_external_id page)a
  @required_fields ~w(file_id chunk_external_id)a

  @doc """
  Changeset for inserting a chunk back-reference. `:page` stays nil for
  flow formats (CSV, plain text, OCR'd images).
  """
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:file_id)
    |> unique_constraint([:file_id, :chunk_external_id],
      name: :platform_file_chunks_file_id_chunk_external_id_index
    )
  end
end
