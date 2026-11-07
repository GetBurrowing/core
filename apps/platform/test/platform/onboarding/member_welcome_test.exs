defmodule Platform.Onboarding.MemberWelcomeTest do
  @moduledoc """
  Burrow's welcome for each new person, task 01a1b6de stage 2: posted once
  per user, in the person's DM with Burrow, naming the owner and admins.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.NativeAgents
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Onboarding.MemberWelcome
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  defp user!(label \\ "member", name \\ nil) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "mw-#{label}-#{n}@example.com",
      name: name || "Person#{n} #{label}",
      oidc_sub: "oidc-mw-#{label}-#{n}"
    })
  end

  defp admin!(name) do
    user = user!("admin", name)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp burrow!(owner) do
    {:ok, agent, _runtime} = NativeAgents.create(owner.id, %{name: "Burrow", harness: "codex"})
    assert agent.slug == "burrow"
    agent
  end

  defp welcomes(user) do
    Repo.all(
      from(m in Message,
        where:
          fragment("?->>'source' = 'member_welcome'", m.metadata) and
            fragment("?->>'welcome_user_id' = ?", m.metadata, ^user.id)
      )
    )
  end

  defp pref(user), do: Accounts.get_user_preferences(user.id)[MemberWelcome.pref_key()]

  test "posts the welcome once, as Burrow, in the person's DM with Burrow" do
    owner = admin!("Owner Person")
    agent = burrow!(owner)
    user = user!()

    assert {:ok, %Message{} = message} = MemberWelcome.ensure(user)

    space = Repo.get!(Space, message.space_id)
    assert space.kind == "dm"

    author = Repo.get!(Participant, message.participant_id)
    assert {author.participant_type, author.participant_id} == {"agent", agent.id}

    assert Repo.exists?(
             from(p in Participant,
               where:
                 p.space_id == ^space.id and p.participant_type == "user" and
                   p.participant_id == ^user.id
             )
           )

    assert pref(user) == message.id
    assert MemberWelcome.shown?(user)
  end

  test "a second, third and concurrent call post nothing more" do
    burrow!(admin!("Owner Person"))
    user = user!()

    results =
      1..4
      |> Task.async_stream(fn _ -> MemberWelcome.ensure(user) end, timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Message{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, :already})) == 3

    assert MemberWelcome.ensure(user) == {:ok, :already}
    assert MemberWelcome.ensure(user.id) == {:ok, :already}
    assert [_one] = welcomes(user)
  end

  test "without a Burrow agent nothing is claimed or posted, and a later call welcomes" do
    user = user!()
    assert MemberWelcome.ensure(user) == {:error, :no_agent}
    assert pref(user) == nil
    assert welcomes(user) == []

    burrow!(admin!("Owner Person"))
    assert {:ok, %Message{}} = MemberWelcome.ensure(user)
    assert [_one] = welcomes(user)
  end

  test "an unknown user is not found" do
    assert MemberWelcome.ensure(Ecto.UUID.generate()) == {:error, :not_found}
    assert MemberWelcome.ensure("not-a-uuid") == {:error, :not_found}
    assert MemberWelcome.ensure(nil) == {:error, :not_found}
  end

  test "a failed DM releases the claim so a later call retries" do
    burrow!(admin!("Owner Person"))
    # An external user: Chat.find_or_create_agent_dm/2 refuses them.
    external =
      Platform.ExternalUserFixtures.external_user!(Platform.Tenancy.get_org_by_slug!("globex"))

    assert {:error, :dm_not_allowed} = MemberWelcome.ensure(external)
    assert pref(external) == nil
    assert welcomes(external) == []
  end

  test "names the owner and the admins, never the person themself" do
    owner = admin!("Olive Owner")
    second = admin!("Adam Admin")
    burrow!(owner)
    user = user!()

    {:ok, message} = MemberWelcome.ensure(user)

    assert message.content =~ "Olive Owner (owner)"
    assert message.content =~ "Adam Admin (admin)"
    assert message.metadata["admin_ids"] == [owner.id, second.id]

    text =
      MemberWelcome.welcome_text(second, "Burrow", [
        %{id: owner.id, name: owner.name},
        %{id: second.id, name: second.name}
      ])

    assert text =~ "Olive Owner (owner)"
    refute text =~ "Adam Admin"
  end

  test "the owner is not told to ask themself" do
    owner = %{id: "o", name: "Olive Owner"}
    admin = %{id: "a", name: "Adam Admin"}

    text = MemberWelcome.welcome_text(owner, "Burrow", [owner, admin])
    refute text =~ "Olive Owner"
    assert text =~ "Adam Admin (admin)"

    assert MemberWelcome.welcome_text(owner, "Burrow", [owner]) =~ "You run this install"
  end

  test "the welcome lists the steps in order, in plain words, with no API key and no terminal" do
    text =
      MemberWelcome.welcome_text(%{id: "u", name: "Ada Person"}, "Burrow", [
        %{id: "o", name: "Olive Owner"}
      ])

    assert text =~ "Welcome to Burrow Ada."

    steps = ["notifications", "phone", "ChatGPT or Claude subscription", "channel"]
    positions = Enum.map(steps, fn s -> :binary.match(text, s) |> elem(0) end)
    assert positions == Enum.sort(positions)

    refute text =~ ~r/api.?key/i
    refute text =~ ~r/terminal|command line/i
  end

  test "shown? needs a real welcome message, not just the preference" do
    user = user!()
    refute MemberWelcome.shown?(user)

    {:ok, _} = Accounts.update_user_preference(user.id, MemberWelcome.pref_key(), "posting")
    refute MemberWelcome.shown?(user)

    {:ok, _} =
      Accounts.update_user_preference(user.id, MemberWelcome.pref_key(), Ecto.UUID.generate())

    refute MemberWelcome.shown?(user)
  end

  test "shown? is false once the welcome message is deleted" do
    burrow!(admin!("Owner Person"))
    user = user!()
    {:ok, message} = MemberWelcome.ensure(user)
    assert MemberWelcome.shown?(user)

    Repo.update_all(from(m in Message, where: m.id == ^message.id),
      set: [deleted_at: DateTime.utc_now()]
    )

    refute MemberWelcome.shown?(user)
  end

  test "shown? refuses another person's welcome pointed at by the preference" do
    burrow!(admin!("Owner Person"))
    other = user!("other")
    {:ok, message} = MemberWelcome.ensure(other)

    user = user!()
    {:ok, _} = Accounts.update_user_preference(user.id, MemberWelcome.pref_key(), message.id)
    refute MemberWelcome.shown?(user)
  end
end
