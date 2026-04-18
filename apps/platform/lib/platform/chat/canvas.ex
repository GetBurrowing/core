defmodule Platform.Chat.Canvas do
  @moduledoc """
  First-class space-scoped canvas (ADR 0036).

  A canvas owns a canonical document (`CanvasDocument`), has its own lifecycle,
  and is referenced by messages rather than subordinate to them. Deletion is
  soft via `deleted_at`; provenance is tracked via `cloned_from`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Chat.CanvasDocument

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_canvases" do
    field(:space_id, :binary_id)
    field(:created_by, :binary_id)
    field(:cloned_from, :binary_id)
    field(:title, :string)
    field(:document, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:deleted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(canvas, attrs) do
    canvas
    |> cast(attrs, [
      :space_id,
      :created_by,
      :cloned_from,
      :title,
      :document,
      :metadata,
      :deleted_at
    ])
    |> validate_required([:space_id, :created_by])
    |> validate_document()
  end

  defp validate_document(changeset) do
    case get_field(changeset, :document) do
      nil ->
        put_change(changeset, :document, CanvasDocument.new())

      %{} = doc when map_size(doc) == 0 ->
        put_change(changeset, :document, CanvasDocument.new())

      doc when is_map(doc) ->
        case CanvasDocument.validate(doc) do
          {:ok, _} ->
            changeset

          {:error, reasons} ->
            add_error(changeset, :document, "invalid: #{Enum.join(reasons, "; ")}")
        end
    end
  end
end
