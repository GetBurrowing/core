defmodule Platform.Meetings.Whiteboard do
  @moduledoc """
  Schema for the `meeting_whiteboards` table — one Excalidraw scene per
  meeting (task 019fcfcf stage 1).

  `scene` holds the whole `.excalidraw` payload (`elements`, the
  persisted `appState` subset, `files`). `scene_version` is a monotonic
  counter used for compare-and-set on save: v1 is SINGLE-EDITOR, so the
  counter exists to make a lost update *detectable*, not mergeable.
  There is no reconciler.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "meeting_whiteboards" do
    belongs_to(:meeting, Platform.Meetings.Meeting)
    belongs_to(:last_edited_by_user, Platform.Accounts.User)

    field(:scene, :map, default: %{})
    field(:scene_version, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating or replacing a scene.

  `scene_version` is cast rather than derived here because the caller
  (`Platform.Meetings.upsert_whiteboard_scene/4`) computes it inside a
  transaction that has already re-read the row — the increment is part
  of the compare-and-set, not a property of an unattached struct.
  """
  def changeset(whiteboard, attrs) do
    whiteboard
    |> cast(attrs, [:meeting_id, :last_edited_by_user_id, :scene, :scene_version])
    |> validate_required([:meeting_id, :scene, :scene_version])
    |> validate_number(:scene_version, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:meeting_id)
    |> foreign_key_constraint(:last_edited_by_user_id)
    |> unique_constraint(:meeting_id)
  end
end
