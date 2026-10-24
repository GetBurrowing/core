defmodule Platform.Social.ClipRender do
  @moduledoc """
  One rendered version (`rev`) of a `Platform.Social.Clip` (Clip Studio 1/9,
  task 01a16661-e234): the file it produced and the look and trim it was
  rendered with. A clip keeps its id across re-renders; each new rev adds a
  row here and earlier rows are never rewritten. Unique per `(clip_id, rev)`.

  Deleting the clip deletes its renders; deleting the file nils `file_id`
  and keeps the row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @type t :: %__MODULE__{}

  schema "social_clip_renders" do
    belongs_to(:clip, Platform.Social.Clip)
    field(:rev, :integer)
    belongs_to(:file, Platform.Files.File)
    field(:look, :map, default: %{})
    field(:trim_in_s, :float)
    field(:trim_out_s, :float)
    belongs_to(:submitted_by_agent, Platform.Agents.Agent)

    timestamps()
  end

  @fields ~w(clip_id rev file_id look trim_in_s trim_out_s submitted_by_agent_id)a

  @doc "Changeset for a new render row. Written by the context, never from agent attrs."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = render, attrs) do
    render
    |> cast(attrs, @fields)
    |> validate_required([:clip_id, :rev, :look])
    |> validate_number(:rev, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:clip_id)
    |> foreign_key_constraint(:file_id)
    |> foreign_key_constraint(:submitted_by_agent_id)
    |> unique_constraint([:clip_id, :rev])
  end
end
