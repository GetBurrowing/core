defmodule Platform.Social.PostEvent do
  @moduledoc """
  One entry in a post's change log (Social authoring 2/11, task 01a16c4e):
  whether an agent, a human or the system did `action` to the post.

  Written ONLY by `Platform.Social.PostEvents.record!/3`, inside the same
  transaction as the state change it describes. Never from the UI, and
  never from a telemetry handler. `body_before` / `body_after` are only set
  for `edited` (a CHECK enforces it).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @actor_kinds ~w(agent human system)
  @actions ~w(created edited submitted approved rejected revision_requested published failed refused)

  @type t :: %__MODULE__{}

  schema "social_post_events" do
    belongs_to(:post, Platform.Social.Post)
    belongs_to(:idea, Platform.Social.Idea)
    field(:actor_kind, :string)
    field(:actor_id, :binary_id)
    field(:action, :string)
    field(:body_before, :string)
    field(:body_after, :string)
    field(:note, :string)

    timestamps()
  end

  @doc "Accepted `actor_kind` values."
  @spec actor_kinds() :: [String.t()]
  def actor_kinds, do: @actor_kinds

  @doc "Accepted `action` values."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = event, attrs) do
    event
    |> cast(attrs, ~w(post_id idea_id actor_kind actor_id action body_before body_after note)a)
    |> validate_required([:post_id, :actor_kind, :action])
    |> validate_inclusion(:actor_kind, @actor_kinds)
    |> validate_inclusion(:action, @actions)
    |> check_constraint(:actor_kind, name: :social_post_events_actor_kind_check)
    |> check_constraint(:action, name: :social_post_events_action_check)
    |> check_constraint(:body_before, name: :social_post_events_body_only_for_edited_check)
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:idea_id)
  end
end
