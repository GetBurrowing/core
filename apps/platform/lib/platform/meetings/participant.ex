defmodule Platform.Meetings.Participant do
  @moduledoc """
  Schema for the `meeting_participants` table.

  Tracks each user or agent that joins a meeting room, including
  join/leave timestamps and arbitrary metadata (e.g. track info).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_participants" do
    belongs_to(:room, Platform.Meetings.Room)
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:agent, Platform.Agents.Agent)
    field(:display_name, :string)
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    # Task 01a0f842 stage 5: set by `Platform.Meetings.mute_agent_in_call/4`
    # only after the real LiveKit `MutePublishedTrack` RPC confirms, cleared
    # on unmute. See the `add_muted_at_to_meeting_participants` migration
    # for why this is a timestamp (mirroring `left_at`) and not a boolean.
    field(:muted_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :room_id,
      :user_id,
      :agent_id,
      :display_name,
      :joined_at,
      :left_at,
      :muted_at,
      :metadata
    ])
    |> validate_required([:room_id, :display_name, :joined_at])
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
  end
end
