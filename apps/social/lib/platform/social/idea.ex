defmodule Platform.Social.Idea do
  @moduledoc """
  One idea (Social authoring 2/11, task 01a16c4e): the record that groups
  one post per account. A post's `idea_id` points here; a post with none
  is its own one-post group downstream.

  `org_id`, `profile_id`, `created_by_user_id`, `created_by_agent_id` and
  `archived_at` are set by `Platform.Social.Ideas`, never cast. Exactly one
  creator is set at write (`creator/2`). There is no stage column: the stage
  is derived from the posts (`Platform.Social.Ideas.stage/1`), so it cannot
  drift from them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @source_kinds ~w(human agent chat clip task meeting url)
  @max_title 200

  @type t :: %__MODULE__{}

  schema "social_ideas" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:profile, Platform.Social.Profile)

    field(:title, :string)
    field(:brief, :string)
    field(:source_kind, :string)

    belongs_to(:recycled_from_idea, __MODULE__)

    belongs_to(:clip, Platform.Social.Clip)
    belongs_to(:task, Platform.Tasks.Task)
    belongs_to(:meeting, Platform.Meetings.Meeting)
    belongs_to(:message, Platform.Chat.Message)
    field(:source_url, :string)

    belongs_to(:created_by_user, Platform.Accounts.User)
    belongs_to(:created_by_agent, Platform.Agents.Agent)
    field(:archived_at, :utc_datetime_usec)

    has_many(:posts, Platform.Social.Post)

    timestamps()
  end

  @castable ~w(title brief source_kind clip_id task_id meeting_id message_id source_url)a

  @doc "Accepted `source_kind` values."
  @spec source_kinds() :: [String.t()]
  def source_kinds, do: @source_kinds

  @doc "The longest accepted title."
  @spec max_title() :: pos_integer()
  def max_title, do: @max_title

  @doc """
  Casts the content and source refs, and puts the creator: `{:user, id}` or
  `{:agent, id}` (exactly one is set).
  """
  @spec changeset(t(), map(), {:user | :agent, Ecto.UUID.t()}) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = idea, attrs, creator) do
    idea
    |> cast(attrs, @castable)
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title, :source_kind])
    |> validate_length(:title, max: @max_title)
    |> validate_inclusion(:source_kind, @source_kinds)
    |> creator(creator)
    |> check_constraint(:source_kind, name: :social_ideas_source_kind_check)
    |> check_constraint(:created_by_user_id, name: :social_ideas_one_creator_check)
    |> unique_constraint(:clip_id, name: :social_ideas_one_per_clip)
    |> unique_constraint(:recycled_from_idea_id)
    |> foreign_key_constraint(:recycled_from_idea_id)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:clip_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:meeting_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:created_by_agent_id)
  end

  defp creator(changeset, {:user, id}) when is_binary(id),
    do: change(changeset, created_by_user_id: id, created_by_agent_id: nil)

  defp creator(changeset, {:agent, id}) when is_binary(id),
    do: change(changeset, created_by_agent_id: id, created_by_user_id: nil)

  defp creator(changeset, _),
    do: add_error(changeset, :created_by_user_id, "exactly one creator is required")
end
