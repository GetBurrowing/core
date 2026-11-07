defmodule Platform.GameStream.NativeSessionRecord do
  @moduledoc "Durable native mode of Play; no secrets in public status."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "native_play_sessions" do
    field :channel_id, :binary_id
    field :project_id, :binary_id
    field :build_id, :string
    field :immutable_build, :map
    field :protocol_version, :integer
    field :server_image, :string
    field :host_runtime_id, :string
    field :host_handle, :string
    field :host_credential_hash, :string, redact: true
    field :generation, :integer, default: 1
    field :state, :string, default: "starting"
    field :endpoint, :string
    field :reason, :string
    field :capacity, :integer
    field :heartbeat_at, :utc_datetime_usec
    field :idle_since, :utc_datetime_usec
    field :idle_timeout_s, :integer, default: 600
    field :experiment_id, :binary_id
    field :variant_slug, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :duration_s, :integer, default: 0
    field :idle_seconds, :integer, default: 0
    field :player_seconds, :integer, default: 0
    field :reconnect_attempts, :integer, default: 0
    field :connect_count, :integer, default: 0
    field :reconnect_count, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end
