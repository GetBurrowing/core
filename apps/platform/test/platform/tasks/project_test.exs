defmodule Platform.Tasks.ProjectTest do
  use Platform.DataCase, async: true

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

  describe "list_projects/0" do
    test "returns all projects ordered by name" do
      {:ok, _} = Tasks.create_project(%{name: "Bravo"})
      {:ok, _} = Tasks.create_project(%{name: "Alpha"})
      projects = Tasks.list_projects()
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
