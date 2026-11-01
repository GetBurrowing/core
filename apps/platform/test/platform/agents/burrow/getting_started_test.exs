defmodule Platform.Agents.Burrow.GettingStartedTest do
  @moduledoc "The Burrow agent's Getting started space, task 01a19505 stage 1."
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Burrow
  alias Platform.Agents.Burrow.GettingStarted
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "test-host-token")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)
  end

  defp admin! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "getting-started-#{n}@example.com",
        name: "Getting Started #{n}",
        oidc_sub: "oidc-getting-started-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  test "the space and its kickoff are created once across two calls" do
    admin = admin!()
    {:ok, agent} = Burrow.ensure(admin.id, "codex")

    assert {:ok, %Space{id: id}} = GettingStarted.ensure_getting_started(agent, admin)
    assert {:ok, %Space{id: ^id}} = GettingStarted.ensure_getting_started(agent, admin)

    spaces = Repo.all(from(s in Space, where: s.slug == ^GettingStarted.space_slug(agent)))
    assert [%Space{name: "Getting started"} = space] = spaces
    assert space.slug == "getting-started-" <> String.slice(agent.id, -12, 12)
    assert space.metadata["setup_agent_id"] == agent.id
    assert space.metadata["setup_kickoff"] == agent.id

    kickoffs =
      Repo.all(
        from(m in Message,
          where:
            m.space_id == ^space.id and fragment("?->>'source'", m.metadata) == "setup_kickoff"
        )
      )

    assert length(kickoffs) == 1
    assert hd(kickoffs).content =~ "@[Burrow]"
    assert hd(kickoffs).content =~ "integrations"
    assert hd(kickoffs).content =~ "first space"

    members =
      Repo.all(
        from(p in Participant,
          where: p.space_id == ^space.id and p.participant_type in ["user", "agent"],
          select: {p.participant_type, p.participant_id}
        )
      )

    assert Enum.sort(members) == Enum.sort([{"user", admin.id}, {"agent", agent.id}])
  end
end
