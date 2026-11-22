# Seed for `ideas_navigation.browser.mjs` (a DEV database; not part of `mix test`).
#
#   MIX_ENV=dev PLATFORM_DEV_DATABASE=<db> mix run scripts/ideas_navigation_seed.exs <out.json>
#
# One user ("ideasnav": `/dev/login?as=ideasnav`), an approver of two brands in the
# root org, each with a few ideas carrying agent votes; two ideas are selected.
# Writes the brand ids and idea titles to <out.json> for the browser script.
alias Platform.Repo
alias Platform.Social
alias Platform.Social.{Ideas, IdeaVote}

out = List.first(System.argv()) || raise "usage: mix run ... <out.json>"
n = System.unique_integer([:positive])

root =
  Platform.Tenancy.get_root_org() ||
    Repo.insert!(
      Platform.Tenancy.Org.changeset(%Platform.Tenancy.Org{}, %{
        name: "Acme",
        slug: "acme",
        parent_org_id: nil
      })
    )

# The brands go in the ROOT org: a dev-login user is a member of it, so it sees
# them (a child org's brands are not visible to that user).
org = root

user =
  Repo.get_by(Platform.Accounts.User, oidc_sub: "dev-ideasnav") ||
    Repo.insert!(
      Platform.Accounts.User.changeset(%Platform.Accounts.User{}, %{
        email: "ideasnav@example.org",
        name: "Dev Ideasnav",
        oidc_sub: "dev-ideasnav"
      })
    )

unless Repo.get_by(Platform.Tenancy.OrgMembership, user_id: user.id, org_id: org.id) do
  Repo.insert!(
    Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
      user_id: user.id,
      org_id: org.id,
      role: "member"
    })
  )
end

{:ok, space} =
  Platform.Chat.create_space(%{
    name: "Nav chan #{n}",
    slug: "nav-chan-#{n}",
    kind: "channel",
    org_id: org.id
  })

{:ok, _} =
  Platform.Chat.add_participant(space.id, %{
    participant_type: "user",
    participant_id: user.id,
    joined_at: DateTime.utc_now()
  })

agents =
  for i <- 1..3 do
    Repo.insert!(%Platform.Agents.Agent{slug: "nav-agent-#{n}-#{i}", name: "Nav Agent #{i}"})
  end

{:ok, project} = Platform.Tasks.create_project(%{name: "Nav #{n}", org_id: org.id})

brands =
  for name <- ["Alpha Brand", "Bravo Brand"] do
    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: name,
        space_id: space.id,
        approver_user_ids: [user.id],
        default_hashtags: ["#nav"]
      })

    profile = Repo.update!(Ecto.Changeset.change(profile, project_id: project.id))
    [author | voters] = agents

    ideas =
      for {title, votes, selected?} <- [
            {"#{name} plain idea", 0, false},
            {"#{name} voted idea", 2, false},
            {"#{name} chosen idea", 1, true}
          ] do
        {:ok, idea} = Ideas.create(org.id, profile.id, %{title: title}, {:agent, author.id})

        for voter <- Enum.take(voters, votes) do
          Repo.insert!(%IdeaVote{
            idea_id: idea.id,
            org_id: org.id,
            profile_id: profile.id,
            voter_agent_id: voter.id
          })
        end

        if selected?,
          do: {:ok, _, :changed} = Ideas.select_for_research(org.id, idea.id, {:user, user.id})

        title
      end

    %{id: profile.id, name: name, ideas: ideas}
  end

File.write!(out, Jason.encode!(%{brands: brands}))
IO.puts("seeded #{out}")
