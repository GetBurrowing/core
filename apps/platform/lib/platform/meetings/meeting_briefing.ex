defmodule Platform.Meetings.MeetingBriefing do
  @moduledoc """
  The after-action briefing for one concluded meeting (task
  `01a1694a-676e-7000-a653-5e1e6db65205`). Built by
  `Platform.Meetings.MeetingBriefings.build/1`.

  ## One row per meeting, shared by every attendee

  `meeting_id` is unique: there is exactly ONE row per meeting, and every
  attendee's Inbox row points at it. Resolution is shared — when one attendee
  reverts or confirms an item, every other attendee sees it resolved —
  so the `receipts` map lives on this one row rather than on a row per
  person. That is the reason this is not a `Platform.Memory.Briefing`: that
  table is unique on `(user_id, digest_date)` and keeps each person's
  receipts on their own row, so a second attendee could never see the first
  one's action.

    * `attendee_user_ids` — the users the briefing is for
      (`Platform.Meetings.human_attendee_ids/1`), unioned across rebuilds,
      never shrunk.
    * `items` — node key → `%{"kind", "ref", "title", "filed_status"}`. Keys
      are stable digests of the item's ref, so a rebuild finds the same key
      for the same task or canvas. The reserved key `"_content"` holds the
      rebuilt-each-run content (open questions, unfiled action items, the
      transcript link) and is not an item.
    * `receipts` — node key → `%{"verb", "at", "by", "ref", "kind"}`, the
      same receipt shape the daily briefing uses. A rebuild never overwrites
      or removes a receipt.
      Items of kind `"finding"` are the exception: their receipt lives on
      the shared `Platform.Meetings.SynthesisFinding` row (task 01a16974),
      because one finding can sit in several meetings' briefings.
    * `summary` / `transcript_id` — from the meeting's newest completed
      transcript, nil until one exists.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "meeting_briefings" do
    belongs_to(:meeting, Platform.Meetings.Meeting)
    field(:attendee_user_ids, {:array, :binary_id}, default: [])
    field(:items, :map, default: %{})
    field(:receipts, :map, default: %{})
    field(:summary, :string)
    field(:transcript_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(briefing, attrs) do
    briefing
    |> cast(attrs, [:meeting_id, :attendee_user_ids, :items, :receipts, :summary, :transcript_id])
    |> validate_required([:meeting_id])
    |> foreign_key_constraint(:meeting_id)
    |> unique_constraint(:meeting_id, name: :meeting_briefings_meeting_id_index)
  end
end
