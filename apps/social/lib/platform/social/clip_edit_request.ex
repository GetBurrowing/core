defmodule Platform.Social.ClipEditRequest do
  @moduledoc "An editing instruction/history and its notification/return receipts, never a publishing decision."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "social_clip_edit_requests" do
    belongs_to(:clip, Platform.Social.Clip)
    belongs_to(:base_render, Platform.Social.ClipRender)
    field(:requested_by_user_id, :binary_id)
    field(:assigned_user_id, :binary_id)
    field(:assigned_agent_id, :binary_id)
    field(:position, :integer, read_after_writes: true)
    field(:note, :string)
    field(:client_request_id, :binary_id)
    field(:request_payload_hash, :string)
    field(:notification_status, :string)
    field(:notification_attempted_at, :utc_datetime_usec)
    field(:notification_message_id, :binary_id)
    belongs_to(:returned_render, Platform.Social.ClipRender)
    field(:returned_at, :utc_datetime_usec)
    timestamps()
  end
end
