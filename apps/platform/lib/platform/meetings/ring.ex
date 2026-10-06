defmodule Platform.Meetings.Ring do
  @moduledoc """
  One ring of one user for one meeting (task 01a10db7 stage 2): a PushKit VoIP
  push the iOS app reports to CallKit as an incoming call. Written and moved
  through its states by `Platform.Meetings.Ringing`.

    * `trigger` — `meeting_started` or `live_invite`;
    * `state` — `ringing`, then exactly one of `answered`, `declined`,
      `missed` or `cancelled`. Every transition is a compare-and-set on
      `state = 'ringing'`, so a ring settles once.

  A ring carries ids only. It never holds a device token or a LiveKit token.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @triggers ~w(meeting_started live_invite)
  @states ~w(ringing answered declined missed cancelled)

  schema "meeting_rings" do
    belongs_to(:meeting, Platform.Meetings.Meeting)
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:inviter_user, Platform.Accounts.User)
    field(:trigger, :string)
    field(:state, :string, default: "ringing")
    field(:answered_at, :utc_datetime_usec)
    field(:declined_at, :utc_datetime_usec)
    field(:missed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def triggers, do: @triggers
  def states, do: @states

  def changeset(ring, attrs) do
    ring
    |> cast(attrs, [:meeting_id, :user_id, :inviter_user_id, :trigger, :state])
    |> validate_required([:meeting_id, :user_id, :trigger, :state])
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:state, @states)
    |> foreign_key_constraint(:meeting_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:inviter_user_id)
  end
end
