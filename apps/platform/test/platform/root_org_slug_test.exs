defmodule Platform.RootOrgSlugTest do
  @moduledoc """
  Pins every path that resolves "the org a write lands in when the caller
  named none" to `Platform.Tenancy.root_org_slug/0` rather than a hardcoded
  `"fabrikam"` (task 01a081c2 stage 1).

  ## Why these tests are shaped the way they are

  Migration `20260519143620_seed_root_orgs.exs` seeds an org with slug
  `"fabrikam"` into every migrated database, this test DB included. A test
  written against that seeded org passes identically before and after the
  change and proves nothing. So each case here:

    * keeps the seeded `"fabrikam"` org in place AND inserts a second org with
      slug `"milhouse"`, then points `:root_org_slug` at `"milhouse"`; and
    * asserts on the resulting **org_id**, never on `{:ok, _}`. With `"fabrikam"`
      still present the unfixed code succeeds and writes the WRONG org id, so
      an ok-tuple assertion is green on main and worthless.

  `describe "root org renamed away"` is the exception, and it is the literal
  production shape: on suite.example.com the single org was RENAMED
  from `"fabrikam"` to `"milhouse"` on 2026-09-03, so no `"fabrikam"` row exists at
  all. That is what made a first-time OIDC login unable to create a user —
  `apply_derived_role/1` returned `{:error, :org_not_found}` and aborted the
  insert `Multi`.

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

  # The seeded "fabrikam" org STAYS. A second org carries the configured slug, so
  # unfixed code still finds an org and still succeeds — with the wrong id.
  defp seed_second_org! do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    milhouse =
      %Org{}
      |> Org.changeset(%{
        name: "Milhouse",
        slug: @renamed_slug,
        parent_org_id: fabrikam.id
      })
      |> Repo.insert!()

    put_root_org_slug(@renamed_slug)

    %{fabrikam: fabrikam, milhouse: milhouse}
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

  # ── Configured root org (seeded "fabrikam" still present) ────────────────

  describe "configured root org" do
    setup do
      seed_second_org!()
    end

    test "WikiPage.changeset/2 defaults an org_id-less page to the configured org",
         %{milhouse: milhouse, fabrikam: fabrikam} do
      n = System.unique_integer([:positive])

      page =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: "org/root-org-slug-#{n}.md", content: "hello"})
        |> Repo.insert!()

      assert page.org_id == milhouse.id
      refute page.org_id == fabrikam.id
    end

    test "WikiJournalEntry.changeset/2 defaults an org_id-less entry to the configured org",
         %{milhouse: milhouse, fabrikam: fabrikam} do
      entry =
        %WikiJournalEntry{}
        |> WikiJournalEntry.changeset(%{content: "note", date: Date.utc_today()})
        |> Repo.insert!()

      assert entry.org_id == milhouse.id
      refute entry.org_id == fabrikam.id
    end

    test "Tasks.create_project/1 with no :org_id attaches to the configured org",
         %{milhouse: milhouse, fabrikam: fabrikam} do
      n = System.unique_integer([:positive])

      assert {:ok, project} = Tasks.create_project(%{name: "Root Org Slug Project #{n}"})
      assert project.org_id == milhouse.id
      refute project.org_id == fabrikam.id
    end

    test "Tenancy.promote_to_admin/1 with no :org_slug writes the membership in the configured org",
         %{milhouse: milhouse, fabrikam: fabrikam} do
      user = create_user!()

      assert {:ok, membership} = Tenancy.promote_to_admin(user)
      assert membership.org_id == milhouse.id
      refute membership.org_id == fabrikam.id
      assert membership.role == "admin"

      # And nothing was written into the seeded Fabrikam org.
      refute Repo.get_by(OrgMembership, user_id: user.id, org_id: fabrikam.id)
    end

    test "Tenancy.apply_derived_role/1 writes the membership in the configured org",
         %{milhouse: milhouse, fabrikam: fabrikam} do
      user = create_user!()

      assert {:ok, %OrgMembership{} = membership} = Tenancy.apply_derived_role(user)
      assert membership.org_id == milhouse.id
      refute membership.org_id == fabrikam.id
    end

    test "Accounts.find_or_create_from_oidc/1 puts a new user's membership in the configured org",
         %{milhouse: milhouse, fabrikam: fabrikam} do
      n = System.unique_integer([:positive])

      assert {:ok, user} =
               Accounts.find_or_create_from_oidc(%{
                 sub: "oidc-configured-root-#{n}",
                 email: "configured-root-#{n}@example.com",
                 name: "Configured Root #{n}"
               })

      assert %OrgMembership{} =
               membership = Repo.get_by(OrgMembership, user_id: user.id, org_id: milhouse.id)

      assert membership.org_id == milhouse.id
      refute Repo.get_by(OrgMembership, user_id: user.id, org_id: fabrikam.id)
    end
  end

  # ── The production shape: the root org was renamed, no "fabrikam" exists ──

  describe "root org renamed away" do
    setup do
      {1, _} =
        Repo.update_all(
          from(o in Org, where: o.slug == "fabrikam"),
          set: [slug: @renamed_slug]
        )

      put_root_org_slug(@renamed_slug)

      assert Tenancy.get_org_by_slug("fabrikam") == nil
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

      assert membership.role == "member"
    end
  end
end
