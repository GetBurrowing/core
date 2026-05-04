defmodule Platform.Repo.Migrations.CreateInvocationVisibilityGrants do
  @moduledoc """
  Reserve the `invocation_visibility_grants` table per ADR 0040 architect-finding-3.

  The ADR's D2 deferred the cross-org delegated-visibility question ("can org A
  delegate visibility of an invocation back to a user in org B?"). Stage 2's
  visibility filter is `WHERE (invoked_by_user_id, owner_org_id) = subscriber`.
  If delegation is added later without a reserved schema slot, the filter
  shape has to be retrofitted — making Stage 2 visibility code touch every
  subscriber when the answer arrives.

  Reserving the empty table NOW means the filter shape can accommodate
  delegation from day one:

      WHERE (invoked_by_user_id, owner_org_id) = subscriber
        OR EXISTS (
          SELECT 1 FROM invocation_visibility_grants g
          WHERE g.invocation_id = re.id
            AND g.grantee_user_id = subscriber.user_id
            AND g.revoked_at IS NULL
        )

  Stage 1 ships the table empty; nothing writes to it. Stage 2 wires the
  filter (always returns false from the EXISTS until grants exist). Stage 3
  or beyond decides governance for who can grant.

  Reversible: rollback drops the table outright. Safe at this stage because
  no rows exist.
  """

  use Ecto.Migration

  @grant_scopes ~w(read_thinking_stream read_audit)

  def change do
    create table(:invocation_visibility_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      # Who is the invocation being granted visibility into?
      # Stored as the runtime_event id (the canonical handle for an invocation).
      # No FK so the grant survives event archival; integrity enforced at write.
      add(:invocation_id, :binary_id, null: false)

      # Who is the grant FOR?
      add(:grantee_user_id, :uuid, null: false)
      add(:grantee_org_id, :binary_id, null: false)

      # Who issued the grant?
      add(:granted_by_user_id, :uuid, null: false)
      add(:granted_by_org_id, :binary_id, null: false)

      # What does the grant cover?
      add(:scope, :string, null: false)

      # Lifecycle
      add(:granted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:revoked_at, :utc_datetime_usec)
      add(:revocation_reason, :string)

      # Optional expiry — NULL means indefinite
      add(:expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    # Lookups by grantee for the visibility filter (Stage 2)
    create(
      index(:invocation_visibility_grants, [:grantee_user_id, :grantee_org_id],
        where: "revoked_at IS NULL",
        name: :invocation_visibility_grants_active_grantee_idx
      )
    )

    # Lookups by invocation (e.g. "who has access to this invocation?")
    create(
      index(:invocation_visibility_grants, [:invocation_id],
        where: "revoked_at IS NULL",
        name: :invocation_visibility_grants_invocation_idx
      )
    )

    # Lookups by granter (e.g. "who has org A granted access to?")
    create(
      index(:invocation_visibility_grants, [:granted_by_org_id, :granted_by_user_id],
        where: "revoked_at IS NULL",
        name: :invocation_visibility_grants_granter_idx
      )
    )

    # Prevent duplicate active grants for the same (invocation, grantee, scope) tuple
    create(
      unique_index(
        :invocation_visibility_grants,
        [:invocation_id, :grantee_user_id, :scope],
        where: "revoked_at IS NULL",
        name: :invocation_visibility_grants_unique_active_idx
      )
    )

    execute(
      """
      COMMENT ON COLUMN invocation_visibility_grants.scope IS
        'Grant scope. One of: #{Enum.join(@grant_scopes, ", ")}. See ADR 0040.'
      """,
      "COMMENT ON COLUMN invocation_visibility_grants.scope IS NULL"
    )
  end
end
