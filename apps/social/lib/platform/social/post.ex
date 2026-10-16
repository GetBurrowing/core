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

    timestamps()
  end

  @editable ~w(body media_file_ids link_url scheduled_at status external_url external_id error
               task_id meeting_id segment_ids episode_url start_s end_s)a

  # Social 2/7: the AI-disclosure flags and per-file media facts.
  @publisher_fields ~w(is_aigc ai_disclosure generated_by_agent_id media_meta)a

  @doc "Accepted `status` values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

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
    |> force_aigc_for_agent_media()
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_approved_has_approver()
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

  @max_body 10_000
  @max_reason 2_000

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
    |> check_constraint(:approved_by_user_id,
      name: :social_posts_approved_needs_approver_check,
      message: "is required once a post is approved, scheduled or published"
    )
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:approved_by_user_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:meeting_id)
    |> foreign_key_constraint(:generated_by_agent_id)
  end
end
