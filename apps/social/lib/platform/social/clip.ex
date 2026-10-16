defmodule Platform.Social.Clip do
  @moduledoc """
  A clip candidate cut from one of a `Platform.Social.Profile`'s episodes
  (task 01a140a8; the pipeline that fills it is Social 5/7).

  `render_file_id` names the rendered file in core's Files; deleting the
  file nils it and keeps the clip. `end_s` must be after `start_s` when both
  are set (changeset and DB CHECK).

  Social 5/7 adds the pipeline: a clip's footage is EITHER `source_url` (a
  YouTube episode) OR `source_file_id` + `transcript_file_id` (a video and
  its transcript in Files), exactly one (changeset and DB CHECK).
  `requested_*` keep the agent's times; `start_s`/`end_s` become the
  sentence-snapped times the render used. `duration_s`, `width`, `height`
  and `byte_size` describe the rendered file, since `platform_files` stores
  no duration or dimensions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(candidate rendering rendered failed)

  @type t :: %__MODULE__{}

  schema "social_clips" do
    belongs_to(:profile, Platform.Social.Profile)

    field(:source_url, :string)
    field(:start_s, :float)
    field(:end_s, :float)
    field(:caption, :string)
    field(:speaker, :string)
    belongs_to(:render_file, Platform.Files.File)
    field(:status, :string, default: "candidate")

    # Social 5/7: the clip pipeline.
    belongs_to(:source_file, Platform.Files.File)
    belongs_to(:transcript_file, Platform.Files.File)
    field(:requested_start_s, :float)
    field(:requested_end_s, :float)
    field(:duration_s, :float)
    field(:width, :integer)
    field(:height, :integer)
    field(:byte_size, :integer)
    field(:platforms, {:array, :string}, default: [])
    field(:crop_x, :float, default: 0.5)
    field(:error, :string)
    field(:attempts, :integer, default: 0)
    field(:render_started_at, :utc_datetime_usec)
    field(:rendered_at, :utc_datetime_usec)

    timestamps()
  end

  @editable ~w(source_url start_s end_s caption speaker render_file_id status
               source_file_id transcript_file_id crop_x platforms)a

  # Written only by the render queue (Social 5/7), never from agent attrs.
  @render_fields ~w(status start_s end_s requested_start_s requested_end_s duration_s
                    width height byte_size render_file_id error attempts
                    render_started_at rendered_at platforms)a

  @doc "Accepted `status` values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for the editable fields. `profile_id` is set by `Platform.Social`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = clip, attrs) do
    clip
    |> cast(attrs, @editable)
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_span()
    |> validate_one_source()
    |> validate_number(:crop_x, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> clip_constraints()
  end

  @doc """
  The render queue's changeset (Social 5/7): status, snapped times, the
  render's measurements and bookkeeping. Never fed agent attrs.
  """
  @spec render_changeset(t(), map()) :: Ecto.Changeset.t()
  def render_changeset(%__MODULE__{} = clip, attrs) do
    clip
    |> cast(attrs, @render_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_span()
    |> clip_constraints()
  end

  defp clip_constraints(changeset) do
    changeset
    |> check_constraint(:status, name: :social_clips_status_check)
    |> check_constraint(:end_s, name: :social_clips_span_check, message: "must be after start_s")
    |> check_constraint(:source_url,
      name: :social_clips_one_source_check,
      message: "exactly one of source_url or source_file_id must be set"
    )
    |> check_constraint(:crop_x, name: :social_clips_crop_x_check, message: "must be 0..1")
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:render_file_id)
    |> foreign_key_constraint(:source_file_id)
    |> foreign_key_constraint(:transcript_file_id)
  end

  defp validate_one_source(changeset) do
    case {get_field(changeset, :source_url), get_field(changeset, :source_file_id)} do
      {nil, nil} ->
        add_error(
          changeset,
          :source_url,
          "exactly one of source_url or source_file_id must be set"
        )

      {url, file} when not is_nil(url) and not is_nil(file) ->
        add_error(
          changeset,
          :source_url,
          "exactly one of source_url or source_file_id must be set"
        )

      _ ->
        changeset
    end
  end

  defp validate_span(changeset) do
    start_s = get_field(changeset, :start_s)
    end_s = get_field(changeset, :end_s)

    if is_number(start_s) and is_number(end_s) and end_s <= start_s,
      do: add_error(changeset, :end_s, "must be after start_s"),
      else: changeset
  end
end
