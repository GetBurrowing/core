defmodule Platform.Social.IdeaNote do
  @moduledoc """
  One note in an idea's thread (Social authoring 7/11, task 01a16c50-ea67):
  a human (from the Ideas tab) or an agent (`social_idea_note_add`) said
  `body` about the idea.

  Written ONLY by `Platform.Social.IdeaNotes.add/4`; `idea_id`,
  `author_kind` and `author_id` are put there, never cast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @author_kinds ~w(human agent)
  @max_body 4_000

  @type t :: %__MODULE__{}

  schema "social_idea_notes" do
    belongs_to(:idea, Platform.Social.Idea)
    field(:author_kind, :string)
    field(:author_id, :binary_id)
    field(:body, :string)

    timestamps()
  end

  @doc "Accepted `author_kind` values."
  @spec author_kinds() :: [String.t()]
  def author_kinds, do: @author_kinds

  @doc "The longest accepted body."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = note, attrs) do
    note
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body, :idea_id, :author_kind])
    |> validate_length(:body, max: @max_body)
    |> validate_inclusion(:author_kind, @author_kinds)
    |> check_constraint(:author_kind, name: :social_idea_notes_author_kind_check)
    |> check_constraint(:body, name: :social_idea_notes_body_length_check)
    |> foreign_key_constraint(:idea_id)
  end
end
