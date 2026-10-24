defmodule Platform.Social.VoiceLearning do
  @moduledoc """
  One accepted learning in a brand's voice (`Platform.Social.Voice`,
  Social authoring 4/11): `text`, the weekly note it came from
  (`source_note_id`), and who accepted it and when. Written only by the
  weekly-note flow (11/11) through `changeset/2`; never cast from a
  profile's attrs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  embedded_schema do
    field(:text, :string)
    field(:source_note_id, :binary_id)
    field(:accepted_by_user_id, :binary_id)
    field(:accepted_at, :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = learning, attrs) do
    learning
    |> cast(attrs, [:text, :source_note_id, :accepted_by_user_id, :accepted_at])
    |> validate_required([:text])
    |> validate_length(:text, min: 1, max: 1000)
  end
end
