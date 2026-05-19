defmodule Platform.Repo.Migrations.RefineFabrikamAdminMembershipByEmailDomain do
  @moduledoc """
  Replace the hardcoded admin email allowlist (PR #394's
  `20260519143630_backfill_fabrikam_memberships.exs`) with an email-domain
  rule so new Fabrikam hires automatically inherit `:admin` on the root org
  without a per-person migration.

  ## Rule

      WHERE LOWER(email) LIKE '%@example.com'

  Anchored on the literal `@example.com` suffix to avoid the obvious
  spoof / subdomain traps:

    * `example.com@example.com` → does NOT match (ends in `@gmail.com`)
    * `alice@us.example.com` → does NOT match (subdomain in the middle)
    * `Alice@example.com`    → matches (LOWER normalizes the host)
    * `marlowe.quill@example.com` → matches

  ## Idempotency: ADDITIVE ONLY

  Promotes matching emails to `:admin` via `ON CONFLICT (user_id, org_id)
  DO UPDATE`. Does **not** downgrade non-matching admins — a manually
  granted admin (or anyone Marlowe elevated post-#394) stays admin until a
  separate operation strips them. Re-running is safe: already-admin rows
  are unchanged by the upsert.

  The membership row is inserted at `:member` if it doesn't already
  exist; the upsert immediately re-states it to `:admin`. The net effect
  is "ensure this user has an admin row in Fabrikam" without needing two
  passes.

  # WARNING: Rule is locked to @example.com domain. Future Fabrikam alias domains
  # (e.g. example.com, kobo-ai.co) need explicit additions here. Contractors
  # temporarily on @example.com should be denylisted via the roles_locked_at
  # column — see migration 20260519XXXX_add_roles_locked_at_to_org_memberships
  # (stage 3 of this task).

  ## Reversal

  `down/0` is a no-op. Reversing the promotion safely would require
  knowing each user's prior role; that history is not preserved here.
  If you need to roll back, restore from a backup or run a targeted
  downgrade manually.
  """

  use Ecto.Migration

  def up do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      INSERT INTO org_memberships (id, user_id, org_id, role, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        u.id,
        (SELECT id FROM orgs WHERE slug = 'fabrikam'),
        'admin',
        NOW(),
        NOW()
      FROM users u
      WHERE LOWER(u.email) LIKE '%@example.com'
      ON CONFLICT (user_id, org_id) DO UPDATE
        SET role = 'admin', updated_at = NOW()
      """,
      []
    )
  end

  def down do
    # No-op — this migration only promotes; reversing would require knowing prior state.
    :ok
  end
end
