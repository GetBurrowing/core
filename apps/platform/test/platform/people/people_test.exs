defmodule Platform.PeopleTest do
  @moduledoc """
  Task 01a1aa47 stage 3 — the `Platform.People` read API: card data for
  everyone, private data only when `Wiki.get_page/2` with the caller's scope
  returns the private page.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.People
  alias Platform.People.Pages
  alias Platform.Repo
  alias Platform.Tenancy.{Org, OrgMembership}

  @updated_by "0193a1b2-0000-7000-8000-00000000aaaa"

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    org = Repo.get!(Org, tenant_org_id("globex"))
    subject = user!("subject", org)
    member = user!("member", org)

    {:ok, _, _} =
      Pages.write_card(
        nil,
        "marisol-tennebrook",
        """
        ---
        name: Marisol Tennebrook
        aliases: Mari
        user_id: #{subject.id}
        relation: team
        role: platform lead
        ---

        ## Role
        Platform lead for the deploy pipeline.

        ## Current projects
        - Deploy pipeline

        ## Agents
        - Scribe
        """,
        @updated_by
      )

    {:ok, _, _} =
      Pages.write_private(
        nil,
        "marisol-tennebrook",
        """
        ---
        name: Marisol Tennebrook
        user_id: #{subject.id}
        relation: team
        ---

        ## Interactions
        - 2026-10-02 meeting: Deploy review [cite: meeting:abc]

        ## Perspectives
        - I prefer small PRs — own words [cite: chat:s:m]
        """,
        @updated_by
      )

    %{subject: subject, member: member}
  end

  defp user!(label, org) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "people-#{label}-#{n}@example.com",
        name: "People #{label}",
        oidc_sub: "people-#{label}-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()

    user
  end

  test "cares_about returns perspectives to the subject and nothing to another member", ctx do
    assert People.cares_about("marisol-tennebrook", Scope.for_user(ctx.subject)) ==
             ["I prefer small PRs — own words [cite: chat:s:m]"]

    assert People.cares_about("marisol-tennebrook", Scope.for_user(ctx.member)) == []
    assert People.cares_about("nobody-here", Scope.for_user(ctx.subject)) == []
  end

  test "who_is answers card data to everyone and private data only to the subject", ctx do
    member_view = People.who_is("Mari", Scope.for_user(ctx.member))

    assert %{slug: "marisol-tennebrook", name: "Marisol Tennebrook", role: "platform lead"} =
             member_view

    assert member_view.current_projects == ["Deploy pipeline"]
    assert member_view.agents == ["Scribe"]
    assert member_view.role_notes == ["Platform lead for the deploy pipeline."]
    refute member_view.private_visible?
    assert is_nil(member_view.interactions)
    assert is_nil(member_view.perspectives)

    subject_view = People.who_is("marisol-tennebrook", Scope.for_user(ctx.subject))
    assert subject_view.private_visible?
    assert subject_view.interactions == ["2026-10-02 meeting: Deploy review [cite: meeting:abc]"]

    assert is_nil(People.who_is("Fixture Founder", Scope.for_user(ctx.member)))
  end

  test "worked_on carries interactions only when the private page is visible", ctx do
    assert People.worked_on("marisol-tennebrook", Scope.for_user(ctx.member)) ==
             %{projects: ["Deploy pipeline"], interactions: []}

    assert %{projects: ["Deploy pipeline"], interactions: [_]} =
             People.worked_on("marisol-tennebrook", Scope.for_user(ctx.subject))
  end
end
