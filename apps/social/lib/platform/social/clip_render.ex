defmodule Platform.Social.ClipRender do
  @moduledoc """
  One rendered version (`rev`) of a `Platform.Social.Clip` (Clip Studio 1/9,
  task 01a16661-e234): the file it produced and the look and trim it was
  rendered with. A clip keeps its id across re-renders; each new rev adds a
  row here and earlier rows are never rewritten. Unique per `(clip_id, rev)`.

  Human removal tombstones the review entry and retains this row and its
  completion identity. Administrative clip teardown cascades renders; deleting
  a Files row nils `file_id` and keeps the snapshot.
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
    field(:requested_start_s, :float)
    field(:requested_end_s, :float)
    field(:actual_start_s, :float)
    field(:actual_end_s, :float)
    field(:headline, :string)
    field(:caption, :string)
    field(:caption_fixes, :map)
    field(:candidate_id, :string)
    field(:alternate_id, :string)
    field(:source, :map)
    field(:duration_s, :float)
    field(:width, :integer)
    field(:height, :integer)
    field(:byte_size, :integer)
    field(:provenance, :map)
    field(:completion_key, :string)
    field(:snapshot_status, :string, default: "recorded")
    belongs_to(:submitted_by_agent, Platform.Agents.Agent)

    # Removal hides review entries; immutable inputs, completion keys and media remain retained.
    field(:removed_at, :utc_datetime_usec)
    belongs_to(:removed_by_user, Platform.Accounts.User)

    timestamps()
  end

  @fields ~w(clip_id rev file_id look trim_in_s trim_out_s submitted_by_agent_id
             requested_start_s requested_end_s actual_start_s actual_end_s headline caption
             caption_fixes candidate_id alternate_id source duration_s width height byte_size
             provenance completion_key snapshot_status)a

  @doc "Changeset for a new render row. Written by the context, never from agent attrs."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = render, attrs) do
    render
    |> cast(attrs, @fields)
    |> validate_required([:clip_id, :rev, :look])
    |> validate_number(:rev, greater_than_or_equal_to: 1)
    |> validate_inclusion(:snapshot_status, ~w(recorded historical_unknown))
    |> validate_number(:requested_start_s, greater_than_or_equal_to: 0)
    |> validate_number(:actual_start_s, greater_than_or_equal_to: 0)
    |> validate_bounds(:requested_start_s, :requested_end_s)
    |> validate_bounds(:actual_start_s, :actual_end_s)
    |> foreign_key_constraint(:clip_id)
    |> foreign_key_constraint(:file_id)
    |> foreign_key_constraint(:submitted_by_agent_id)
    |> unique_constraint([:clip_id, :rev])
    |> unique_constraint([:clip_id, :completion_key])
  end

  defp validate_bounds(changeset, start_field, end_field) do
    case {get_field(changeset, start_field), get_field(changeset, end_field)} do
      {a, b} when is_number(a) and is_number(b) and b <= a ->
        add_error(changeset, end_field, "must be after start")

      _ ->
        changeset
    end
  end
end
