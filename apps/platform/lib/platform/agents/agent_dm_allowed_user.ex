defmodule Platform.Agents.AgentDmAllowedUser do
  @moduledoc """
  Ecto schema for `agent_dm_allowed_users`: the "specific people" list behind
  an agent's `dm_policy` (task 01a19776).

  One row means "`user_id` may DM `agent_id` while that agent's policy is
  `specific`". Rows survive a policy change so flipping back restores the
  list. Written only through `Platform.Agents.DmAccess.set_policy/4`.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_dm_allowed_users" do
    belongs_to(:agent, Platform.Agents.Agent)
    belongs_to(:user, Platform.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end
end
