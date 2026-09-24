defmodule Platform.Tenancy.ScopeColorEntriesTest do
  @moduledoc """
  `Tenancy.scope_color_entries/1`: the org list the scope-colour `<style>`
  block is built from (task 01a09333-d374 stage 5).

  Since stage 5 moved the six shipped orgs onto the runtime colour path, a
  scope chip is coloured ONLY by a rule in that block. The block used to be
  built from `scope_slug_entries/1`, the Tasks rail's list, which narrows a
  Fabrikam member who is not an admin to the orgs they belong to. Chat shows
  that same member every org's channels, each with a header chip, so their
  SXI chip rendered with no colour at all. Admins never saw it, because an
  admin's rail list is every org.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}

  @seeded ~w(fabrikam soylent wayne_tech sxi paragon)

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

  test "a Fabrikam member who is not an admin gets a colour for every org chat shows them" do
    user = user!() |> member!("fabrikam")

    refute Tenancy.fabrikam_admin?(user)
    assert Tenancy.visibility(user) == :root_all

    colour = slugs(Tenancy.scope_color_entries(user))

    for slug <- @seeded, do: assert(slug in colour, "#{slug} has no colour for a Fabrikam member")

    # The Tasks rail's list is narrower on purpose, and that difference is
    # exactly the gap the colour list must not inherit.
    assert slugs(Tenancy.scope_slug_entries(user)) == MapSet.new(["fabrikam"])
  end

  test "a member of one tenant only gets that tenant's colour and nothing else" do
    user = user!() |> member!("sxi")

    assert slugs(Tenancy.scope_color_entries(user)) == MapSet.new(["sxi"])
  end

  test "an archived org has no colour, and a viewer with no memberships gets none" do
    admin = user!() |> member!("fabrikam", "admin")

    Repo.update_all(from(o in Org, where: o.slug == "paragon"),
      set: [archived_at: DateTime.utc_now()]
    )

    refute "paragon" in slugs(Tenancy.scope_color_entries(admin))
    assert Tenancy.scope_color_entries(nil) == []
    assert Tenancy.scope_color_entries(user!()) == []
  end

  test "each entry carries the stored fill lightness the six are solved at" do
    user = user!() |> member!("fabrikam")
    sxi = Enum.find(Tenancy.scope_color_entries(user), &(&1.slug == "sxi"))

    assert %{hue: 162, chroma: 0.15, lightness: 0.7, label: "SXI"} = sxi
  end
end
