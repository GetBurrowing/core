defmodule Platform.Prototypes.Version do
  @moduledoc """
  One immutable publish of a prototype. Nothing updates a version's bytes or
  manifest after insert; the only later write is `removed_at`, set by
  `Platform.Prototypes.Purger` when retention deletes the bytes.

  `manifest` is one map per file:
  `%{"path", "content_type", "byte_size", "storage_key", "sha256"}`.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "prototype_versions" do
    belongs_to(:prototype, Platform.Prototypes.Prototype)
    field(:version, :integer)
    field(:manifest, {:array, :map}, default: [])
    field(:total_bytes, :integer, default: 0)
    field(:entry_path, :string, default: "index.html")
    field(:published_by, :map, default: %{})
    field(:removed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The manifest entry for `path`, or nil."
  @spec file(t(), String.t()) :: map() | nil
  def file(%__MODULE__{manifest: manifest}, path) when is_binary(path),
    do: Enum.find(manifest, &(&1["path"] == path))
end
