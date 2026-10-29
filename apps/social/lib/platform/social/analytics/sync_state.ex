defmodule Platform.Social.Analytics.SyncState do
  @moduledoc """
  Durable cursor and baseline checkpoint for one org (Clip Studio 9/9).

  Capture the cursor BEFORE starting the baseline, persist progress after
  each baseline post, then drain from that original cursor. Cursors are
  opaque; `syncedAt` is not an ordering key. The org primary key also gives
  the worker a single row to lock. Only the sync writes this schema.
  """
  use Ecto.Schema

  @primary_key {:org_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "social_analytics_sync_states" do
    field(:cursor, :string)
    field(:replay_cursor, :string)
    field(:retry_at, :utc_datetime_usec)
    field(:cursor_captured_at, :utc_datetime_usec)
    field(:bootstrap_after_post_id, :binary_id)
    field(:bootstrap_complete, :boolean, default: false)
    timestamps()
  end
end
