defmodule Platform.RootOrgSlugTest do
  @moduledoc """
  Task 01a081c2 stage 1 pinned every path that resolves "the org a write
  lands in when the caller named none" to `Platform.Tenancy.root_org_slug/0`
  rather than a hardcoded `"fabrikam"`. Task 01a068f6 stage 1 went further for
  the six call sites below: they no longer read `root_org_slug/0` AT ALL —
  they resolve the root org structurally via `Platform.Tenancy.get_root_org/0`
  (`parent_org_id IS NULL`), so an operator does not have to configure
  `ROOT_ORG_SLUG` (or anything else) for a fresh install to work at all.

  `root_org_slug/0` itself is unchanged and still configurable — it still
  backs `Tenancy.get_org_by_slug(Tenancy.root_org_slug())` call sites that
  were NOT migrated (e.g. the `sidebar_component.ex` UI comparisons) and
  the explicit `:org_slug` override opt on `promote_to_admin/2` /
  `revoke_admin/2`. This file no longer proves anything about those; it now
  proves the opposite for the six migrated call sites: `ROOT_ORG_SLUG`
  pointed at a real, non-root org must NOT redirect them.

  ## Why "configured root org" is shaped the way it is

  Migration `20260519143620_seed_root_orgs.exs` seeds an org with slug
  `"acme"` into every migrated database, this test DB included. A test
  written against that seeded org passes identically whether or not the
  code under test even looks at `:root_org_slug`, and proves nothing. So
  each case here:

    * keeps the seeded `"acme"` org in place AND inserts a second org —
      `"milhouse"`, parented UNDER Acme, i.e. a real, ordinary tenant, not a
      root — then points `:root_org_slug` at `"milhouse"`; and
    * asserts the write lands on **Acme's org_id** and NOT `milhouse`'s.
      `root_org_slug/0` pointing at a real (non-root) org is exactly the
      case a naive "did it error?" assertion can't distinguish from a
      slug-based implementation that redirected there — asserting the org
      id is the only way to catch that regression.

  `describe "root org renamed away"` is the literal production shape: on
  suite.example.com the single org was RENAMED from `"acme"` to
  `"milhouse"` on 2026-09-03 — same *row*, same `parent_org_id IS NULL`,
  different slug. That is what made a first-time OIDC login unable to
  create a user under the pre-01a068f6 slug-based lookup —
  `apply_derived_role/1` returned `{:error, :org_not_found}` and aborted
  the insert `Multi`. Structural lookup fixes that unconditionally (no
  `ROOT_ORG_SLUG` needed at all), and — because this is also the very
  first membership ever written on that (renamed) root org in this test's
  transaction — it is the exact scenario `apply_derived_role/1`'s
  bootstrap-admin fallback (task 01a068f6 stage 1) targets: the first
  person into a fresh/renamed install becomes its admin.

  `async: false`: `:root_org_slug` is application env, which is global. A
  concurrent async case reading it would see `"milhouse"`.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @renamed_slug "milhouse"

  # ── Helpers ──────────────────────────────────────────────────────────

  defp put_root_org_slug(slug) do
    previous = Application.get_env(:platform, :root_org_slug)
    Application.put_env(:platform, :root_org_slug, slug)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :root_org_slug)
        value -> Application.put_env(:platform, :root_org_slug, value)
      end
    end)

    :ok
  end

  # The seeded "acme" org STAYS and remains the ONLY `parent_org_id IS NULL`
  # row — "milhouse" is parented under it, an ordinary tenant. A slug-based
  # lookup pointed at "milhouse" would find and use it; the structural
  # `get_root_org/0` lookup this file now exercises must not.
  defp seed_second_org! do
    acme = Tenancy.get_org_by_slug!("acme")

    milhouse =
      %Org{}
      |> Org.changeset(%{
        name: "Milhouse",
        slug: @renamed_slug,
        parent_org_id: acme.id
      })
      |> Repo.insert!()

    put_root_org_slug(@renamed_slug)

    %{acme: acme, milhouse: milhouse}
  end

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "root-org-slug-#{n}@example.com",
          name: "Root Org Slug #{n}",
          oidc_sub: "oidc-root-org-slug-#{n}"
        },
        overrides
      )

    %Accounts.User{}
    |> Accounts.User.changeset(attrs)
    |> Repo.insert!()
  end

  # ── Configured root org (seeded "acme" still present) ────────────────
  #
  # Task 01a068f6 stage 1: these six call sites now resolve the root org
  # structurally (`get_root_org/0`), so `:root_org_slug` pointed at
  # "milhouse" — a real org, just not the root — must NOT redirect any of
  # them. Every write below must land on Acme, not milhouse.

  describe "configured root org" do
    setup do
      seed_second_org!()
    end

    test "WikiPage.changeset/2 ignores :root_org_slug and defaults to the structural root",
         %{milhouse: milhouse, acme: acme} do
      n = System.unique_integer([:positive])

      page =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: "org/root-org-slug-#{n}.md", content: "hello"})
        |> Repo.insert!()

      assert page.org_id == acme.id
      refute page.org_id == milhouse.id
    end

    test "WikiJournalEntry.changeset/2 ignores :root_org_slug and defaults to the structural root",
         %{milhouse: milhouse, acme: acme} do
      entry =
        %WikiJournalEntry{}
        |> WikiJournalEntry.changeset(%{content: "note", date: Date.utc_today()})
        |> Repo.insert!()

      assert entry.org_id == acme.id
      refute entry.org_id == milhouse.id
    end

    test "Tasks.create_project/1 with no :org_id ignores :root_org_slug and attaches to the structural root",
         %{milhouse: milhouse, acme: acme} do
      n = System.unique_integer([:positive])

      assert {:ok, project} = Tasks.create_project(%{name: "Root Org Slug Project #{n}"})
      assert project.org_id == acme.id
      refute project.org_id == milhouse.id
    end

    test "Tenancy.promote_to_admin/1 with no :org_slug ignores :root_org_slug and writes to the structural root",
         %{milhouse: milhouse, acme: acme} do
      user = create_user!()

      assert {:ok, membership} = Tenancy.promote_to_admin(user)
      assert membership.org_id == acme.id
      refute membership.org_id == milhouse.id
      assert membership.role == "admin"

      # And nothing was written into the configured-but-non-root milhouse org.
      refute Repo.get_by(OrgMembership, user_id: user.id, org_id: milhouse.id)
    end

    test "Tenancy.apply_derived_role/1 ignores :root_org_slug and writes to the structural root",
         %{milhouse: milhouse, acme: acme} do
      user = create_user!()

      assert {:ok, %OrgMembership{} = membership} = Tenancy.apply_derived_role(user)
      assert membership.org_id == acme.id
      refute membership.org_id == milhouse.id
    end

    test "Accounts.find_or_create_from_oidc/1 ignores :root_org_slug and puts a new user's membership on the structural root",
         %{milhouse: milhouse, acme: acme} do
      n = System.unique_integer([:positive])

      assert {:ok, user} =
               Accounts.find_or_create_from_oidc(%{
                 sub: "oidc-configured-root-#{n}",
                 email: "configured-root-#{n}@example.com",
                 name: "Configured Root #{n}"
               })

      assert %OrgMembership{} =
               membership = Repo.get_by(OrgMembership, user_id: user.id, org_id: acme.id)

      assert membership.org_id == acme.id
      refute Repo.get_by(OrgMembership, user_id: user.id, org_id: milhouse.id)
    end
  end

  # ── root_org_slug/0 itself: no literal default (task 01a116de) ────────
  #
  # `config.exs` used to default `:root_org_slug` to a client's slug, so on a
  # fresh install whose root is seeded `root` the accessor named an org that
  # did not exist. It now reads config when set and non-blank, else the
  # structural root's slug, else nil. Each case pins BOTH inputs (the config
  # key and the root row) so it cannot pass on whatever the test DB seeded.

  defp delete_root_org_slug do
    previous = Application.get_env(:platform, :root_org_slug)
    Application.delete_env(:platform, :root_org_slug)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :root_org_slug)
        value -> Application.put_env(:platform, :root_org_slug, value)
      end
    end)

    :ok
  end

  defp set_root_row_slug!(slug) do
    {1, _} =
      Repo.update_all(from(o in Org, where: is_nil(o.parent_org_id)), set: [slug: slug])

    :ok
  end

  describe "root_org_slug/0 resolution" do
    test "(a) unset config + root row `root` resolves \"root\"" do
      delete_root_org_slug()
      set_root_row_slug!("root")

      assert Tenancy.root_org_slug() == "root"
    end

    test "(b) config \"acme\" + root row `acme` resolves \"acme\"" do
      put_root_org_slug("acme")
      set_root_row_slug!("acme")

      assert Tenancy.root_org_slug() == "acme"
    end

    test "(b') a set config wins over the root row's slug" do
      put_root_org_slug("acme")
      set_root_row_slug!("root")

      assert Tenancy.root_org_slug() == "acme"
    end

    test "(c) no root row and no config resolves nil" do
      delete_root_org_slug()
      # `TRUNCATE ... CASCADE`, not `Repo.delete_all/1`: other tables
      # FK-reference `orgs.id` with ON DELETE RESTRICT. Transactional, so it
      # rolls back with the test (same approach as
      # adr_0042_root_org_resolution_test.exs).
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE orgs CASCADE")

      assert Tenancy.get_root_org() == nil
      assert Tenancy.root_org_slug() == nil
    end

    test "(d) a blank config value is treated as unset" do
      set_root_row_slug!("root")

      put_root_org_slug("")
      assert Tenancy.root_org_slug() == "root"

      put_root_org_slug("   ")
      assert Tenancy.root_org_slug() == "root"
    end
  end

  # ── The root sorts first structurally, whatever its slug ─────────────

  describe "root-first ordering" do
    test "list_orgs_in_priority_order/0 puts a root slugged `zz-root` first" do
      set_root_row_slug!("zz-root")

      slugs = Tenancy.list_orgs_in_priority_order() |> Enum.map(& &1.slug)
      assert Enum.take(slugs, 5) == ["zz-root", "soylent", "wayne_tech", "sxi", "paragon"]
    end

    test "Projects.group_by_org/1 puts the root's bucket first whatever its slug" do
      set_root_row_slug!("zz-root")
      root = Tenancy.get_root_org()
      soylent = Tenancy.get_org_by_slug!("soylent")

      {:ok, _} = Tasks.create_project(%{name: "Soylent Order Probe", org_id: soylent.id})
      {:ok, _} = Tasks.create_project(%{name: "Root Order Probe", org_id: root.id})

      slugs =
        Tasks.list_projects_unscoped(preload: :org)
        |> Platform.Projects.group_by_org()
        |> Enum.map(fn {slug, _name, _ps} -> slug end)

      assert Enum.take(slugs, 2) == ["zz-root", "soylent"]
    end
  end

  # ── The production shape: the root org was renamed, no "acme" exists ──

  describe "root org renamed away" do
    setup do
      {1, _} =
        Repo.update_all(
          from(o in Org, where: o.slug == "acme"),
          set: [slug: @renamed_slug]
        )

      put_root_org_slug(@renamed_slug)

      assert Tenancy.get_org_by_slug("acme") == nil
      %{root: Tenancy.get_org_by_slug!(@renamed_slug)}
    end

    test "a first-time OIDC login creates the user and its membership", %{root: root} do
      n = System.unique_integer([:positive])
      sub = "oidc-renamed-root-#{n}"

      assert {:ok, user} =
               Accounts.find_or_create_from_oidc(%{
                 sub: sub,
                 email: "renamed-root-#{n}@example.com",
                 name: "Renamed Root #{n}"
               })

      assert Repo.get_by(Accounts.User, oidc_sub: sub)

      assert %OrgMembership{} =
               membership = Repo.get_by(OrgMembership, user_id: user.id, org_id: root.id)

      # This is also the FIRST-EVER membership on this (renamed) root org in
      # this test's transaction, so the bootstrap-admin fallback (task
      # 01a068f6 stage 1) fires: the first person into a fresh/renamed
      # install becomes its admin, regardless of the domain rule (this
      # email does not match it). That is the point of the fallback, not
      # an accident of test ordering — see `tenancy_test.exs`'s dedicated
      # "denylist overlay + ops API" bootstrap-admin coverage for the
      # isolated behavior and the second-user/lock precedence tests.
      assert membership.role == "admin"
    end
  end
end
