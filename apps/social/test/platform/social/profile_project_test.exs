defmodule Platform.Social.ProfileProjectTest do
  @moduledoc """
  Task 01a16532 stage 1: where a profile's renders are stored.
  `default_render_project_id/1` picks the org's only (or first by name)
  non-archived project and never creates one; `create_profile/2` uses it
  when no `project_id` is given; `set_profile_project/4` is approver-only
  and refuses another org's, unknown and archived projects; the
  `profile_needs_project` copy tells a human where to fix it.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  require Ecto.Query

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, Profile}
  alias Platform.Social.Renderer.Fake
  alias Platform.Tasks.Project

  @copy "This profile has no project to store renders in. An approver can set one in Social › Settings › Project for renders."

  defp named_project!(org_id, name) do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: name, org_id: org_id, slug: "p-#{unique()}"})

    project
  end

  defp archive!(project) do
    {:ok, project} = Platform.Tasks.update_project(project, %{archived_at: DateTime.utc_now()})
    project
  end

  defp project_count(org_id),
    do: Repo.aggregate(Ecto.Query.where(Project, [p], p.org_id == ^org_id), :count)

  defp approved_profile!(org_id, attrs \\ %{}) do
    approver = member!(user!(), org_id)

    {:ok, profile} =
      Social.create_profile(
        org_id,
        Map.merge(%{name: "Show #{unique()}", approver_user_ids: [approver.id]}, attrs)
      )

    {profile, approver}
  end

  describe "default_render_project_id/1" do
    test "an org with no projects has no default" do
      assert Social.default_render_project_id(org_id!()) == nil
    end

    test "an org with one project defaults to it" do
      org_id = org_id!()
      only = named_project!(org_id, "Only")
      assert Social.default_render_project_id(org_id) == only.id
    end

    test "with several projects, the first by name wins, not the first inserted" do
      org_id = org_id!()
      _late = named_project!(org_id, "Zulu")
      first = named_project!(org_id, "Alpha")
      _mid = named_project!(org_id, "Mike")
      assert Social.default_render_project_id(org_id) == first.id
    end

    test "an archived project is ignored even when it sorts first" do
      org_id = org_id!()
      named_project!(org_id, "Aardvark") |> archive!()
      live = named_project!(org_id, "Bravo")
      assert Social.default_render_project_id(org_id) == live.id

      only_archived = org_id!()
      named_project!(only_archived, "Gone") |> archive!()
      assert Social.default_render_project_id(only_archived) == nil
    end

    test "a non-uuid org is nil" do
      assert Social.default_render_project_id("nope") == nil
    end
  end

  describe "create_profile/2 project default" do
    test "defaults to the resolver's project and creates no project" do
      org_id = org_id!()
      named_project!(org_id, "Zulu")
      first = named_project!(org_id, "Alpha")
      before = project_count(org_id)

      {:ok, profile} = Social.create_profile(org_id, %{name: "Show #{unique()}"})

      assert profile.project_id == first.id
      assert project_count(org_id) == before
    end

    test "an org with no projects stays nil and gains no project" do
      org_id = org_id!()
      {:ok, profile} = Social.create_profile(org_id, %{"name" => "Show #{unique()}"})
      assert profile.project_id == nil
      assert project_count(org_id) == 0
    end

    test "an explicit project_id wins over the default" do
      org_id = org_id!()
      named_project!(org_id, "Alpha")
      chosen = named_project!(org_id, "Zulu")

      {:ok, profile} =
        Social.create_profile(org_id, %{"name" => "Show", "project_id" => chosen.id})

      assert profile.project_id == chosen.id
    end

    test "an explicit project from another org is refused" do
      org_id = org_id!()
      named_project!(org_id, "Alpha")
      foreign = named_project!(org_id!(), "Foreign")

      assert {:error, changeset} =
               Social.create_profile(org_id, %{name: "Show", project_id: foreign.id})

      assert %{project_id: ["must belong to the profile's org"]} = errors_on(changeset)
    end
  end

  describe "set_profile_project/4" do
    setup do
      org_id = org_id!()
      first = named_project!(org_id, "Alpha")
      second = named_project!(org_id, "Bravo")
      {profile, approver} = approved_profile!(org_id)
      assert profile.project_id == first.id
      %{org_id: org_id, first: first, second: second, profile: profile, approver: approver}
    end

    test "an approver sets the project", w do
      assert {:ok, %Profile{project_id: id}} =
               Social.set_profile_project(w.org_id, w.profile, w.approver.id, w.second.id)

      assert id == w.second.id
      assert Repo.get!(Profile, w.profile.id).project_id == w.second.id
    end

    test "a non-approver is refused and nothing is written", w do
      bystander = member!(user!(), w.org_id)

      assert {:error, :not_an_approver} =
               Social.set_profile_project(w.org_id, w.profile.id, bystander.id, w.second.id)

      assert Repo.get!(Profile, w.profile.id).project_id == w.first.id
    end

    test "an agent is refused and nothing is written", w do
      agent = pinned_agent!(w.org_id)

      assert {:error, :not_a_human} =
               Social.set_profile_project(w.org_id, w.profile, agent.id, w.second.id)

      assert Repo.get!(Profile, w.profile.id).project_id == w.first.id
    end

    # REQUIRED: a project from another org is refused, even for an approver.
    test "a project from another org is refused", w do
      foreign = named_project!(org_id!(), "Foreign")

      assert {:error, changeset} =
               Social.set_profile_project(w.org_id, w.profile, w.approver.id, foreign.id)

      assert %{project_id: ["must belong to the profile's org"]} = errors_on(changeset)
      assert Repo.get!(Profile, w.profile.id).project_id == w.first.id
    end

    test "an unknown project id is refused", w do
      assert {:error, %Ecto.Changeset{}} =
               Social.set_profile_project(
                 w.org_id,
                 w.profile,
                 w.approver.id,
                 Ecto.UUID.generate()
               )

      assert {:error, %Ecto.Changeset{}} =
               Social.set_profile_project(w.org_id, w.profile, w.approver.id, "not-a-uuid")

      assert {:error, %Ecto.Changeset{}} =
               Social.set_profile_project(w.org_id, w.profile, w.approver.id, nil)

      assert Repo.get!(Profile, w.profile.id).project_id == w.first.id
    end

    test "an archived project in the org is refused", w do
      archived = archive!(w.second)

      assert {:error, changeset} =
               Social.set_profile_project(w.org_id, w.profile, w.approver.id, archived.id)

      assert %{project_id: ["must not be an archived project"]} = errors_on(changeset)
      assert Repo.get!(Profile, w.profile.id).project_id == w.first.id
    end

    test "a profile outside the caller's org is not_found", w do
      assert {:error, :not_found} =
               Social.set_profile_project(org_id!(), w.profile, w.approver.id, w.second.id)
    end
  end

  describe "rendering" do
    setup do
      Fake.reset()
      render_world!()
    end

    test "a profile created with the resolved default renders", world do
      {:ok, profile} = Social.create_profile(world.org_id, %{name: "Defaulted #{unique()}"})
      assert profile.project_id == world.project.id

      {:ok, _} = Social.create_account(world.org_id, profile, %{platform: "x", handle: "@d"})
      Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(profile.id))
      clip = file_clip!(%{world | profile: profile}, 4.0, 12.0)

      assert {:ok, %Clip{status: "rendering"}} = Social.render_clip(world.scope, clip.id)
      id = clip.id
      assert_receive {:social_clip, %Clip{id: ^id, status: "rendered"}}, 5_000
    end

    test "the refusal copy is verbatim for humans and agents", world do
      assert Social.profile_needs_project() == @copy
      assert {:error, @copy} = Social.render_project(%Profile{project_id: nil})

      clip = file_clip!(world, 4.0, 12.0)

      Repo.update_all(Ecto.Query.where(Profile, [p], p.id == ^world.profile.id),
        set: [project_id: nil]
      )

      assert {:error, %{code: :profile_needs_project, error: @copy, suggestion: hint}} =
               Platform.Federation.ToolArguments.dispatch(
                 "social_clip_render",
                 %{"clip_id" => clip.id},
                 %{agent_id: world.agent.id}
               )

      assert hint =~ "Social › Settings › Project for renders"
    end
  end
end
