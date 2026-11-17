defmodule PlatformWeb.GameStudioLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.{Branding, Chat, Repo, Tasks, Tenancy}

  setup %{conn: conn} do
    old = Application.get_env(:platform, :game_publications)
    on_exit(fn -> Application.put_env(:platform, :game_publications, old || []) end)
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "studio-#{n}@example.invalid",
        name: "Studio user",
        oidc_sub: "studio-#{n}",
        preferences: %{"first_run_goal" => "existing"}
      })

    org = Tenancy.get_org_by_slug!("acme")
    Repo.insert!(%Platform.Tenancy.OrgMembership{user_id: user.id, org_id: org.id, role: "admin"})
    {:ok, _} = Branding.update_identity(user, %{experience: "gaming"})

    {:ok, project} =
      Tasks.create_project(%{name: "Voltron", org_id: org.id, tech_stack: %{"engine" => "godot"}})

    {:ok, space} =
      Chat.create_channel(%{
        name: "Game dev",
        slug: "studio-dev-#{n}",
        org_id: org.id,
        created_by: user.id,
        metadata: %{"goal_project_id" => project.id}
      })

    {:ok, project} =
      Tasks.update_project(project, %{config: %{"development_space_id" => space.id}})

    Application.put_env(:platform, :game_publications, [
      %{
        "slug" => "voltron",
        "published" => true,
        "org_id" => org.id,
        "project_id" => project.id,
        "development_space_id" => space.id,
        "title" => "Voltron",
        "summary" => "Build a giant mech together.",
        "image_path" => "/images/voltron-game.png",
        "current_version" => "test-build",
        "releases" => [
          %{
            "version" => "test-build",
            "attachment_id" => Ecto.UUID.generate(),
            "sha256" => String.duplicate("a", 64),
            "byte_size" => 1000
          }
        ]
      }
    ])

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
      project: project,
      space: space
    }
  end

  test "default entry goes directly into studio; discover remains available", %{conn: conn} do
    assert conn |> get("/play") |> redirected_to() == "/studio"
    assert conn |> get("/play?mode=discover") |> html_response(200) =~ "Find your next obsession"
  end

  test "studio embeds the actual authorized project chat and project actions", %{
    conn: conn,
    project: project,
    space: space
  } do
    {:ok, view, html} = live(conn, "/studio?project=#{project.id}")

    if directory = System.get_env("STUDIO_EVIDENCE") do
      File.mkdir_p!(directory)

      File.write!(
        Path.join(directory, "studio.html"),
        conn |> get("/studio?project=#{project.id}") |> html_response(200)
      )
    end

    assert has_element?(view, "#game-studio")
    assert html =~ "studio-chat-#{space.id}"
    refute html =~ "the Transcript tab is for"
    assert html =~ "Start the conversation"
    assert has_element?(view, "#studio-playtest")
    assert has_element?(view, "a[href='/studio/chat?project=#{project.id}']", "Ask an agent")
    assert has_element?(view, "#bottom-nav [data-destination=studio][aria-current=page]")
    assert has_element?(view, "#bottom-nav [data-destination=playtest]")
  end

  test "new-game form does not send existing members into first-run onboarding", %{conn: conn} do
    {:ok, view, _} = live(conn, "/studio?new=1")
    assert has_element?(view, "#studio-new-game")
    assert has_element?(view, "select[name='game[engine]'] option[value=godot]")
    refute has_element?(view, "#studio-playtest")
  end

  test "a public community is never used as a development conversation", %{
    conn: conn,
    project: project,
    space: space
  } do
    {:ok, _} =
      Chat.update_space(space, %{metadata: Map.put(space.metadata, "public_game_slug", "test")})

    {:ok, view, html} = live(conn, "/studio?project=#{project.id}")
    refute html =~ "studio-chat-#{space.id}"
    refute has_element?(view, "#studio-playtest")
    assert html =~ "Connect your team room"
  end

  test "foreign and malformed project selection never reveals foreign project data", %{
    conn: conn,
    user: user
  } do
    membership = Repo.get_by!(Platform.Tenancy.OrgMembership, user_id: user.id)
    own_org_id = Platform.TenancyFixtures.tenant_org_id("initech")
    membership |> Ecto.Changeset.change(role: "member", org_id: own_org_id) |> Repo.update!()

    {:ok, other_org} =
      Repo.insert(%Tenancy.Org{
        name: "Foreign studio",
        slug: "foreign-studio-#{System.unique_integer([:positive])}",
        parent_org_id: Tenancy.get_root_org().id
      })

    {:ok, project} =
      Tasks.create_project(%{
        name: "Secret foreign game",
        org_id: other_org.id,
        tech_stack: %{"engine" => "godot"}
      })

    {:ok, _, html} = live(conn, "/studio?project=#{project.id}")
    refute html =~ "Secret foreign game"
    {:ok, _, html} = live(conn, "/studio?project=broken")
    refute html =~ "Secret foreign game"
  end

  test "starting a game creates a project, development room and actual setup brief", %{
    user: user,
    project: existing
  } do
    agent = Platform.PrototypeFixtures.agent!()

    assert {:ok, project, :requested} =
             Platform.Gaming.NewGame.create(
               user,
               %{
                 "name" => "Tiny physics game",
                 "engine" => "godot",
                 "org_id" => existing.org_id,
                 "idea" => "Throw cars together"
               },
               agent_provider: fn -> {:ok, agent} end
             )

    assert project.repo_url == nil
    assert project.tech_stack["engine"] == "godot"
    space = Chat.get_space(project.config["development_space_id"])
    assert space.metadata["goal_project_id"] == project.id
    assert is_nil(space.metadata["public_game_slug"])
    assert Chat.get_agent_participant(space.id, agent.id)

    assert Enum.any?(
             Chat.list_messages(space.id),
             &String.contains?(&1.content, "Throw cars together")
           )

    assert Enum.any?(Platform.Gaming.Studio.list(user), &(&1.project.id == project.id))
  end

  test "unavailable setup agent leaves no orphan project", %{user: user, project: project} do
    before = length(Tasks.list_projects_for_user(user))

    assert {:error, :setup_unavailable} =
             Platform.Gaming.NewGame.create(
               user,
               %{"name" => "Never provisioned", "engine" => "godot", "org_id" => project.org_id},
               agent_provider: fn -> {:error, :no_agent} end
             )

    assert length(Tasks.list_projects_for_user(user)) == before
  end
end
