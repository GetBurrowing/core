defmodule Platform.TestRootOrgIdentityTest do
  @moduledoc """
  The test database's root org is the neutral `acme|Acme` fixture pinned in
  `config/test.exs` (task 01a116de stage 4), and the auto-admin domain is
  `acme.test`.

  The pin only reaches the row through `20260519143620_seed_root_orgs`,
  which runs once when the database is migrated. A rig that reuses an
  already-migrated test database keeps whatever root it was seeded with,
  so the suite's `"acme"` lookups would be exercising a stale row, or
  raising for a reason unrelated to the code under test. This file reads
  the seeded row itself, so that case fails here by name.
  """
  use Platform.DataCase, async: true

  alias Platform.Tenancy

  test "the seeded root org is slugged acme and named Acme" do
    root = Tenancy.get_root_org()

    assert root.slug == "acme"
    assert root.name == "Acme"
    assert root.parent_org_id == nil
  end

  test "the slug lookup the suite uses resolves to that same root" do
    assert Tenancy.get_org_by_slug!("acme").id == Tenancy.get_root_org().id
    assert Platform.TenancyFixtures.acme_org_id() == Tenancy.get_root_org().id
  end

  test "the test environment pins the root slug and the admin email domain" do
    assert System.get_env("ROOT_ORG_SLUG") == "acme"
    assert System.get_env("ROOT_ORG_NAME") == "Acme"
    assert Application.get_env(:platform, :root_org_admin_email_domain) == "acme.test"
  end
end
