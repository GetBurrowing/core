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

  # ── Lifecycle hook pipelines (task 019fe1b6 stage 3) ──────────────────
  describe "lifecycle_pipeline validation in the changeset" do
    setup context do
      name = :"project_lifecycle_registry_#{:erlang.phash2(context.test)}"
      start_supervised!({Platform.Lifecycle.StepRegistry, name: name})

      previous = Application.get_env(:platform, :lifecycle_step_registry)
      Application.put_env(:platform, :lifecycle_step_registry, name)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:platform, :lifecycle_step_registry)
          value -> Application.put_env(:platform, :lifecycle_step_registry, value)
        end
      end)

      :ok
    end

    defp lifecycle_step(overrides \\ %{}) do
      Map.merge(%{"step" => "notify", "await" => false, "can_divert" => false}, overrides)
    end

    defp with_pipeline(pipeline), do: %{"lifecycle_pipeline" => pipeline}

    test "a valid pipeline saves and resolves in declared order" do
      first = lifecycle_step()
      second = Map.put(lifecycle_step(), "label", "second")

      assert {:ok, project} =
               Tasks.create_project(%{
                 name: "Pipeline Project",
                 config: with_pipeline(%{"planning.entered" => [first, second]})
               })

      assert Platform.Lifecycle.resolve_steps(project, "planning.entered") == [first, second]
    end

    test "a step naming a loaded module is rejected on :config and NOT persisted" do
      assert {:error, changeset} =
               Tasks.create_project(%{
                 name: "Module Step",
                 config:
                   with_pipeline(%{"planning.entered" => [lifecycle_step(%{"step" => "Enum"})]})
               })

      assert %{config: [reason]} = errors_on(changeset)
      assert reason =~ "names a module"
      assert Tasks.list_projects_unscoped() |> Enum.all?(&(&1.name != "Module Step"))
    end

    test "a malformed await is rejected on :config and NOT persisted" do
      assert {:error, changeset} =
               Tasks.create_project(%{
                 name: "Bad Await",
                 config:
                   with_pipeline(%{"planning.entered" => [lifecycle_step(%{"await" => "true"})]})
               })

      assert %{config: [reason]} = errors_on(changeset)
      assert reason =~ "\"await\" must be a boolean"
      assert Tasks.list_projects_unscoped() |> Enum.all?(&(&1.name != "Bad Await"))
    end

    test "a non-map lifecycle_pipeline is rejected" do
      assert {:error, changeset} =
               Tasks.create_project(%{name: "Not A Map", config: with_pipeline("nope")})

      assert %{config: [reason]} = errors_on(changeset)
      assert reason =~ "lifecycle_pipeline must be a map"
    end

    test "a project with unrelated config keys and no pipeline still saves" do
      # Control: without this, a validator that rejected every :config
      # change would pass the cases above.
      assert {:ok, project} =
               Tasks.create_project(%{
                 name: "Unrelated Config",
                 config: %{"some_other_feature" => %{"enabled" => true}}
               })

      assert project.config == %{"some_other_feature" => %{"enabled" => true}}
      assert Platform.Lifecycle.resolve_pipeline(project) == %{}
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
