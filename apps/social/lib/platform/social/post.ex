defmodule Platform.Social.Post do
  @moduledoc """
  A post drafted for a `Platform.Social.Account` (task 01a140a8).

  `approved_by_user_id` and `approved_at` are in NO general cast list: only
  `approval_changeset/2`, called by `Platform.Social.approve_post/3`, sets
  them. Two layers keep an agent from approving: the context looks the id up
  as a user, and the column is a FK to `users` (agents are a separate table).
  A DB CHECK refuses `approved`, `scheduled` or `published` without both.

  Source refs (`task_id`, `meeting_id`, `segment_ids`, `episode_url`,
  `start_s`, `end_s`) are for the meeting bridge (Social 6/7); deleting the
  task or meeting nils the ref and keeps the post.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(draft needs_approval approved scheduled published failed)
  @approved_statuses ~w(approved scheduled published)

  # Social Studio (slice A). A post is `legacy` (every pre-Studio row and every
  # row a legacy writer inserts) or `studio`. `flow` is in NO cast list: only
  # `studio_changeset/2`'s caller sets it, on the struct, at insert, and
  # nothing changes it afterwards. A Studio row is confined to
  # `@studio_statuses` and holds no vendor id (DB CHECKs, the second line of
  # defence behind the code refusals on every send-side path).
  @max_body 10_000
  @max_reason 2_000

  @duplicate_destination "duplicate_destination"
  @flows ~w(legacy studio)
  @studio_statuses ~w(draft needs_approval approved planned)
  @studio_creatable ~w(draft needs_approval)

  @type t :: %__MODULE__{}

  schema "social_posts" do
    belongs_to(:account, Platform.Social.Account)

    field(:body, :string)
    field(:media_file_ids, {:array, :binary_id}, default: [])
    field(:link_url, :string)
    field(:scheduled_at, :utc_datetime_usec)
    field(:status, :string, default: "draft")

    belongs_to(:approved_by_user, Platform.Accounts.User)
    field(:approved_at, :utc_datetime_usec)

    field(:external_url, :string)
    field(:external_id, :string)
    field(:error, :string)

    # A human's rejection (Social 4/7 migration). In NO cast list: only
    # Social 3/7's reject changeset sets them; agents only read them.
    field(:rejection_reason, :string)
    field(:rejected_at, :utc_datetime_usec)

    belongs_to(:task, Platform.Tasks.Task)
    belongs_to(:meeting, Platform.Meetings.Meeting)
    field(:segment_ids, {:array, :string}, default: [])
    field(:episode_url, :string)
    field(:start_s, :float)
    field(:end_s, :float)

    # Publisher columns (Social 2/7).
    field(:is_aigc, :boolean, default: false)
    field(:ai_disclosure, :string)
    belongs_to(:generated_by_agent, Platform.Agents.Agent)
    field(:media_meta, :map, default: %{})

    # A video post's cover (task 01a165ec stage 2): an uploaded image OR a
    # frame, one at a time (`Platform.Social.Cover`). No FK into core's
    # tables, as for media_file_ids. `cover_error` is the publisher's.
    field(:cover_file_id, :binary_id)
    field(:cover_offset_ms, :integer)
    field(:cover_error, :string)

    # Why an approved post did not go out (task 01a165f1). In NO cast list:
    # only `refusal_changeset/4`, called by `Platform.Social.Publishing`,
    # sets them, and every success or terminal write clears them.
    field(:refused_reason, :string)
    field(:refused_at, :utc_datetime_usec)
    field(:retry_after, :utc_datetime_usec)

    # Clip Studio 2/9 (task 01a16662). In NO cast list (not @editable, not
    # @publisher_fields, not AgentDrafts' @castable): `clip_id` and
    # `publish_after` are written only by the human approve path, and
    # `publish_attempts`, `platform_post_id` and `published_at` only by
    # `Platform.Social.Publishing`. `external_id` stays the vendor's post id;
    # `platform_post_id` is the platform's own id for it.
    belongs_to(:clip, Platform.Social.Clip)
    # Immutable approval selection; never cast from an agent or post editor.
    belongs_to(:clip_render, Platform.Social.ClipRender)
    field(:platform_post_id, :string)
    field(:publish_after, :utc_datetime_usec)
    field(:publish_attempts, :integer, default: 0)
    field(:published_at, :utc_datetime_usec)

    # Clip Studio 9/9: vendor snapshots, owned by the analytics sync only.
    # Absent views are different from zero. Never cast from editors/agents.
    field(:analytics_external_id, :string)
    field(:metrics, :map, default: %{})
    field(:metrics_synced_at, :utc_datetime_usec)

    # Social authoring 2/11 (task 01a16c4e). In NO cast list: set only by
    # `Platform.Social.AgentDrafts` (checked against the idea's org and
    # profile) and `Platform.Social.ClipDecisions.approve_clip/5`. Nil is a
    # post that is its own one-post group.
    belongs_to(:idea, Platform.Social.Idea)

    # Social authoring 5/11 (task 01a16c50): why this time was suggested,
    # shown under the suggested time on the Queue's idea card.
    field(:schedule_reason, :string)

    # Composer 1/5 (task 01a14aca): post-side facts of a composed post
    # (platform, prompt slug, composition id, edited?, edit count before
    # send), nil for every other post. Never the experiment arm: that is on
    # the Experiments.Assignment row for the composition.
    field(:composer_provenance, :map)

    # Social authoring 7/11 (task 01a16c50-ea67): the version's platform
    # options (`Platform.Social.PlatformOptions`). In NO cast list: only
    # `options_changeset/2`, called by `Platform.Social.set_platform_options/4`.
    field(:platform_options, :map, default: %{})

    # Social Studio (slice A). In NO cast list.
    field(:flow, :string, default: "legacy")
    field(:version, :integer, default: 1)
    field(:state_rev, :integer, default: 0)
    # The destination named at creative acceptance: written once, never cast.
    field(:accepted_account_id, :binary_id)
    belongs_to(:planned_by_user, Platform.Accounts.User)
    field(:planned_set_at, :utc_datetime_usec)

    timestamps()
  end

  @editable ~w(body media_file_ids link_url scheduled_at status external_url external_id error
               task_id meeting_id segment_ids episode_url start_s end_s
               cover_file_id cover_offset_ms cover_error schedule_reason)a

  # Social 2/7: the AI-disclosure flags and per-file media facts.
  @publisher_fields ~w(is_aigc ai_disclosure generated_by_agent_id media_meta)a

  @max_schedule_reason 280

  @doc "The longest accepted `schedule_reason` (Social authoring 5/11)."
  @spec max_schedule_reason() :: pos_integer()
  def max_schedule_reason, do: @max_schedule_reason

  @refused_reasons ~w(media_rejected rate_limited account_archived publisher_not_configured)

  @doc "Accepted `refused_reason` values."
  @spec refused_reasons() :: [String.t()]
  def refused_reasons, do: @refused_reasons

  # Composer 1/5: written once, by `Platform.Social.Composer.send/4`.
  @composer_fields ~w(composer_provenance)a

  @doc "Accepted `status` values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Accepted `flow` values."
  @spec flows() :: [String.t()]
  def flows, do: @flows

  @doc "The statuses a Studio post can hold (the DB boundary CHECK)."
  @spec studio_statuses() :: [String.t()]
  def studio_statuses, do: @studio_statuses

  @doc "Whether the post belongs to the Studio flow."
  @spec studio?(t() | term()) :: boolean()
  def studio?(%__MODULE__{flow: "studio"}), do: true
  def studio?(_), do: false

  @doc """
  The ONLY creation changeset for a Studio post (`Platform.Social.Studio`).
  Casts the content fields a human drafts, allows only `draft` and
  `needs_approval`, and never casts `flow`, `version`, the plan columns or
  the approver. The caller sets `flow: "studio"` on the struct.
  """
  @spec studio_create_changeset(t(), map()) :: Ecto.Changeset.t()
  def studio_create_changeset(%__MODULE__{} = post, attrs) do
    post
    |> cast(attrs, ~w(body media_file_ids link_url status)a)
    |> cast(attrs, @publisher_fields)
    |> validate_required([:body, :status])
    |> validate_inclusion(:status, @studio_creatable)
    |> validate_length(:body, max: @max_body)
    |> unique_constraint(:account_id,
      name: :social_posts_studio_destination_key,
      message: @duplicate_destination
    )
    |> db_constraints()
  end

  @studio_content ~w(body media_file_ids link_url cover_file_id cover_offset_ms platform_options
                     is_aigc ai_disclosure)a

  @doc "The content fields `Platform.Social.Studio.save_version/5` accepts (plus `account_id`)."
  @spec studio_content_fields() :: [atom()]
  def studio_content_fields, do: @studio_content

  @doc """
  The changes a Studio version save would make to `post`: only the content
  fields that really differ (an empty map means nothing to save). Validated
  against a copy of the post in an editable status, because the legacy
  cover rule locks past `needs_approval`, while a Studio edit of an approved
  post is allowed and revokes the approval instead. Returns
  `{:ok, changes}` or `{:error, changeset}`.
  """
  @spec studio_content_changes(t(), map(), Platform.Social.Cover.ctx()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def studio_content_changes(%__MODULE__{} = post, attrs, ctx) do
    validated =
      %{post | status: "draft"}
      |> cast(attrs, @studio_content)
      |> validate_required([:body])
      |> validate_length(:body, max: @max_body)
      |> Platform.Social.Cover.validate(attrs, ctx)

    if validated.valid?, do: {:ok, validated.changes}, else: {:error, validated}
  end

  @doc """
  Whether `changeset` failed on the one-Studio-post-per-render-and-destination
  index (`social_posts_studio_destination_key`); callers answer
  `{:error, :duplicate_destination}`.
  """
  @spec duplicate_destination?(Ecto.Changeset.t()) :: boolean()
  def duplicate_destination?(%Ecto.Changeset{errors: errors}) do
    match?({@duplicate_destination, _}, errors[:account_id])
  end

  @doc "Statuses a post may hold only once a human has approved it."
  @spec approved_statuses() :: [String.t()]
  def approved_statuses, do: @approved_statuses

  @doc """
  Changeset for the editable fields. `account_id` is set by
  `Platform.Social`; `approved_by_user_id` / `approved_at` only by
  `approval_changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = post, attrs) do
    post
    |> cast(attrs, @editable)
    |> cast(attrs, @publisher_fields)
    |> cast(attrs, @composer_fields)
    |> force_aigc_for_agent_media()
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:schedule_reason, max: @max_schedule_reason)
    |> validate_approved_has_approver()
    |> Platform.Social.Cover.validate(attrs)
    |> db_constraints()
  end

  @doc """
  The ONLY changeset that writes `platform_options` (Social authoring 7/11):
  `options` already cleaned by `Platform.Social.PlatformOptions.validate/2`.
  """
  @spec options_changeset(t(), map()) :: Ecto.Changeset.t()
  def options_changeset(%__MODULE__{} = post, options) when is_map(options),
    do: change(post, platform_options: options)

  @doc """
  The human path's cover edit (`Platform.Social.set_cover/4`): casts ONLY
  the cover fields, optionally backfills the video's duration from the
  browser (`duration_ms`, only when none is known), then runs the one cover
  rule, `Platform.Social.Cover.validate/3`.
  """
  @spec cover_changeset(t(), map(), Platform.Social.Cover.ctx()) :: Ecto.Changeset.t()
  def cover_changeset(%__MODULE__{} = post, attrs, ctx \\ nil) do
    duration_ms = Map.get(attrs, :duration_ms, Map.get(attrs, "duration_ms"))

    post
    |> cast(attrs, Platform.Social.Cover.fields())
    |> Platform.Social.Cover.backfill_duration(duration_ms, ctx)
    |> Platform.Social.Cover.validate(attrs, ctx)
    |> db_constraints()
  end

  # A post whose media an agent generated is AI-generated content: while
  # `generated_by_agent_id` is set, `is_aigc` is forced true and can never be
  # cleared through attrs.
  defp force_aigc_for_agent_media(changeset) do
    if get_field(changeset, :generated_by_agent_id),
      do: put_change(changeset, :is_aigc, true),
      else: changeset
  end

  # Mirrors the DB CHECK, so a general update that moves an unapproved post
  # to approved/scheduled/published fails as a changeset error first.
  defp validate_approved_has_approver(changeset) do
    if get_field(changeset, :status) in @approved_statuses and
         (is_nil(get_field(changeset, :approved_by_user_id)) or
            is_nil(get_field(changeset, :approved_at))),
       do: add_error(changeset, :status, "requires a human approval first"),
       else: changeset
  end

  @doc """
  The ONLY changeset that sets the approver: `approved_by_user_id`,
  `approved_at` and status `approved`. The caller (`Platform.Social`) has
  already checked the id is a human user; the FK is the second layer.
  """
  @spec approval_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def approval_changeset(%__MODULE__{} = post, approver_user_id) do
    post
    |> change(
      approved_by_user_id: approver_user_id,
      approved_at: DateTime.utc_now(),
      status: "approved"
    )
    |> validate_required([:approved_by_user_id, :approved_at])
    |> db_constraints()
  end

  @doc """
  The ONLY writer of `refused_reason` / `refused_at` / `retry_after`
  (task 01a165f1): `Platform.Social.Publishing.publish_post/2` refused this
  approved post before the vendor. Sets the reason, `refused_at` (now), the
  plain-sentence `error` and `retry_after` (nil unless rate limited). The
  status is left alone: the post stays `approved`.
  """
  @spec refusal_changeset(t(), String.t(), String.t(), DateTime.t() | nil) ::
          Ecto.Changeset.t()
  def refusal_changeset(%__MODULE__{} = post, reason, error, retry_after) do
    post
    |> change(
      refused_reason: reason,
      refused_at: DateTime.utc_now(),
      error: error,
      retry_after: retry_after
    )
    |> validate_inclusion(:refused_reason, @refused_reasons)
    |> check_constraint(:refused_reason, name: :social_posts_refused_reason_check)
    |> db_constraints()
  end

  @doc """
  The changes that clear a recorded refusal. Every success or terminal write
  (`scheduled`, `published`, `failed`) merges these in.
  """
  @spec refusal_cleared() :: keyword()
  def refusal_cleared, do: [refused_reason: nil, refused_at: nil, retry_after: nil]

  @doc """
  A human approver's edit on the approval card (Social 3/7): casts ONLY
  `body`. The status stays `needs_approval`.
  """
  @spec human_edit_changeset(t(), map()) :: Ecto.Changeset.t()
  def human_edit_changeset(%__MODULE__{} = post, attrs) do
    post
    |> cast(attrs, [:body])
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body)
    |> db_constraints()
  end

  @doc """
  A human's rejection (Social 3/7), the ONLY writer of member 4's
  `rejection_reason` / `rejected_at`. Casts only `rejection_reason`
  (required, at most #{@max_reason} characters), stamps `rejected_at`, and
  moves the post to `draft`: the status list has no `rejected`, and `draft`
  lets the drafting agent revise and resubmit through
  `Platform.Social.AgentDrafts`. "Rejected" is therefore `rejected?/1`, never
  a status.
  """
  @spec reject_changeset(t(), String.t() | nil) :: Ecto.Changeset.t()
  def reject_changeset(%__MODULE__{} = post, reason) do
    post
    |> cast(%{rejection_reason: reason}, [:rejection_reason])
    |> update_change(:rejection_reason, &String.trim/1)
    |> validate_required([:rejection_reason])
    |> validate_length(:rejection_reason, max: @max_reason)
    |> put_change(:rejected_at, DateTime.utc_now())
    |> put_change(:status, "draft")
    |> db_constraints()
  end

  @doc "The longest accepted rejection reason."
  @spec max_rejection_reason() :: pos_integer()
  def max_rejection_reason, do: @max_reason

  @doc """
  Whether a human rejected this post and it has not been resubmitted: a
  `draft` with `rejected_at` set. The one definition every caller uses.
  """
  @spec rejected?(t()) :: boolean()
  def rejected?(%__MODULE__{status: "draft", rejected_at: %DateTime{}}), do: true
  def rejected?(%__MODULE__{}), do: false

  defp db_constraints(changeset) do
    changeset
    |> check_constraint(:status, name: :social_posts_status_check)
    |> check_constraint(:status, name: :social_posts_planned_only_studio_check)
    |> check_constraint(:status, name: :social_posts_studio_boundary_check)
    |> check_constraint(:version, name: :social_posts_version_check)
    |> check_constraint(:state_rev, name: :social_posts_state_rev_check)
    |> check_constraint(:approved_by_user_id,
      name: :social_posts_approved_needs_approver_check,
      message: "is required once a post is approved, scheduled or published"
    )
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:approved_by_user_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:meeting_id)
    |> foreign_key_constraint(:generated_by_agent_id)
    |> foreign_key_constraint(:clip_id)
    |> foreign_key_constraint(:idea_id)
    |> check_constraint(:publish_attempts,
      name: :social_posts_publish_attempts_check,
      message: "must not be negative"
    )
  end
end
