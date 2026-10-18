defmodule Platform.RootOrgAdminByDomainE2ETest do
  @moduledoc """
  e2e_behavior case 2 (task 01a068f6 stage 3, plan-approved).

  Proves the admin-by-domain rule is genuinely config-driven end to end
  through the real OIDC login seam (`Platform.Accounts.find_or_create_from_oidc/1`,
  which delegates to `Platform.Tenancy.apply_derived_role/1` — see that
  function's moduledoc), not merely that `derive_role_from_email/1` returns
  the right atom in isolation (already covered by
  `root_org_admin_email_domain_test.exs`).

  ## Why a non-Legacy domain and a controlled bystander membership

  `:root_org_admin_email_domain` is configured to `"acme-test.com"` — a
  domain with no relationship to Legacy — so a pass here cannot be explained
  by a lingering `"example.net"` special case anywhere in the call chain.

  `apply_derived_role/1` has a bootstrap-admin fallback: the FIRST
  membership ever written on an empty root org is force-admined regardless
  of the domain rule (see its moduledoc). Left uncontrolled, the
  acme-test.com case below would pass for the WRONG reason — it would be
  the first membership, not the domain rule, doing the promoting. Seeding
  a bystander membership first makes the acme-test.com login the SECOND
  membership on the org, so only the domain rule can explain an `:admin`
  result.

  ## Why the example.net email is checked SECOND, not first

  The old, pre-01a068f6 behavior was a compiled-in `@example.net` literal.
  If that literal still existed anywhere in the call chain, a example.net
  address would derive `:admin` regardless of what
  `:root_org_admin_email_domain` is configured to. Sending the
  example.net login SECOND — after the bystander AND the acme-test.com
  admin — also removes it from the bootstrap-fallback window, so an
  `:admin` result for it could only come from the (now provably absent)
  hardcoded domain check, never from bootstrap.

  ## Third scenario: example.net explicitly re-configured

  The plan's validation payload for this case (01a0daa5-23bc-7009) asks
  for a third leg: the SAME kind of `@example.net` address, but with
  `:root_org_admin_email_domain` explicitly set to `"example.net"`, must
  still derive `:admin`. This is the "configurable, not deleted" half of
  the proof — scenario two shows the hardcode is gone; this one shows the
  underlying mechanism still works for Legacy's own domain once an operator
  (or `config/dev.exs`/`config/test.exs`'s convenience pin) opts into it
  explicitly. Uses its own `describe` block so it can set its own
  `:root_org_admin_email_domain` and its own bystander, independent of the
  acme-test.com describe block above.

  `async: false`: `:root_org_admin_email_domain` is application env, which
  is global to the node — mirrors `root_org_admin_email_domain_test.exs`
  and `root_org_slug_test.exs`.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @configured_domain "acme-test.com"

  defp put_domain(value) do
    previous = Application.fetch_env(:platform, :root_org_admin_email_domain)

    on_exit(fn ->
      case previous do
        {:ok, prior} -> Application.put_env(:platform, :root_org_admin_email_domain, prior)
        :error -> Application.delete_env(:platform, :root_org_admin_email_domain)
      end
    end)

    Application.put_env(:platform, :root_org_admin_email_domain, value)
  end

  defp create_user!(email) do
    n = System.unique_integer([:positive])

    %Accounts.User{}
    |> Accounts.User.changeset(%{
      email: email,
      name: "Domain E2E #{n}",
      oidc_sub: "oidc-domain-e2e-#{n}"
    })
    |> Repo.insert!()
  end

  defp assert_empty_root_org! do
    root_org = Tenancy.get_root_org()
    refute is_nil(root_org), "expected a seeded root org in the test DB"

    # Zero existing memberships, per the plan's setup — the boot-time seed
    # migration only seeds orgs, never memberships, so this is already the
    # steady state; assert it rather than assume it.
    assert Repo.aggregate(
             from(m in OrgMembership, where: m.org_id == ^root_org.id),
             :count
           ) == 0

    root_org
  end

  defp seed_bystander!(root_org, email) do
    # Seed a bystander membership FIRST so the org is no longer empty —
    # this is what takes the bootstrap-admin fallback out of play for
    # every login that follows. The bystander itself IS the first
    # membership, so it is bootstrap-admined regardless of its own email
    # — that's expected and irrelevant to what this file tests; what
    # matters is that the membership COUNT is no longer zero afterward.
    bystander = create_user!(email)
    assert {:ok, %OrgMembership{}} = Tenancy.apply_derived_role(bystander)

    assert Repo.aggregate(
             from(m in OrgMembership, where: m.org_id == ^root_org.id),
             :count
           ) == 1

    bystander
  end

  describe "a non-Legacy configured domain" do
    setup do
      put_domain(@configured_domain)
      root_org = assert_empty_root_org!()
      bystander = seed_bystander!(root_org, "bystander@example.com")
      %{root_org: root_org, bystander: bystander}
    end

    test "the configured domain derives admin via the domain rule, not the bootstrap fallback",
         %{root_org: root_org} do
      n = System.unique_integer([:positive])

      assert {:ok, user} =
               Accounts.find_or_create_from_oidc(%{
                 sub: "oidc-acme-admin-#{n}",
                 email: "alice-#{n}@#{@configured_domain}",
                 name: "Alice Acme #{n}"
               })

      assert %OrgMembership{role: "admin"} =
               Repo.get_by(OrgMembership, user_id: user.id, org_id: root_org.id)
    end

    test "a example.net email is NOT auto-admined while the domain is configured elsewhere",
         %{root_org: root_org} do
      # First, the acme-test.com admin — establishes there IS already a
      # second (non-bootstrap) membership before example.net arrives.
      n = System.unique_integer([:positive])

      assert {:ok, _admin_user} =
               Accounts.find_or_create_from_oidc(%{
                 sub: "oidc-acme-admin-#{n}",
                 email: "alice-#{n}@#{@configured_domain}",
                 name: "Alice Acme #{n}"
               })

      # Now a example.net address logs in for the first time, arriving as
      # (at least) the THIRD membership on the org (bystander, acme admin,
      # this one) — nowhere near the bootstrap window, and with
      # :root_org_admin_email_domain still pointed at acme-test.com. If the
      # old hardcoded "@example.net" check still existed anywhere in this
      # call chain, this would derive :admin anyway.
      assert {:ok, legacy_user} =
               Accounts.find_or_create_from_oidc(%{
                 sub: "oidc-legacy-#{n}",
                 email: "bob-#{n}@example.net",
                 name: "Bob Legacy #{n}"
               })

      assert %OrgMembership{role: "member"} =
               Repo.get_by(OrgMembership, user_id: legacy_user.id, org_id: root_org.id)
    end
  end

  # ── Third scenario (validation payload leg (c)) ──────────────────────
  #
  # example.net explicitly re-configured as the admin domain must still
  # derive :admin — proving the domain rule is configurable, not that the
  # old Legacy behavior was simply deleted.
  describe "example.net explicitly configured as the admin domain" do
    setup do
      put_domain("example.net")
      root_org = assert_empty_root_org!()
      bystander = seed_bystander!(root_org, "bystander-c@example.com")
      %{root_org: root_org, bystander: bystander}
    end

    test "a example.net email derives admin once the domain is explicitly configured to it",
         %{root_org: root_org} do
      n = System.unique_integer([:positive])

      assert {:ok, user} =
               Accounts.find_or_create_from_oidc(%{
                 sub: "oidc-legacy-explicit-#{n}",
                 email: "carol-#{n}@example.net",
                 name: "Carol Legacy #{n}"
               })

      assert %OrgMembership{role: "admin"} =
               Repo.get_by(OrgMembership, user_id: user.id, org_id: root_org.id)
    end
  end
end
