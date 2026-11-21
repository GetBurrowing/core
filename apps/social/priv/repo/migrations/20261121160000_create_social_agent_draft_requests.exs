defmodule Platform.Repo.Migrations.CreateSocialAgentDraftRequests do
  @moduledoc """
  Retry safety for the agent tool `social_studio_draft_create`: one row per
  (agent, account, request id), pointing at the Studio draft that request
  created. A Studio post is one post on one account, so the key is the
  destination account, not the profile: the same request id on another
  account is another draft. The unique index is what makes a retry, even a concurrent one,
  return the one draft rather than a second. `content_hash` lets a repeat
  tell the same request from a reused id with different content.

  Ships with Social as a build-time module's migration (ADR 0055). Rolling
  back drops the table and keeps every post; a retry after a rollback and a
  re-apply would make a new draft.
  """
  use Ecto.Migration

  # old-code-compatible: creates a new table only (its unique index is on that new table);
  # no existing table changes and the previous release neither reads nor writes it.
  def change do
    create table(:social_agent_draft_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)

      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:post_id, references(:social_posts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:request_id, :text, null: false)
      add(:content_hash, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:social_agent_draft_requests, [:agent_id, :account_id, :request_id]))
    create(index(:social_agent_draft_requests, [:post_id]))

    create(
      constraint(:social_agent_draft_requests, :social_agent_draft_requests_request_id_check,
        check: "length(request_id) BETWEEN 1 AND 200"
      )
    )
  end
end
