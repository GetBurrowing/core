defmodule Platform.Repo.Migrations.AddRejectionToSocialPosts do
  @moduledoc """
  A human's rejection of a post (task 01a140a9-4c70, Social 4/7): adds
  `rejection_reason` (text) and `rejected_at` to `social_posts`. Both are
  nullable and the change is additive. The version, 20261015190851, is the
  one the stack reserved for this member.

  These columns are written ONLY by Social 3/7's human reject path. Agents
  read them through the `social_post_list` tool, so an agent can see what was
  rejected and why. No agent path and no general cast list writes them.

  DECISION: a dedicated column, not the existing `error` column. `error` is
  the publisher's failure text (Social 2/7). Conflating "a human said no"
  with "the network said no" would mislead the agent reading the post.
  """

  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      add(:rejection_reason, :text)
      add(:rejected_at, :utc_datetime_usec)
    end
  end
end
