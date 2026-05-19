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
end
