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

  Clip Studio 1/9 (task 01a16661-e234) adds:

    * `title` (max 200) and `episode_code` (max 32), both nullable: under
      the clip tool's `[privacy] mode = "local"` nothing transcript-derived
      arrives.
    * `origin`: `burrow` (rendered here; exactly one footage source) or
      `external` (rendered outside Burrow and submitted by an agent with
      `submit_changeset/2`; no footage source). `source_label` names where.
    * the review state, `review_status` (`pending` | `approved` |
      `rejected`; nil before a first render), `review_note`,
      `reviewed_by_user_id`, `reviewed_at`. `review_changeset/2` is their
      ONLY writer; no agent path ever sets them.
    * `rev`, `look` (`Platform.Social.ClipLook`), `trim_in_s`/`trim_out_s`:
      the rendered version and what it was rendered with. One
      `Platform.Social.ClipRender` row per rev. Written by the render
      contexts, never cast from `changeset/2` attrs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(candidate rendering rendered failed)
  @origins ~w(burrow external)
  @review_statuses ~w(pending approved rejected)

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

    # Clip Studio 1/9: metadata, origin, review state, versions and look.
    field(:title, :string)
    field(:episode_code, :string)
    field(:origin, :string, default: "burrow")
    field(:source_label, :string)
    field(:review_status, :string)
    field(:review_note, :string)
    belongs_to(:reviewed_by_user, Platform.Accounts.User)
    field(:reviewed_at, :utc_datetime_usec)
    belongs_to(:submitted_by_agent, Platform.Agents.Agent)
    field(:rev, :integer, default: 1)
    field(:look, :map, default: %{})
    field(:trim_in_s, :float)
    field(:trim_out_s, :float)

    has_many(:renders, Platform.Social.ClipRender)

    timestamps()
  end

  @editable ~w(source_url start_s end_s caption speaker render_file_id status
               source_file_id transcript_file_id crop_x platforms title episode_code)a

  # Written only by the render queue (Social 5/7), never from agent attrs.
  @render_fields ~w(status start_s end_s requested_start_s requested_end_s duration_s
                    width height byte_size render_file_id error attempts
                    render_started_at rendered_at platforms)a

  # Clip Studio 1/9: what an agent's externally rendered clip may carry.
  # Never the review fields, rev or origin.
  @submit_fields ~w(title caption speaker episode_code source_label platforms render_file_id
                    duration_s width height byte_size look)a

  @doc "Accepted `status` values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Accepted `origin` values."
  @spec origins() :: [String.t()]
  def origins, do: @origins

  @doc "Accepted `review_status` values (nil is also allowed: never rendered)."
  @spec review_statuses() :: [String.t()]
  def review_statuses, do: @review_statuses

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
    |> validate_meta()
    |> clip_constraints()
  end

  @doc """
  Clip Studio 1/9: a clip rendered OUTSIDE Burrow (htc-clip-tool), submitted
  by an agent. Casts only the metadata, the platforms, the rendered file and
  its measurements, and the look; forces `origin` external, `status`
  rendered, `review_status` pending, `rev` 1 and `rendered_at` now. Title,
  caption, speaker and episode code may all be nil. `profile_id` and
  `submitted_by_agent_id` are set by the caller, never cast.
  """
  @spec submit_changeset(t(), map()) :: Ecto.Changeset.t()
  def submit_changeset(%__MODULE__{} = clip, attrs) do
    clip
    |> cast(attrs, @submit_fields)
    |> put_change(:origin, "external")
    |> put_change(:status, "rendered")
    |> put_change(:review_status, "pending")
    |> put_change(:rev, 1)
    |> put_change(:rendered_at, DateTime.utc_now())
    |> validate_required([:render_file_id])
    |> validate_meta()
    |> validate_one_source()
    |> validate_look()
    |> clip_constraints()
  end

  @doc """
  Clip Studio 1/9: the ONLY writer of `review_status`, `review_note`,
  `reviewed_by_user_id` and `reviewed_at`. Accepts a clip or a changeset
  (so a render changeset can be followed by `:reset_pending`).

    * `{:approve, user_id}`: approved, by that user, now; the note is cleared.
    * `{:reject, user_id, note}`: rejected, by that user, now; the note is
      trimmed, required and at most 2000 characters.
    * `:reset_pending`: pending, clearing note, reviewer and reviewed_at
      (a new render goes back to review).

  The reviewer must be a user (FK to `users`); whether that user may
  approve this profile is the caller's rule.
  """
  @spec review_changeset(t() | Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def review_changeset(clip_or_changeset, decision)

  def review_changeset(clip, {:approve, user_id}) do
    clip
    |> change(%{
      review_status: "approved",
      review_note: nil,
      reviewed_by_user_id: user_id,
      reviewed_at: DateTime.utc_now()
    })
    |> review_validations()
  end

  def review_changeset(clip, {:reject, user_id, note}) do
    clip
    |> change(%{
      review_status: "rejected",
      review_note: if(is_binary(note), do: String.trim(note)),
      reviewed_by_user_id: user_id,
      reviewed_at: DateTime.utc_now()
    })
    |> update_change(:review_note, &blank_to_nil/1)
    |> validate_required([:review_note], message: "a rejection needs a note")
    |> validate_length(:review_note, max: 2000)
    |> review_validations()
  end

  def review_changeset(clip, :reset_pending) do
    clip
    |> change(%{
      review_status: "pending",
      review_note: nil,
      reviewed_by_user_id: nil,
      reviewed_at: nil
    })
    |> review_validations()
  end

  defp review_validations(changeset) do
    changeset =
      if get_field(changeset, :review_status) in ["approved", "rejected"],
        do: validate_required(changeset, [:reviewed_by_user_id, :reviewed_at]),
        else: changeset

    clip_constraints(changeset)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: s)

  defp validate_meta(changeset) do
    changeset
    |> validate_length(:title, max: 200)
    |> validate_length(:episode_code, max: 32)
  end

  defp validate_look(changeset) do
    validate_change(changeset, :look, fn :look, look ->
      case Platform.Social.ClipLook.validate(look) do
        {:ok, _} -> []
        {:error, messages} -> [look: Enum.join(messages, "; ")]
      end
    end)
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
    |> check_constraint(:origin, name: :social_clips_origin_check)
    |> check_constraint(:review_status, name: :social_clips_review_status_check)
    |> check_constraint(:rev, name: :social_clips_rev_check, message: "must be at least 1")
    |> check_constraint(:trim_out_s,
      name: :social_clips_trim_check,
      message: "trim_in_s must be >= 0 and trim_out_s after it"
    )
    |> check_constraint(:reviewed_at,
      name: :social_clips_review_needs_reviewer_check,
      message: "an approved or rejected clip needs reviewed_at"
    )
    |> check_constraint(:review_note,
      name: :social_clips_reject_needs_note_check,
      message: "a rejection needs a note"
    )
    |> foreign_key_constraint(:reviewed_by_user_id)
    |> foreign_key_constraint(:submitted_by_agent_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:render_file_id)
    |> foreign_key_constraint(:source_file_id)
    |> foreign_key_constraint(:transcript_file_id)
  end

  # Clip Studio 1/9: origin-aware. An external clip names no footage; a
  # Burrow clip names exactly one source.
  defp validate_one_source(changeset) do
    if get_field(changeset, :origin) == "external",
      do: validate_no_source(changeset),
      else: validate_burrow_source(changeset)
  end

  defp validate_no_source(changeset) do
    case {get_field(changeset, :source_url), get_field(changeset, :source_file_id)} do
      {nil, nil} -> changeset
      _ -> add_error(changeset, :source_url, "an external clip names no source")
    end
  end

  defp validate_burrow_source(changeset) do
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
