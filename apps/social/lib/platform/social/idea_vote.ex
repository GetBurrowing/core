defmodule Platform.Social.IdeaVote do
  @moduledoc "One authenticated actor's interest in an idea. Ownership fields are set by IdeaVotes."
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "social_idea_votes" do
    belongs_to(:idea, Platform.Social.Idea)
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:profile, Platform.Social.Profile)
    belongs_to(:voter_user, Platform.Accounts.User)
    belongs_to(:voter_agent, Platform.Agents.Agent)
    timestamps(updated_at: false)
  end
end
