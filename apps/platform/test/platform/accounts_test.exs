defmodule Platform.AccountsTest do
  @moduledoc """
  Covers the Stage 2 self-healing email-domain admin rule wired into
  `Platform.Accounts.find_or_create_from_oidc/1`.

  The hook fires on:

    * **INSERT** — every new user gets an `org_memberships` row in Fabrikam
      with role derived from `Platform.Tenancy.derive_role_from_email/1`.
    * **email-change UPDATE** — if a user's email refreshes to a Fabrikam
      address, they auto-promote to admin. There is **no auto-revoke**;
      offboarding is explicitly out of scope per the plan.

  Tenancy-level rule semantics (anchoring, case-insensitivity, idempotent
  upsert) live in `Platform.TenancyTest`; this file exercises only the
  Accounts-side wiring.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ──────────────────────────────────────────────────────────

  defp fabrikam_role(user) do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    Repo.one(
      from(m in OrgMembership,
        where: m.user_id == ^user.id and m.org_id == ^fabrikam.id,
        select: m.role
      )
    )
  end

  defp fabrikam_membership_count(user) do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    Repo.aggregate(
      from(m in OrgMembership, where: m.user_id == ^user.id and m.org_id == ^fabrikam.id),
      :count,
      :id
    )
  end

  defp oidc_attrs(overrides) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        sub: "accounts-oidc-#{n}",
        email: "accounts-#{n}@example.com",
        name: "Accounts Test #{n}"
      },
      overrides
    )
  end

  # ── INSERT hook ──────────────────────────────────────────────────────

  describe "find_or_create_from_oidc/1 — INSERT hook" do
    test "a brand-new @example.com signup gets a Fabrikam admin membership" do
      attrs = oidc_attrs(%{email: "newhire@example.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)

      assert fabrikam_role(user) == "admin"
      assert fabrikam_membership_count(user) == 1
      assert Tenancy.fabrikam_admin?(user)
    end

    test "a brand-new @gmail.com signup gets a Fabrikam member membership" do
      attrs = oidc_attrs(%{email: "external@gmail.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)

      assert fabrikam_role(user) == "member"
      assert fabrikam_membership_count(user) == 1
      refute Tenancy.fabrikam_admin?(user)
    end

    test "the case-insensitive rule applies on insert" do
      attrs = oidc_attrs(%{email: "Mixed-Case@example.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
      assert fabrikam_role(user) == "admin"
    end

    test "subdomain spoofs do NOT receive admin on insert" do
      attrs = oidc_attrs(%{email: "subdomain@us.example.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
      assert fabrikam_role(user) == "member"
      refute Tenancy.fabrikam_admin?(user)
    end
  end

  # ── UPDATE / email-change hook ───────────────────────────────────────

  describe "find_or_create_from_oidc/1 — email-change hook" do
    test "an existing member changing email to @example.com is promoted to admin" do
      sub = "promo-sub-#{System.unique_integer([:positive])}"

      {:ok, user} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "alice@gmail.com",
          name: "Alice"
        })

      assert fabrikam_role(user) == "member"

      {:ok, promoted} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "alice@example.com",
          name: "Alice"
        })

      assert promoted.id == user.id
      assert promoted.email == "alice@example.com"
      assert fabrikam_role(promoted) == "admin"
      assert fabrikam_membership_count(promoted) == 1
      assert Tenancy.fabrikam_admin?(promoted)
    end

    test "an existing admin (Fabrikam email) changing email to @gmail.com STAYS admin" do
      # DELIBERATE: offboarding is out of scope per plan Stage 2. The
      # hook is promote-only; a Fabrikam email changing to non-Fabrikam MUST
      # NOT auto-revoke admin. Stripping a departed employee is a
      # separate operation (planned for a later stage).
      sub = "offboard-sub-#{System.unique_integer([:positive])}"

      {:ok, fabrikam_user} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "bob@example.com",
          name: "Bob"
        })

      assert fabrikam_role(fabrikam_user) == "admin"

      {:ok, after_change} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "bob@gmail.com",
          name: "Bob"
        })

      assert after_change.id == fabrikam_user.id
      assert after_change.email == "bob@gmail.com"
      # Role is preserved — no auto-revoke.
      assert fabrikam_role(after_change) == "admin"
      assert fabrikam_membership_count(after_change) == 1
    end

    test "an existing user whose email does NOT change is unaffected by the hook" do
      sub = "noop-sub-#{System.unique_integer([:positive])}"
      email = "carol@gmail.com"

      {:ok, user} =
        Accounts.find_or_create_from_oidc(%{sub: sub, email: email, name: "Carol"})

      assert fabrikam_role(user) == "member"

      # Name refresh, same email — hook is a no-op.
      {:ok, refreshed} =
        Accounts.find_or_create_from_oidc(%{sub: sub, email: email, name: "Carol Renamed"})

      assert refreshed.id == user.id
      assert refreshed.name == "Carol Renamed"
      assert fabrikam_role(refreshed) == "member"
      assert fabrikam_membership_count(refreshed) == 1
    end

    test "a member changing email to another non-Fabrikam address is NOT auto-promoted" do
      sub = "lateral-sub-#{System.unique_integer([:positive])}"

      {:ok, user} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "dave@gmail.com",
          name: "Dave"
        })

      assert fabrikam_role(user) == "member"

      {:ok, refreshed} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "dave@yahoo.com",
          name: "Dave"
        })

      assert refreshed.email == "dave@yahoo.com"
      assert fabrikam_role(refreshed) == "member"
    end
  end
end
