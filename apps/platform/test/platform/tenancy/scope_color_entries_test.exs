defmodule Platform.Tenancy.ScopeColorEntriesTest do
  @moduledoc """
  `Tenancy.scope_color_entries/1`: the org list the scope-colour `<style>`
  block is built from (task 01a09333-d374 stage 5).

  Since stage 5 moved the six shipped orgs onto the runtime colour path, a
  scope chip is coloured ONLY by a rule in that block. The block used to be
  built from `scope_slug_entries/1`, the Tasks rail's list, which narrows a
  Acme member who is not an admin to the orgs they belong to. Chat shows
  that same member every org's channels, each with a header chip, so their
  SXI chip rendered with no colour at all. Admins never saw it, because an
  admin's rail list is every org.

  The root org is in the list for every viewer (task 01a116de gate-fix
  stage); other tenants only for viewers who can see them.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}

  @seeded ~w(acme soylent wayne_tech sxi paragon)

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "scope-colour-entries-#{n}@example.com",
      name: "User #{n}",
      oidc_sub: "oidc-scope-colour-entries-#{n}"
    })
  end

  defp member!(user, slug, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!(slug).id,
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp slugs(entries), do: entries |> Enum.map(& &1.slug) |> MapSet.new()

  test "an Acme member who is not an admin gets a colour for every org chat shows them" do
    user = user!() |> member!("acme")

    refute Tenancy.root_admin?(user)
    assert Tenancy.visibility(user) == :root_all

    colour = slugs(Tenancy.scope_color_entries(user))

    for slug <- @seeded, do: assert(slug in colour, "#{slug} has no colour for an Acme member")

    # The Tasks rail's list is narrower on purpose, and that difference is
    # exactly the gap the colour list must not inherit.
    assert slugs(Tenancy.scope_slug_entries(user)) == MapSet.new(["acme"])
  end

  test "a member of one tenant gets that tenant's colour and the root's, and no other tenant's" do
    user = user!() |> member!("sxi")
    root = Tenancy.get_root_org()

    # The root is always emitted (task 01a116de gate-fix stage): its section
    # and pill reach non-root viewers, and its colour is not tenant-private.
    assert slugs(Tenancy.scope_color_entries(user)) == MapSet.new(["sxi", root.slug])
  end

  test "an archived org has no colour, and a viewer with no memberships gets none" do
    admin = user!() |> member!("acme", "admin")

    Repo.update_all(from(o in Org, where: o.slug == "paragon"),
      set: [archived_at: DateTime.utc_now()]
    )

    refute "paragon" in slugs(Tenancy.scope_color_entries(admin))

    # A viewer with no visibility of any org still gets the root, and only
    # the root.
    root = Tenancy.get_root_org()
    assert slugs(Tenancy.scope_color_entries(nil)) == MapSet.new([root.slug])
    assert slugs(Tenancy.scope_color_entries(user!())) == MapSet.new([root.slug])
  end

  test "an archived root is not emitted" do
    root = Tenancy.get_root_org()

    Repo.update_all(from(o in Org, where: o.id == ^root.id),
      set: [archived_at: DateTime.utc_now()]
    )

    assert Tenancy.scope_color_entries(nil) == []
  end

  test "each entry carries the stored fill lightness the six are solved at" do
    user = user!() |> member!("acme")
    sxi = Enum.find(Tenancy.scope_color_entries(user), &(&1.slug == "sxi"))

    assert %{hue: 162, chroma: 0.15, lightness: 0.7, label: "SXI"} = sxi
  end
end
