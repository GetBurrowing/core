defmodule Platform.Chat.AttentionState do
  @moduledoc """
  Tracks per-agent engagement state within a chat space.

  States:
    * `"idle"`         — default, agent responds based on space attention mode
    * `"engaged"`      — sticky engagement after @mention or directed interaction
    * `"silenced"`     — agent will not respond until re-mentioned or timeout
    * `"observe_only"` — agent monitors but does not respond
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(idle engaged silenced observe_only)

  schema "chat_attention_state" do
    field(:space_id, :binary_id)
    field(:agent_participant_id, :binary_id)
    field(:state, :string, default: "idle")
    field(:engaged_since, :utc_datetime_usec)
    field(:engaged_context, :string)
    field(:silenced_until, :utc_datetime_usec)
    field(:last_triage_at, :utc_datetime_usec)
    field(:triage_buffer_start_id, :binary_id)
    field(:metadata, :map, default: %{})
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(attention_state, attrs) do
    attention_state
    |> cast(attrs, [
      :space_id,
      :agent_participant_id,
      :state,
      :engaged_since,
      :engaged_context,
      :silenced_until,
      :last_triage_at,
      :triage_buffer_start_id,
      :metadata,
      :updated_at
    ])
    |> validate_required([:space_id, :agent_participant_id, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:space_id, :agent_participant_id],
      name: :chat_attention_state_space_agent
    )
  end
end
