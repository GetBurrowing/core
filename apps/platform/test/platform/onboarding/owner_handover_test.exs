defmodule Platform.Onboarding.OwnerHandoverTest do
  @moduledoc """
  The owner's hand-over moment: marked past first run, and a first project and
  channel named after the root org on an install that has none.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat.{Participant, Space}
  alias Platform.Onboarding.{FirstRunGoal, OwnerHandover}
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy

  defp user!(label \\ "owner") do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "oh-#{label}-#{n}@example.com",
      name: "OH #{label} #{n}",
      oidc_sub: "oidc-oh-#{label}-#{n}"
    })
  end

  defp org! do
    org = Tenancy.get_org!(acme_org_id())
    org |> Ecto.Changeset.change(name: "Hand Over Co") |> Repo.update!()
  end

  setup do
    org = org!()
    Repo.delete_all(Project)
    {:ok, org: org}
  end

  describe "FirstRunGoal.mark_owner/1" do
    test "writes the preference and the user is no longer pending" do
      user = user!()
      assert FirstRunGoal.pending?(user)

      assert :ok = FirstRunGoal.mark_owner(user)
      assert Accounts.get_user_preferences(user.id)["first_run_goal"] == "owner"
      refute FirstRunGoal.pending?(user)
    end

    test "is idempotent and leaves other preference keys alone" do
      user = user!()
      {:ok, _} = Accounts.update_user_preference(user.id, "theme", "dark")

      assert :ok = FirstRunGoal.mark_owner(user)
      assert :ok = FirstRunGoal.mark_owner(user)

      assert Accounts.get_user_preferences(user.id) == %{
               "theme" => "dark",
               "first_run_goal" => "owner"
             }
    end

    test "an unknown user is not found" do
      assert {:error, :not_found} = FirstRunGoal.mark_owner(%{id: Ecto.UUID.generate()})
      assert {:error, :not_found} = FirstRunGoal.mark_owner(nil)
    end
  end

  describe "OwnerHandover.complete/1" do
    test "creates a project and a channel named after the org, owner as admin", %{org: org} do
      user = user!()
      assert :ok = OwnerHandover.complete(user)

      assert [%Project{name: "Hand Over Co", org_id: org_id}] = Repo.all(Project)
      assert org_id == org.id

      space = Repo.one!(from(s in Space, where: s.slug == "hand-over-co"))
      assert space.kind == "channel"
      assert space.name == "Hand Over Co"
      assert space.org_id == org.id

      assert %Participant{role: "admin"} =
               Repo.one!(
                 from(p in Participant,
                   where:
                     p.space_id == ^space.id and p.participant_type == "user" and
                       p.participant_id == ^user.id
                 )
               )

      assert Accounts.get_user_preferences(user.id)["first_run_goal"] == "owner"
    end

    test "a second run creates nothing more" do
      user = user!()
      assert :ok = OwnerHandover.complete(user)
      spaces = Repo.aggregate(from(s in Space, where: s.slug == "hand-over-co"), :count)

      assert :ok = OwnerHandover.complete(user)
      assert Repo.aggregate(Project, :count) == 1
      assert Repo.aggregate(from(s in Space, where: s.slug == "hand-over-co"), :count) == spaces
    end

    test "nothing is created when a project already exists, but the owner is still marked",
         %{org: org} do
      {:ok, _} = Platform.Tasks.create_project(%{name: "Existing", org_id: org.id})
      user = user!()

      assert :ok = OwnerHandover.complete(user)

      assert [%Project{name: "Existing"}] = Repo.all(Project)
      refute Repo.exists?(from(s in Space, where: s.slug == "hand-over-co"))
      assert Accounts.get_user_preferences(user.id)["first_run_goal"] == "owner"
    end

    test "never raises on bad input" do
      assert :ok = OwnerHandover.complete(nil)
      assert :ok = OwnerHandover.complete(%{id: "not-a-uuid"})
    end
  end
end
