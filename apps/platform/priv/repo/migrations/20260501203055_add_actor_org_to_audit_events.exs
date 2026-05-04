defmodule Platform.Repo.Migrations.AddActorOrgToAuditEvents do
  @moduledoc """
  Add `actor_org_id` to `audit_events` per ADR 0040 architect-finding-2.

  The original ADR proposal added `invoked_by_user_id` + `owner_org_id` to
  audit_events, mirroring the runtime_events dual-key pattern. The architect
  review correctly observed that audit_events already models actor identity
  via `actor_id` + `actor_type` — the right strategy is to **extend** the
  existing model with org scoping rather than duplicate the dual-key columns.

  This migration adds a single `actor_org_id` column and an index on
  `(actor_org_id, inserted_at)` to support per-org audit views.

  The `actor_type` enum (string column, application-side enum) is extended
  with the value `"federated_user"` — no DB change required since `actor_type`
  is `:string`. The canonical list is documented in
  `Platform.Audit.Event.@actor_types`.

  Reversible: rollback drops the column and index.
  """

  use Ecto.Migration

  def change do
    alter table(:audit_events) do
      add(:actor_org_id, :binary_id)
    end

    create(
      index(:audit_events, [:actor_org_id, :inserted_at],
        where: "actor_org_id IS NOT NULL",
        name: :audit_events_actor_org_id_idx
      )
    )

    execute(
      """
      COMMENT ON COLUMN audit_events.actor_org_id IS
        'Org owning the actor that produced this event. NULL for legacy rows and intra-org events. See ADR 0040.'
      """,
      "COMMENT ON COLUMN audit_events.actor_org_id IS NULL"
    )
  end
end
