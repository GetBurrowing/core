defmodule Platform.Repo.Migrations.AddMutedAtToMeetingParticipants do
  @moduledoc """
  Task 01a0f842 stage 5, canvas 01a0f846-cfb1 (item 5, mute half): no agent
  mute control exists anywhere on main before this stage. `muted_at`
  mirrors `left_at`'s own shape exactly — a nullable timestamp, not a
  boolean — set by `Platform.Meetings.mute_agent_in_call/4` only AFTER
  `mute_livekit_published_track/3` confirms the real `MutePublishedTrack`
  Twirp RPC landed, and cleared (`nil`) on unmute. This is the durable
  record of a HOST ACTION, not a mirror of LiveKit's own live-reported
  `muted_identities` (that stays a transient, client-pushed fact folded
  into `MeetingLive`'s `media_states` handler) — the two can briefly
  disagree while LiveKit's own track-mute event propagates back to every
  connected client, and `muted_at` is what lets a reconnecting host (or a
  second host) see the LAST ACTION taken without waiting on that round
  trip. Additive, nullable, no default: every existing row reads
  `muted_at: nil`, i.e. "never muted by a host," which is the correct
  reading for every row that predates this stage.
  """

  use Ecto.Migration

  def change do
    alter table(:meeting_participants) do
      add(:muted_at, :utc_datetime_usec)
    end
  end
end
