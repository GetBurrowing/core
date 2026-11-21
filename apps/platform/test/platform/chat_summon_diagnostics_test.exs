defmodule Platform.ChatSummonDiagnosticsTest do
  @moduledoc """
  What `Platform.ChatSummonDiagnostics.describe/4` reports when an agent or an
  actor's participant row is somewhere other than the expected space. These
  states are built directly, so the tests do not depend on how a LiveView
  chooses the space it mounts.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.ChatSummonDiagnostics
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "diag-#{tag}-#{n}@example.test",
      name: "Diag #{tag} #{n}",
      oidc_sub: "oidc-diag-#{tag}-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "diag-agent-#{n}", name: "Diag#{n}", status: "active"})
  end

  defp channel!(owner, slug) do
    {:ok, space} =
      Chat.create_channel(%{name: "Diag #{slug}", slug: slug, created_by: owner.id})

    space
  end

  defp join!(space, actor, agent) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: actor.id,
        display_name: "Actor",
        joined_at: DateTime.utc_now()
      })

    {:ok, _} = Chat.add_agent_participant(space.id, agent)
    :ok
  end

  defp describe(space, actor, agent),
    do: ChatSummonDiagnostics.describe(space, actor, agent, :no_view)

  test "rows only in the expected space report no rows elsewhere and one space for the slug" do
    owner = user!("owner")
    actor = user!("actor")
    agent = agent!()
    space = channel!(owner, "diag-healthy-#{System.unique_integer([:positive])}")
    join!(space, actor, agent)

    text = describe(space, actor, agent)

    assert text =~ "agent participant rows in OTHER spaces: 0"
    assert text =~ "actor participant rows in OTHER spaces: 0"
    assert text =~ "spaces sharing this space's slug (all orgs): 1"
    assert text =~ "of which is this space: true"
    assert text =~ "participant rows for this agent: 1"
    assert text =~ "actor has a participant row: true"
  end

  test "rows that landed in a same-slug space in another org are counted as elsewhere" do
    owner = user!("owner")
    actor = user!("actor")
    agent = agent!()
    slug = "diag-wrong-#{System.unique_integer([:positive])}"

    expected =
      owner
      |> channel!(slug)
      |> Ecto.Changeset.change(org_id: Tenancy.get_org_by_slug!("initech").id)
      |> Repo.update!()

    other = channel!(owner, slug)
    refute other.org_id == expected.org_id
    join!(other, actor, agent)

    text = describe(expected, actor, agent)

    assert text =~ "participant rows for this agent: 0"
    assert text =~ "actor has a participant row: false"
    assert text =~ "agent participant rows in OTHER spaces: 1"
    assert text =~ "actor participant rows in OTHER spaces: 1"
    assert text =~ "spaces sharing this space's slug (all orgs): 2"
    assert text =~ "of which is this space: true"
  end

  test "an expected space that no longer carries the slug is reported as not among the matches" do
    owner = user!("owner")
    actor = user!("actor")
    agent = agent!()
    space = channel!(owner, "diag-stale-#{System.unique_integer([:positive])}")

    Repo.update_all(from(s in Platform.Chat.Space, where: s.id == ^space.id),
      set: [slug: "diag-renamed-#{System.unique_integer([:positive])}"]
    )

    text = describe(space, actor, agent)

    assert text =~ "spaces sharing this space's slug (all orgs): 0"
    assert text =~ "of which is this space: false"
  end

  test "an unavailable participant read is reported as unavailable, not as a row that exists" do
    owner = user!("owner")
    actor = user!("actor")
    agent = agent!()
    space = channel!(owner, "diag-unavailable-#{System.unique_integer([:positive])}")

    text = describe(%{space | id: "not-a-uuid"}, actor, agent)

    assert text =~ "participant rows for this agent: {:unavailable,"
    assert text =~ "actor has a participant row: {:unavailable,"
    refute text =~ "actor has a participant row: true"
    refute text =~ "actor has a participant row: false"
  end

  test "the output is counts, booleans and labels, with no identifiers" do
    owner = user!("owner")
    actor = user!("actor")
    agent = agent!()
    space = channel!(owner, "diag-ids-#{System.unique_integer([:positive])}")
    join!(space, actor, agent)

    refute describe(space, actor, agent) =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-/
  end

  test "the membership observation is labelled as a fresh read and reflects the space's org" do
    owner = user!("owner")
    actor = user!("actor")
    agent = agent!()

    space =
      owner
      |> channel!("diag-membership-#{System.unique_integer([:positive])}")
      |> Ecto.Changeset.change(org_id: Tenancy.get_org_by_slug!("initech").id)
      |> Repo.update!()

    label = "first preloaded membership org is this space's org (a fresh read now)"

    assert describe(space, actor, agent) =~ "#{label}: false"

    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: actor.id,
        org_id: space.org_id,
        role: "member",
        external: false
      })
    )

    assert describe(space, actor, agent) =~ "#{label}: true"
  end

  test "a read that fails is reported as unavailable and does not raise" do
    owner = user!("owner")
    agent = agent!()
    space = channel!(owner, "diag-broken-#{System.unique_integer([:positive])}")

    text = describe(space, %{id: "not-a-uuid"}, agent)

    assert is_binary(text)
    assert text =~ "actor participant rows in OTHER spaces: {:unavailable,"
    assert text =~ "agent participant rows in OTHER spaces: 0"
  end
end
