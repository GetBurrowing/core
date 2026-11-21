defmodule Platform.Social.AgentDraftRequest do
  @moduledoc """
  One agent request for a Studio draft (`Platform.Social.Studio.create_agent_draft/4`):
  who asked (`agent_id`), for which destination (`account_id`), under which
  caller-chosen `request_id`, with what content (`content_hash`), and the
  `post_id` it made. The unique index on (agent, account, request id) is the
  retry guard. Written only by `Studio.create_agent_draft/4`.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @type t :: %__MODULE__{}

  schema "social_agent_draft_requests" do
    field(:agent_id, :binary_id)
    field(:account_id, :binary_id)
    belongs_to(:post, Platform.Social.Post)
    field(:request_id, :string)
    field(:content_hash, :string)

    timestamps()
  end
end
