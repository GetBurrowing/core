defmodule Platform.TenancyTest do
  @moduledoc """
  Coverage for the MT/RBAC foundation context module
  (`Platform.Tenancy`), the `Org` + `OrgMembership` schemas, and the
  seed/backfill migrations.

  Relies on the seed migration (`20260519143620_seed_root_orgs.exs`)
  having run — every test here assumes Fabrikam + the four tenants are
  present in the DB.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "tenancy-test-#{n}@example.com",
          name: "Tenancy Test #{n}",
          oidc_sub: "oidc-tenancy-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  # Closure-over-a-map lookup function for the `effective_value/3`
  # tests — keeps the tests storage-agnostic exactly like the resolver
  # claims to be.
  defp build_lookup(values_by_org_id) do
    fn %Org{id: org_id}, key ->
      case Map.fetch(values_by_org_id, {org_id, key}) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end
  end

  # ── Seed-data sanity ─────────────────────────────────────────────────

  describe "seed migration" do
    test "Fabrikam is seeded as the root org" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      assert fabrikam.name == "Fabrikam"
      assert is_nil(fabrikam.parent_org_id)
    end

    test "the four tenants are seeded under Fabrikam" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      for slug <- ~w(soylent wayne_tech sxi paragon) do
        tenant = Tenancy.get_org_by_slug!(slug)
        assert tenant.parent_org_id == fabrikam.id, "#{slug} should parent to Fabrikam"
      end
    end

    test "exactly one row has parent_org_id IS NULL (DB-enforced via partial unique index)" do
      roots = Repo.all(from(o in Org, where: is_nil(o.parent_org_id)))
      assert length(roots) == 1
      assert hd(roots).slug == "fabrikam"
    end

    test "the orgs_single_root partial unique index rejects a second root insert" do
      assert_raise Postgrex.Error, ~r/orgs_single_root/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO orgs (id, parent_org_id, name, slug, inserted_at, updated_at)
          VALUES (gen_random_uuid(), NULL, $1, $2, NOW(), NOW())
          """,
          ["Bogus Root", "bogus_root_#{System.unique_integer([:positive])}"]
        )
      end
    end
  end

  # ── get_org!/1 and get_org_by_slug ───────────────────────────────────

  describe "get_org!/1" do
    test "returns the org for a known id" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      assert Tenancy.get_org!(fabrikam.id).slug == "fabrikam"
    end

    test "raises Ecto.NoResultsError for an unknown id" do
      bogus = Ecto.UUID.generate()
      assert_raise Ecto.NoResultsError, fn -> Tenancy.get_org!(bogus) end
    end
  end

  describe "get_org_by_slug/1" do
    test "returns the org when found" do
      assert %Org{slug: "fabrikam"} = Tenancy.get_org_by_slug("fabrikam")
    end

    test "returns nil for an unknown slug" do
      assert is_nil(Tenancy.get_org_by_slug("definitely-not-a-real-slug"))
    end
  end

  describe "get_org_by_slug!/1" do
    test "returns the org when found" do
      assert %Org{slug: "soylent"} = Tenancy.get_org_by_slug!("soylent")
    end

    test "raises Ecto.NoResultsError for an unknown slug" do
      assert_raise Ecto.NoResultsError, fn ->
        Tenancy.get_org_by_slug!("definitely-not-a-real-slug")
      end
    end
  end

  # ── list_orgs / list_tenants ──────────────────────────────────────────

  describe "list_orgs/0" do
    test "returns every org (root + tenants)" do
      slugs = Tenancy.list_orgs() |> Enum.map(& &1.slug) |> Enum.sort()
      assert "fabrikam" in slugs
      assert "soylent" in slugs
      assert "wayne_tech" in slugs
      assert "sxi" in slugs
      assert "paragon" in slugs
    end
  end

  describe "list_tenants/0" do
    test "excludes the root org" do
      slugs = Tenancy.list_tenants() |> Enum.map(& &1.slug)
      refute "fabrikam" in slugs
    end

    test "includes the four seeded tenants" do
      slugs = Tenancy.list_tenants() |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ~w(paragon soylent wayne_tech sxi)
    end
  end

  # ── list_active_tenants/0 (scope-rail source) ────────────────────────

  describe "list_active_tenants/0" do
    # Stamp `archived_at` directly — the column is the only thing
    # `list_active_tenants/0` reads. The full authz/cascade path is
    # covered in Platform.Tenancy.LifecycleTest.
    defp archive_org!(slug) do
      org = Tenancy.get_org_by_slug!(slug)

      org
      |> Org.changeset(%{archived_at: DateTime.utc_now()})
      |> Repo.update!()
    end

    test "includes the root Fabrikam plus every active tenant" do
      slugs = Tenancy.list_active_tenants() |> Enum.map(& &1.slug)
      assert "fabrikam" in slugs
      assert Enum.sort(slugs) == ~w(paragon soylent fabrikam wayne_tech sxi)
    end

    test "returns rows in canonical tenant-priority order (Fabrikam first)" do
      slugs = Tenancy.list_active_tenants() |> Enum.map(& &1.slug)
      assert slugs == ["fabrikam", "soylent", "wayne_tech", "sxi", "paragon"]
    end

    test "excludes an archived tenant" do
      archive_org!("sxi")

      slugs = Tenancy.list_active_tenants() |> Enum.map(& &1.slug)
      refute "sxi" in slugs
      # the other four scopes (root + 3 active tenants) survive
      assert Enum.sort(slugs) == ~w(paragon soylent fabrikam wayne_tech)
    end

    test "excludes a deletion-scheduled tenant (scheduling stamps archived_at)" do
      org = Tenancy.get_org_by_slug!("paragon")

      org
      |> Org.changeset(%{
        archived_at: DateTime.utc_now(),
        deletion_scheduled_at: DateTime.utc_now()
      })
      |> Repo.update!()

      slugs = Tenancy.list_active_tenants() |> Enum.map(& &1.slug)
      refute "paragon" in slugs
    end

    test "still lists Fabrikam even though the root can never be archived" do
      # Archive every tenant; only the un-archivable root remains.
      Enum.each(~w(soylent wayne_tech sxi paragon), &archive_org!/1)

      slugs = Tenancy.list_active_tenants() |> Enum.map(& &1.slug)
      assert slugs == ["fabrikam"]
    end

    test "regression: list_tenants/0 STILL returns an archived tenant (all-rows callers)" do
      archive_org!("sxi")

      # list_active_tenants hides it...
      refute "sxi" in (Tenancy.list_active_tenants() |> Enum.map(& &1.slug))

      # ...but list_tenants/0 (org-summary walkers, preamble builder,
      # federation tool surface) still sees every tenant regardless of
      # archive state.
      all = Tenancy.list_tenants() |> Enum.map(& &1.slug) |> Enum.sort()
      assert all == ~w(paragon soylent wayne_tech sxi)
    end
  end

  # ── list_active_tenants_for_user/1 (viewer-scoped section headers) ───

  describe "list_active_tenants_for_user/1" do
    defp membership!(user, slug, role) do
      org_id =
        case slug do
          "fabrikam" -> Tenancy.get_org_by_slug!("fabrikam").id
          other -> Tenancy.get_org_by_slug!(other).id
        end

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
      |> Repo.insert!()

      user
    end

    defp slugs_for(user), do: Tenancy.list_active_tenants_for_user(user) |> Enum.map(& &1.slug)

    test "returns only the orgs the member belongs to" do
      user =
        create_user!(%{email: "tenant_scope_#{System.unique_integer([:positive])}@example.com"})
        |> membership!("fabrikam", "member")
        |> membership!("soylent", "member")

      refute Tenancy.fabrikam_admin?(user)

      slugs = slugs_for(user)
      assert Enum.sort(slugs) == ~w(soylent fabrikam)
      refute "sxi" in slugs
      refute "wayne_tech" in slugs
      refute "paragon" in slugs
    end

    test "preserves canonical tenant-priority ordering" do
      user =
        create_user!(%{email: "tenant_ord_#{System.unique_integer([:positive])}@example.com"})
        |> membership!("paragon", "member")
        |> membership!("soylent", "member")

      assert slugs_for(user) == ["soylent", "paragon"]
    end

    test "a root (Fabrikam) admin bypasses the membership filter" do
      admin =
        create_user!(%{email: "tenant_admin_#{System.unique_integer([:positive])}@example.com"})
        |> membership!("fabrikam", "admin")

      assert Tenancy.fabrikam_admin?(admin) == true
      assert Enum.sort(slugs_for(admin)) == ~w(paragon soylent fabrikam wayne_tech sxi)
    end

    test "the admin bypass also works off preloaded memberships (zero-query path)" do
      admin =
        create_user!(%{email: "tenant_pre_#{System.unique_integer([:positive])}@example.com"})
        |> membership!("fabrikam", "admin")

      preloaded = Repo.preload(admin, org_memberships: :org)
      assert Tenancy.fabrikam_admin_preloaded?(preloaded) == true
      assert Enum.sort(slugs_for(preloaded)) == ~w(paragon soylent fabrikam wayne_tech sxi)
    end

    test "an archived org the member belongs to is still excluded" do
      user =
        create_user!(%{email: "tenant_arch_#{System.unique_integer([:positive])}@example.com"})
        |> membership!("fabrikam", "member")
        |> membership!("sxi", "member")

      Tenancy.get_org_by_slug!("sxi")
      |> Org.changeset(%{archived_at: DateTime.utc_now()})
      |> Repo.update!()

      assert slugs_for(user) == ["fabrikam"]
    end

    test "a nil user, or anything without a binary id, returns []" do
      assert Tenancy.list_active_tenants_for_user(nil) == []
      assert Tenancy.list_active_tenants_for_user(%{}) == []
      assert Tenancy.list_active_tenants_for_user(%{id: 7}) == []
    end

    test "list_active_tenants/0 stays unscoped for system callers" do
      assert Enum.sort(Enum.map(Tenancy.list_active_tenants(), & &1.slug)) ==
               ~w(paragon soylent fabrikam wayne_tech sxi)
    end
  end

  # ── ADR-0042 canonical tenant-priority ordering ──────────────────────

  describe "tenant_priority/0 + helpers" do
    test "canonical order is fabrikam → seed tenant order" do
      assert Tenancy.tenant_priority() ==
               ["fabrikam", "soylent", "wayne_tech", "sxi", "paragon"]
    end

    test "tenant_priority_index/1 returns position, or sentinel for unknown" do
      assert Tenancy.tenant_priority_index("fabrikam") == 0
      assert Tenancy.tenant_priority_index("soylent") == 1
      assert Tenancy.tenant_priority_index("paragon") == 4
      assert Tenancy.tenant_priority_index("never-heard-of-it") >= 100
    end

    test "list_orgs_in_priority_order/0 surfaces fabrikam first, then seed order" do
      slugs = Tenancy.list_orgs_in_priority_order() |> Enum.map(& &1.slug)
      # The first five entries must match the canonical priority list,
      # any unknown extras tail-sort by slug.
      assert Enum.take(slugs, 5) == ["fabrikam", "soylent", "wayne_tech", "sxi", "paragon"]
    end

    test "sort_by_tenant_priority/2 with a slug accessor" do
      items = [
        %{slug: "paragon"},
        %{slug: "fabrikam"},
        %{slug: "soylent"},
        %{slug: "sxi"},
        %{slug: "wayne_tech"}
      ]

      sorted = Tenancy.sort_by_tenant_priority(items, & &1.slug)
      assert Enum.map(sorted, & &1.slug) == ["fabrikam", "soylent", "wayne_tech", "sxi", "paragon"]
    end
  end

  # ── list_user_memberships/1 ──────────────────────────────────────────

  describe "list_user_memberships/1" do
    test "returns memberships with :org preloaded" do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      [membership] = Tenancy.list_user_memberships(user)
      assert membership.user_id == user.id
      assert %Org{slug: "fabrikam"} = membership.org
    end

    test "returns an empty list for a user with no memberships" do
      user = create_user!()
      assert Tenancy.list_user_memberships(user) == []
    end

    test "accepts a plain map with :id" do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")
      assert [%OrgMembership{}] = Tenancy.list_user_memberships(%{id: user.id})
    end
  end

  # ── fabrikam_admin?/1 ────────────────────────────────────────────────────

  describe "fabrikam_admin?/1" do
    test "true for a user with admin membership in the root org" do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "admin")
      assert Tenancy.fabrikam_admin?(user)
    end

    test "false for a member-role Fabrikam user" do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")
      refute Tenancy.fabrikam_admin?(user)
    end

    test "false for a user with no memberships" do
      user = create_user!()
      refute Tenancy.fabrikam_admin?(user)
    end

    test "false for a sub-org admin (tenant admin is NOT a Fabrikam admin)" do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("soylent"), "admin")
      refute Tenancy.fabrikam_admin?(user)
    end

    test "false for nil input" do
      refute Tenancy.fabrikam_admin?(nil)
    end

    test "false for non-user input" do
      refute Tenancy.fabrikam_admin?(%{not_an: :id})
    end
  end

  # ── fabrikam_admin_preloaded?/1 (pure variant — no DB call) ─────────────

  describe "fabrikam_admin_preloaded?/1" do
    test "true when the preloaded list has an admin membership on the root org" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      user = %User{
        id: Ecto.UUID.generate(),
        org_memberships: [
          %OrgMembership{role: "admin", org: fabrikam}
        ]
      }

      assert Tenancy.fabrikam_admin_preloaded?(user)
    end

    test "false for a preloaded member-role Fabrikam membership" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      user = %User{org_memberships: [%OrgMembership{role: "member", org: fabrikam}]}
      refute Tenancy.fabrikam_admin_preloaded?(user)
    end

    test "false for an admin membership on a tenant org" do
      soylent = Tenancy.get_org_by_slug!("soylent")
      user = %User{org_memberships: [%OrgMembership{role: "admin", org: soylent}]}
      refute Tenancy.fabrikam_admin_preloaded?(user)
    end

    test "false when the preloaded list is empty" do
      refute Tenancy.fabrikam_admin_preloaded?(%User{org_memberships: []})
    end

    test "false when the association is unloaded" do
      refute Tenancy.fabrikam_admin_preloaded?(%User{})
    end

    test "false for nil input" do
      refute Tenancy.fabrikam_admin_preloaded?(nil)
    end
  end

  # ── load_membership/1 (pure — no DB call) ────────────────────────────

  describe "load_membership/1" do
    test "returns %{org:, role:} for an admin user with a preloaded membership" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      user = %User{org_memberships: [%OrgMembership{role: "admin", org: fabrikam}]}

      assert %{org: %Org{slug: "fabrikam"}, role: :admin} = Tenancy.load_membership(user)
    end

    test "returns %{org:, role:} for a member user" do
      soylent = Tenancy.get_org_by_slug!("soylent")
      user = %User{org_memberships: [%OrgMembership{role: "member", org: soylent}]}

      assert %{org: %Org{slug: "soylent"}, role: :member} = Tenancy.load_membership(user)
    end

    test "returns the first membership when multiple are preloaded" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      sxi = Tenancy.get_org_by_slug!("sxi")

      user = %User{
        org_memberships: [
          %OrgMembership{role: "admin", org: fabrikam},
          %OrgMembership{role: "member", org: sxi}
        ]
      }

      assert %{org: %Org{slug: "fabrikam"}, role: :admin} = Tenancy.load_membership(user)
    end

    test "returns nil when the user has no memberships" do
      assert is_nil(Tenancy.load_membership(%User{org_memberships: []}))
    end

    test "returns nil when the association is unloaded" do
      # Default association shape on a freshly built struct.
      assert is_nil(Tenancy.load_membership(%User{}))
    end

    test "returns nil for nil input" do
      assert is_nil(Tenancy.load_membership(nil))
    end

    test "returns nil for non-user input" do
      assert is_nil(Tenancy.load_membership(%{not_a: :user}))
    end
  end

  # ── member_of?/2 ─────────────────────────────────────────────────────

  describe "member_of?/2" do
    test "true via slug match" do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")
      assert Tenancy.member_of?(user, "fabrikam")
    end

    test "true via UUID match" do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")
      assert Tenancy.member_of?(user, fabrikam.id)
    end

    test "false when the user is not a member of the named org" do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")
      refute Tenancy.member_of?(user, "soylent")
    end

    test "false for an unknown slug" do
      user = create_user!()
      refute Tenancy.member_of?(user, "definitely-not-a-real-slug")
    end

    test "false for nil user" do
      refute Tenancy.member_of?(nil, "fabrikam")
    end
  end

  # ── tier/1 and parent_org/1 ──────────────────────────────────────────

  describe "tier/1" do
    test "returns :root for the root org" do
      assert Tenancy.tier(Tenancy.get_org_by_slug!("fabrikam")) == :root
    end

    test "returns :tenant for a tenant org" do
      assert Tenancy.tier(Tenancy.get_org_by_slug!("soylent")) == :tenant
    end
  end

  describe "parent_org/1" do
    test "returns nil for the root org" do
      assert is_nil(Tenancy.parent_org(Tenancy.get_org_by_slug!("fabrikam")))
    end

    test "returns the Fabrikam org for a tenant" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      parent = Tenancy.parent_org(Tenancy.get_org_by_slug!("soylent"))
      assert parent.id == fabrikam.id
    end
  end

  # ── scope_color / scope_label (pure, DB-free) ────────────────────────

  describe "scope_color/1" do
    test "returns the canonical tailwind class for each seeded scope (atom)" do
      assert Tenancy.scope_color(:fabrikam) == "text-fabrikam"
      assert Tenancy.scope_color(:soylent) == "text-soylent"
      assert Tenancy.scope_color(:wayne_tech) == "text-wayne-tech"
      assert Tenancy.scope_color(:sxi) == "text-sxi"
      assert Tenancy.scope_color(:paragon) == "text-paragon"
    end

    test "accepts a binary slug" do
      assert Tenancy.scope_color("fabrikam") == "text-fabrikam"
    end

    test "falls back to text-muted for an unknown atom" do
      assert Tenancy.scope_color(:__never_seeded__) == "text-muted"
    end

    test "falls back to text-muted for an unknown binary (even one that doesn't atomise)" do
      assert Tenancy.scope_color(
               "never-going-to-be-an-atom-#{System.unique_integer([:positive])}"
             ) ==
               "text-muted"
    end
  end

  describe "scope_label/1" do
    test "returns the canonical label for each seeded scope (atom)" do
      assert Tenancy.scope_label(:fabrikam) == "Fabrikam"
      assert Tenancy.scope_label(:soylent) == "Soylent"
      assert Tenancy.scope_label(:wayne_tech) == "Wayne-Tech"
      assert Tenancy.scope_label(:sxi) == "SXI"
      assert Tenancy.scope_label(:paragon) == "Paragon"
    end

    test "accepts a binary slug" do
      assert Tenancy.scope_label("soylent") == "Soylent"
    end

    test "falls back to a capitalised echo for an unknown atom" do
      assert Tenancy.scope_label(:__never_seeded__) == "__never_seeded__"
    end

    test "falls back to a capitalised echo for an unknown binary" do
      slug = "made_up_slug_#{System.unique_integer([:positive])}"
      assert Tenancy.scope_label(slug) == String.capitalize(slug)
    end
  end

  # ── Org changeset coverage ───────────────────────────────────────────

  describe "Platform.Tenancy.Org.changeset/2" do
    test "requires name and slug" do
      changeset = Org.changeset(%Org{}, %{})
      refute changeset.valid?
    end

    test "rejects an invalid slug format" do
      changeset = Org.changeset(%Org{}, %{name: "Bad", slug: "Has Spaces"})
      refute changeset.valid?
      assert {_msg, _opts} = changeset.errors[:slug]
    end

    test "accepts a well-formed slug" do
      changeset = Org.changeset(%Org{}, %{name: "Good", slug: "well_formed-slug"})
      assert changeset.valid?
    end
  end

  # ── email-domain admin rule (stage 1 backfill migration) ────────────
  #
  # Exercises the SQL from
  # `20260519160000_refine_fabrikam_admin_membership_by_email_domain.exs`
  # by re-running it inside the test sandbox after inserting fixtures
  # with the email shapes we care about. The migration is ADDITIVE: it
  # promotes matching emails to :admin and never downgrades anyone.

  describe "email-domain admin rule" do
    @rule_sql """
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
    """

    defp run_rule!, do: Ecto.Adapters.SQL.query!(Repo, @rule_sql, [])

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

    test "a example.com email is promoted to :admin in Fabrikam" do
      user = create_user!(%{email: "alice@example.com"})
      run_rule!()
      assert fabrikam_role(user) == "admin"
    end

    test "a subdomain like @us.example.com is NOT promoted (anchored suffix)" do
      user = create_user!(%{email: "alice@us.example.com"})
      run_rule!()
      # No Fabrikam membership row created, and definitely not :admin.
      assert fabrikam_membership_count(user) == 0
      refute Tenancy.fabrikam_admin?(user)
    end

    test "an external email like @gmail.com is NOT promoted" do
      user = create_user!(%{email: "alice@gmail.com"})
      run_rule!()
      assert fabrikam_membership_count(user) == 0
      refute Tenancy.fabrikam_admin?(user)
    end

    test "a prefix-spoof like 'example.com@example.com' is NOT promoted" do
      # The literal '@example.com' lives in the local-part here, not the
      # host — LIKE '%@example.com' requires it to be the suffix.
      user = create_user!(%{email: "example.com@example.com"})
      run_rule!()
      assert fabrikam_membership_count(user) == 0
      refute Tenancy.fabrikam_admin?(user)
    end

    test "mixed-case email is promoted (LOWER() normalizes the host)" do
      user = create_user!(%{email: "Alice@example.com"})
      run_rule!()
      assert fabrikam_role(user) == "admin"
    end

    test "users with empty / non-matching email are not promoted" do
      # The User changeset rejects nil/empty emails, so we can't insert
      # a user with email = NULL via the normal path. The behavioral
      # guarantee that matters here is: a non-matching email does not
      # produce a Fabrikam admin row. Use a clearly-non-Fabrikam address.
      user = create_user!(%{email: "noreply@example.com"})
      run_rule!()
      assert fabrikam_membership_count(user) == 0
      refute Tenancy.fabrikam_admin?(user)
    end

    test "re-running the migration on an already-admin row is a no-op (no churn, no duplicates)" do
      user = create_user!(%{email: "bob@example.com"})

      run_rule!()
      assert fabrikam_role(user) == "admin"
      assert fabrikam_membership_count(user) == 1

      # Second run: still exactly one row, still :admin.
      run_rule!()
      assert fabrikam_role(user) == "admin"
      assert fabrikam_membership_count(user) == 1
    end
  end

  # ── derive_role_from_email/1 (Stage 2 — pure function) ──────────────

  describe "derive_role_from_email/1" do
    test "returns :admin for a @example.com email" do
      assert Tenancy.derive_role_from_email("alice@example.com") == :admin
    end

    test "is case-insensitive on the host (LOWER parity with the migration)" do
      assert Tenancy.derive_role_from_email("ALICE@example.com") == :admin
      assert Tenancy.derive_role_from_email("Alice@example.com") == :admin
    end

    test "rejects a subdomain (anchor at end of string)" do
      # @us.example.com does not END in @example.com.
      assert Tenancy.derive_role_from_email("alice@us.example.com") == :member
    end

    test "rejects a prefix-spoof (example.com in the local part)" do
      assert Tenancy.derive_role_from_email("example.com@example.com") == :member
    end

    test "returns :member for an external email" do
      assert Tenancy.derive_role_from_email("alice@gmail.com") == :member
    end

    test "returns :member for nil / empty / non-string input" do
      assert Tenancy.derive_role_from_email(nil) == :member
      assert Tenancy.derive_role_from_email("") == :member
      assert Tenancy.derive_role_from_email(123) == :member
      assert Tenancy.derive_role_from_email(%{}) == :member
    end
  end

  # ── set_membership_role/3 (Stage 2 — idempotent upsert) ─────────────

  describe "set_membership_role/3" do
    test "inserts a new row when none exists" do
      user = create_user!()
      assert fabrikam_membership_count(user) == 0

      assert {:ok, %OrgMembership{role: "admin"}} =
               Tenancy.set_membership_role(user, :fabrikam, :admin)

      assert fabrikam_role(user) == "admin"
      assert fabrikam_membership_count(user) == 1
    end

    test "updates the role on an existing row" do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")

      assert {:ok, %OrgMembership{role: "admin"}} =
               Tenancy.set_membership_role(user, :fabrikam, :admin)

      assert fabrikam_role(user) == "admin"
      # Still exactly one row — updated, not duplicated.
      assert fabrikam_membership_count(user) == 1
    end

    test "is idempotent — calling with the same role twice is a no-op" do
      user = create_user!()
      assert {:ok, first} = Tenancy.set_membership_role(user, :fabrikam, :admin)
      assert {:ok, second} = Tenancy.set_membership_role(user, :fabrikam, :admin)

      # Second call returns the same row, no write — updated_at unchanged.
      assert first.id == second.id
      assert first.updated_at == second.updated_at
      assert fabrikam_membership_count(user) == 1
    end

    test "accepts a string slug as well as an atom" do
      user = create_user!()

      assert {:ok, %OrgMembership{role: "member"}} =
               Tenancy.set_membership_role(user, "fabrikam", :member)
    end

    test "defaults to the :fabrikam org" do
      user = create_user!()
      assert {:ok, %OrgMembership{}} = Tenancy.set_membership_role(user, :fabrikam, :admin)
      assert fabrikam_role(user) == "admin"
    end

    test "returns {:error, :org_not_found} for an unknown slug" do
      user = create_user!()

      assert {:error, :org_not_found} =
               Tenancy.set_membership_role(user, "definitely-not-a-real-slug", :admin)
    end

    test "returns {:error, :invalid_input} for non-user input" do
      assert {:error, :invalid_input} =
               Tenancy.set_membership_role(%{not_a: :user}, :fabrikam, :admin)
    end
  end

  # ── OrgMembership changeset coverage ─────────────────────────────────

  describe "Platform.Tenancy.OrgMembership.changeset/2" do
    test "requires user_id, org_id, and role" do
      changeset = OrgMembership.changeset(%OrgMembership{}, %{})
      refute changeset.valid?
      assert changeset.errors[:user_id]
      assert changeset.errors[:org_id]
      assert changeset.errors[:role]
    end

    test "rejects unknown role values" do
      changeset =
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: Ecto.UUID.generate(),
          org_id: Ecto.UUID.generate(),
          role: "ceo"
        })

      refute changeset.valid?
      assert changeset.errors[:role]
    end

    test "accepts admin and member roles" do
      for role <- ~w(admin member) do
        changeset =
          OrgMembership.changeset(%OrgMembership{}, %{
            user_id: Ecto.UUID.generate(),
            org_id: Ecto.UUID.generate(),
            role: role
          })

        assert changeset.valid?, "Expected role=#{role} to be valid"
      end
    end

    test "DB-level CHECK constraint rejects an invalid role on insert" do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      assert_raise Postgrex.Error, ~r/org_memberships_role_check/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO org_memberships (id, user_id, org_id, role, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1::uuid, $2::uuid, 'pretender', NOW(), NOW())
          """,
          [Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(fabrikam.id)]
        )
      end
    end

    test "unique index prevents duplicate (user_id, org_id) memberships" do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      {:error, changeset} =
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: fabrikam.id, role: "admin"})
        |> Repo.insert()

      refute changeset.valid?
    end
  end

  # ── Denylist overlay + ops API (Stage 3) ─────────────────────────────
  #
  # Exercises the `roles_locked_at` overlay and the `promote_to_admin/2`
  # / `revoke_admin/2` ops API on top of the Stage 2 self-healing hook.
  # Skipped case (auto-revoke / lock-prevents-auto-revoke): there IS no
  # auto-revoke in the current design — Stage 2 only auto-PROMOTES on
  # email change, and offboarding is documented as out of scope for this
  # task. That case would only matter if a future stage adds auto-revoke
  # behavior. See plan task 019e41a9 Stage 2.

  describe "denylist overlay + ops API" do
    test "apply_derived_role/1 SKIPS evaluation when roles_locked_at is set (lock prevents auto-promote)" do
      # Non-Fabrikam email → starts at :member, then we manually lock the row,
      # then we change the email to @example.com and re-apply the rule.
      # The lock should hold → role stays :member.
      user = create_user!(%{email: "contractor@vendor.example"})
      {:ok, membership} = Tenancy.apply_derived_role(user)
      assert membership.role == "member"
      assert is_nil(membership.roles_locked_at)

      # Manually set the lock without changing the role.
      {:ok, locked} =
        membership
        |> OrgMembership.changeset(%{roles_locked_at: DateTime.utc_now()})
        |> Repo.update()

      assert not is_nil(locked.roles_locked_at)

      # Simulate email change to a Fabrikam address and re-apply the rule.
      promoted_email_user = %{user | email: "contractor@example.com"}
      {:ok, after_apply} = Tenancy.apply_derived_role(promoted_email_user)

      # Lock holds — still :member, lock timestamp unchanged.
      assert after_apply.role == "member"
      assert after_apply.roles_locked_at == locked.roles_locked_at
      assert fabrikam_role(user) == "member"
    end

    test "apply_derived_role/1 with no existing row inserts at the derived role (no lock to honor)" do
      # Fresh user, no membership row yet → rule applies normally.
      user = create_user!(%{email: "alice@example.com"})
      assert fabrikam_membership_count(user) == 0

      {:ok, membership} = Tenancy.apply_derived_role(user)

      assert membership.role == "admin"
      assert is_nil(membership.roles_locked_at)
    end

    test "apply_derived_role/1 with no lock applies the rule normally" do
      user = create_user!(%{email: "alice@example.com"})
      # First insert at :member with no lock, then re-apply → should promote.
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")

      {:ok, after_apply} = Tenancy.apply_derived_role(user)

      assert after_apply.role == "admin"
      assert is_nil(after_apply.roles_locked_at)
    end

    test "apply_derived_role/1 returns {:error, :invalid_input} for non-user input" do
      assert {:error, :invalid_input} = Tenancy.apply_derived_role(%{not_a: :user})
    end

    test "promote_to_admin/2 sets role=:admin AND roles_locked_at on a new row" do
      user = create_user!(%{email: "partner@external.example"})

      assert {:ok, membership} = Tenancy.promote_to_admin(user)
      assert membership.role == "admin"
      assert %DateTime{} = membership.roles_locked_at
    end

    test "promote_to_admin/2 promotes an existing :member row and sets the lock" do
      user = create_user!(%{email: "partner@external.example"})
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")

      assert {:ok, membership} = Tenancy.promote_to_admin(user)
      assert membership.role == "admin"
      assert %DateTime{} = membership.roles_locked_at
    end

    test "promote_to_admin/2 is idempotent on an already-admin-and-locked row (no write)" do
      user = create_user!(%{email: "partner@external.example"})
      assert {:ok, first} = Tenancy.promote_to_admin(user)
      assert {:ok, second} = Tenancy.promote_to_admin(user)

      assert first.id == second.id
      # Re-call did not bump updated_at because no DB write happened.
      assert first.updated_at == second.updated_at
      assert first.roles_locked_at == second.roles_locked_at
    end

    test "revoke_admin/2 sets role=:member AND roles_locked_at on a new row" do
      user = create_user!(%{email: "noadmin@example.com"})

      assert {:ok, membership} = Tenancy.revoke_admin(user)
      assert membership.role == "member"
      assert %DateTime{} = membership.roles_locked_at
    end

    test "revoke_admin/2 demotes a Stage 2-auto-promoted admin and locks the row" do
      # Create an @example.com user, then run the Stage 2 hook to give
      # them admin. Now revoke_admin → :member + lock. Then re-apply the
      # rule and assert it stays :member (lock holds).
      user = create_user!(%{email: "contractor@example.com"})
      {:ok, after_stage2} = Tenancy.apply_derived_role(user)
      assert after_stage2.role == "admin"

      assert {:ok, revoked} = Tenancy.revoke_admin(user)
      assert revoked.role == "member"
      assert %DateTime{} = revoked.roles_locked_at

      # Re-run the rule — lock holds.
      {:ok, after_apply} = Tenancy.apply_derived_role(user)
      assert after_apply.role == "member"
      assert fabrikam_role(user) == "member"
    end

    test "revoke_admin/2 is idempotent on an already-member-and-locked row (no write)" do
      user = create_user!(%{email: "noadmin@example.com"})
      assert {:ok, first} = Tenancy.revoke_admin(user)
      assert {:ok, second} = Tenancy.revoke_admin(user)

      assert first.id == second.id
      assert first.updated_at == second.updated_at
      assert first.roles_locked_at == second.roles_locked_at
    end

    test "promote_to_admin/2 returns {:error, :org_not_found} for an unknown org_slug" do
      user = create_user!()

      assert {:error, :org_not_found} =
               Tenancy.promote_to_admin(user, org_slug: "definitely-not-a-real-slug")
    end

    test "revoke_admin/2 returns {:error, :org_not_found} for an unknown org_slug" do
      user = create_user!()

      assert {:error, :org_not_found} =
               Tenancy.revoke_admin(user, org_slug: "definitely-not-a-real-slug")
    end

    test "promote_to_admin/2 returns {:error, :invalid_input} for non-user input" do
      assert {:error, :invalid_input} = Tenancy.promote_to_admin(%{not_a: :user})
    end

    test "revoke_admin/2 returns {:error, :invalid_input} for non-user input" do
      assert {:error, :invalid_input} = Tenancy.revoke_admin(%{not_a: :user})
    end

    test "promote_to_admin/2 emits a [:platform, :tenancy, :role_change] audit event" do
      user = create_user!(%{email: "partner@external.example"})

      Platform.Audit.subscribe()

      assert {:ok, membership} =
               Tenancy.promote_to_admin(user, actor_id: Ecto.UUID.generate(), reason: "elevation")

      # Audit.subscribe/0 is a GLOBAL topic — a bare `event` binding takes
      # whichever audit event arrives first, including one broadcast by a
      # concurrently-running test (observed: "chat.participant.added" under
      # ExUnit seed 148473 / --max-cases 8). Pattern-match the event_type so
      # unrelated broadcasts are skipped rather than asserted against.
      assert_receive {:audit_event, %{event_type: "platform.tenancy.role_change"} = event},
                     500

      assert event.event_type == "platform.tenancy.role_change"
      assert event.action == "promote_to_admin"
      assert event.resource_type == "org_membership"
      assert event.resource_id == membership.id
      assert event.metadata["to_role"] == "admin"
      assert event.metadata["target_user_id"] == user.id
      assert event.metadata["reason"] == "elevation"
    end

    test "revoke_admin/2 emits a [:platform, :tenancy, :role_change] audit event" do
      user = create_user!(%{email: "contractor@example.com"})
      {:ok, _} = Tenancy.apply_derived_role(user)

      Platform.Audit.subscribe()

      assert {:ok, membership} =
               Tenancy.revoke_admin(user, actor_id: Ecto.UUID.generate(), reason: "contractor")

      # Audit.subscribe/0 is a GLOBAL topic — a bare `event` binding takes
      # whichever audit event arrives first, including one broadcast by a
      # concurrently-running test (observed: "chat.participant.added" under
      # ExUnit seed 148473 / --max-cases 8). Pattern-match the event_type so
      # unrelated broadcasts are skipped rather than asserted against.
      assert_receive {:audit_event, %{event_type: "platform.tenancy.role_change"} = event},
                     500

      assert event.event_type == "platform.tenancy.role_change"
      assert event.action == "revoke_admin"
      assert event.resource_id == membership.id
      assert event.metadata["from_role"] == "admin"
      assert event.metadata["to_role"] == "member"
      assert event.metadata["reason"] == "contractor"
    end

    test "ops API defaults to actor_type=system when no actor_id is given" do
      user = create_user!(%{email: "partner@external.example"})

      Platform.Audit.subscribe()
      assert {:ok, _} = Tenancy.promote_to_admin(user)

      # Audit.subscribe/0 is a GLOBAL topic — a bare `event` binding takes
      # whichever audit event arrives first, including one broadcast by a
      # concurrently-running test (observed: "chat.participant.added" under
      # ExUnit seed 148473 / --max-cases 8). Pattern-match the event_type so
      # unrelated broadcasts are skipped rather than asserted against.
      assert_receive {:audit_event, %{event_type: "platform.tenancy.role_change"} = event},
                     500

      assert event.actor_type == "system"
      assert is_nil(event.actor_id)
    end
  end

  # ── effective_value/3 (inheritance resolver) ─────────────────────────

  describe "effective_value/3" do
    test ":defined_here when org has the key and no ancestor does" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      lookup = build_lookup(%{{fabrikam.id, :greeting} => "Hi from Fabrikam"})

      assert {:defined_here, "Hi from Fabrikam"} =
               Tenancy.effective_value(fabrikam, :greeting, "fallback", lookup_fn: lookup)
    end

    test ":overridden when org defines the key AND an ancestor also defines it" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      soylent = Tenancy.get_org_by_slug!("soylent")

      lookup =
        build_lookup(%{
          {soylent.id, :greeting} => "Hi from Soylent",
          {fabrikam.id, :greeting} => "Hi from Fabrikam"
        })

      assert {:overridden, "Hi from Soylent", "Hi from Fabrikam"} =
               Tenancy.effective_value(soylent, :greeting, "fallback", lookup_fn: lookup)
    end

    test ":inherited when org has nothing and an ancestor defines the key" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      soylent = Tenancy.get_org_by_slug!("soylent")

      lookup = build_lookup(%{{fabrikam.id, :greeting} => "Hi from Fabrikam"})

      assert {:inherited, %Org{id: source_id}, "Hi from Fabrikam"} =
               Tenancy.effective_value(soylent, :greeting, "fallback", lookup_fn: lookup)

      assert source_id == fabrikam.id
    end

    test ":defined_here with the default when no org in the chain defines the key" do
      soylent = Tenancy.get_org_by_slug!("soylent")
      lookup = build_lookup(%{})

      assert {:defined_here, "fallback-default"} =
               Tenancy.effective_value(soylent, :greeting, "fallback-default", lookup_fn: lookup)
    end

    test "deep ancestor walk — 3-level hierarchy, key defined only at the root" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      soylent = Tenancy.get_org_by_slug!("soylent")

      # Create a hypothetical sub-sub-org parented to Soylent. The
      # seed only has two tiers; this test exercises the resolver's
      # depth handling for the future-tier case Plan 1 v3 documents.
      sub_sub =
        %Org{}
        |> Org.changeset(%{
          name: "Soylent North",
          slug: "soylent_north_#{System.unique_integer([:positive])}",
          parent_org_id: soylent.id
        })
        |> Repo.insert!()

      lookup = build_lookup(%{{fabrikam.id, :greeting} => "Hi from Fabrikam"})

      assert {:inherited, %Org{id: source_id}, "Hi from Fabrikam"} =
               Tenancy.effective_value(sub_sub, :greeting, "fallback", lookup_fn: lookup)

      assert source_id == fabrikam.id
    end

    test "depth limit kicks in for an artificially deep / cyclic chain" do
      # The Org FK constraint prevents a true `parent_org_id == id`
      # cycle from being inserted normally, so we exercise the
      # depth-budget clause directly by constructing a long chain of
      # 17 orgs where the key isn't defined anywhere — the resolver
      # should bail out and return `{:defined_here, default}` rather
      # than recurse without bound.
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      # Build a 17-deep chain: fabrikam <- d1 <- d2 <- ... <- d17. Walking
      # from d17 to find `:greeting` should hit the 16-depth budget
      # before reaching Fabrikam.
      [bottom | _rest] =
        Enum.reduce(1..17, [fabrikam], fn _i, [parent | _] = acc ->
          n = System.unique_integer([:positive])

          child =
            %Org{}
            |> Org.changeset(%{
              name: "Deep #{n}",
              slug: "deep_#{n}",
              parent_org_id: parent.id
            })
            |> Repo.insert!()

          [child | acc]
        end)

      # Only the root (Fabrikam) defines the key — but it's 17 hops up
      # from the bottom, past the 16-depth budget.
      lookup = build_lookup(%{{fabrikam.id, :greeting} => "Hi from Fabrikam"})

      assert {:defined_here, "fallback"} =
               Tenancy.effective_value(bottom, :greeting, "fallback", lookup_fn: lookup)
    end

    test "raises if :lookup_fn opt is missing" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      assert_raise KeyError, fn ->
        Tenancy.effective_value(fabrikam, :greeting, "fallback", [])
      end
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  #
  # The load-bearing input is the 16-CHARACTER one. `Ecto.UUID.cast/1`
  # hex-encodes any 16-byte binary and returns {:ok, _} while
  # `Ecto.UUID.dump/1` rejects it, so a suite built from "higgins" plus a
  # valid UUID is fully green against the bug. Do not prune the 16-character
  # cases as duplicates.
  describe "UUID boundary: Tenancy org lookups and the slug-or-uuid resolver" do
    @slug_16 "higginshigginsxx"

    test "get_org/1 returns nil for a malformed id" do
      assert Tenancy.get_org("higgins") == nil
      assert Tenancy.get_org(@slug_16) == nil
    end

    test "get_org!/1 raises Ecto.NoResultsError, not Ecto.Query.CastError" do
      assert_raise Ecto.NoResultsError, fn -> Tenancy.get_org!(@slug_16) end
    end

    test "member_of?/2 takes the SLUG branch for a 16-character org slug" do
      # member_of?/2 resolves a slug OR a uuid, and its uuid branch pins the
      # ORIGINAL value against Org's strict UUIDv7 key. A bare cast sent any
      # 16-character org slug down the uuid branch, where Repo raised. The
      # observable fix is that it now resolves as a slug (here: a miss, but a
      # miss reached WITHOUT raising).
      user = create_user!()
      refute Tenancy.member_of?(user, @slug_16)
      refute Tenancy.member_of?(user, "higgins")
    end
  end
end
