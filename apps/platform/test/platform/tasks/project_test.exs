defmodule Platform.Tasks.ProjectTest do
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Tasks
  alias Platform.Tasks.Project

  describe "create_project/1" do
    test "creates a project with valid attrs" do
      assert {:ok, %Project{} = project} =
               Tasks.create_project(%{name: "My App", repo_url: "https://github.com/org/repo"})

      assert project.name == "My App"
      assert project.slug == "my-app"
      assert project.repo_url == "https://github.com/org/repo"
      assert project.default_branch == "main"
    end

    test "auto-generates slug from name" do
      assert {:ok, project} = Tasks.create_project(%{name: "Hello World Project"})
      assert project.slug == "hello-world-project"
    end

    test "uses provided slug instead of generating" do
      assert {:ok, project} = Tasks.create_project(%{name: "My App", slug: "custom-slug"})
      assert project.slug == "custom-slug"
    end

    test "fails without name" do
      assert {:error, changeset} = Tasks.create_project(%{slug: "test"})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "fails with duplicate slug" do
      assert {:ok, _} = Tasks.create_project(%{name: "First", slug: "unique-slug"})
      assert {:error, changeset} = Tasks.create_project(%{name: "Second", slug: "unique-slug"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    # ── ADR 0042: org_id is required ───────────────────────────────────────

    test "defaults org_id to root Fabrikam when omitted (legacy callers)" do
      assert {:ok, project} = Tasks.create_project(%{name: "Defaulted"})
      assert project.org_id == fabrikam_org_id()
    end

    test "honors an explicitly-passed tenant org_id" do
      tenant_id = tenant_org_id("soylent")

      assert {:ok, project} = Tasks.create_project(%{name: "Soylent Tool", org_id: tenant_id})
      assert project.org_id == tenant_id
    end

    test "changeset rejects org_id: nil" do
      changeset = Project.changeset(%Project{}, %{name: "NoOrg", org_id: nil})
      refute changeset.valid?
      assert %{org_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "FK violation when org_id references a non-existent org" do
      bogus = Ecto.UUID.generate()

      assert {:error, changeset} =
               Tasks.create_project(%{name: "Phantom", org_id: bogus})

      assert %{org_id: ["does not exist"]} = errors_on(changeset)
    end

    # task 019edbc1 stage 2: project lifecycle topic for long-lived
    # subscribers (e.g. Platform.Meetings.MeetingNotifier) — proves the
    # broadcast fires so subscribers can attach to per-project topics
    # without waiting for the first meeting.
    test "broadcasts {:project_created, project} on projects:lifecycle" do
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Tasks.projects_lifecycle_topic())

      assert {:ok, project} = Tasks.create_project(%{name: "Broadcast Project"})

      assert_receive {:project_created, ^project}, 1_000
    end

    test "does NOT broadcast on insert failure" do
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Tasks.projects_lifecycle_topic())

      assert {:error, _changeset} = Tasks.create_project(%{slug: "no-name"})

      # Scoped to the slug THIS test attempted, not a bare `_`.
      #
      # `projects_lifecycle_topic/0` is a single global topic and this case
      # is `async: true`, so every concurrently-running case that creates a
      # project broadcasts here. `Platform.Tasks.StageTest` (also async)
      # calls `create_project(%{name: "Stage Project"})` in its *setup*, so
      # it broadcasts once per test in that file — reliably landing inside
      # this 200ms window and tripping a bare `refute_receive`.
      #
      # Matching the slug keeps the guarantee that matters (a failed insert
      # must not broadcast) while being immune to siblings: no row was
      # inserted, so nothing carrying slug "no-name" can legitimately exist.
      refute_receive {:project_created, %{slug: "no-name"}}, 200
    end
  end

  describe "update_project/2" do
    test "updates project attributes" do
      {:ok, project} = Tasks.create_project(%{name: "Old Name"})
      assert {:ok, updated} = Tasks.update_project(project, %{name: "New Name"})
      assert updated.name == "New Name"
    end
  end

  describe "get_project/1 and get_project_by_slug/1" do
    test "fetches by id" do
      {:ok, project} = Tasks.create_project(%{name: "Findable"})
      assert Tasks.get_project(project.id).id == project.id
    end

    test "fetches by slug" do
      {:ok, project} = Tasks.create_project(%{name: "Findable", slug: "findable"})
      assert Tasks.get_project_by_slug("findable").id == project.id
    end

    test "returns nil for missing" do
      assert Tasks.get_project(Ecto.UUID.generate()) == nil
      assert Tasks.get_project_by_slug("nope") == nil
    end
  end

  describe "list_projects_unscoped/1" do
    test "returns all projects ordered by name" do
      {:ok, _} = Tasks.create_project(%{name: "Bravo"})
      {:ok, _} = Tasks.create_project(%{name: "Alpha"})
      projects = Tasks.list_projects_unscoped()
      names = Enum.map(projects, & &1.name)
      assert ["Alpha", "Bravo"] == names
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
