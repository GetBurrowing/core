defmodule Platform.Files.Text do
  @moduledoc """
  Ecto schema for the `platform_file_texts` table.

  Stores the extractor's full text plus the optional per-page split for a
  given `Platform.Files.File`. Stage 4 of ADR 0042 reads from this table
  when the `file_get_text` MCP tool serves a request, so we don't re-shell
  out to pdftotext / pandoc / tesseract on every read.

  One row per file. `:file_id` is the primary key (no separate UUID PK —
  the relationship is 1:1 by construction).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:file_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "platform_file_texts" do
    belongs_to(:file, Platform.Files.File,
      define_field: false,
      foreign_key: :file_id,
      references: :id
    )

    field(:text, :string)
    field(:pages, {:array, :string})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast_fields ~w(file_id text pages)a
  @required_fields ~w(file_id text)a

  @doc """
  Changeset for upserting an extracted-text row. `pages` is optional —
  flow formats (CSV, plain text, OCR'd image) leave it nil and the full
  body sits in `text`.
  """
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:file_id)
  end
end
