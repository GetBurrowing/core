defmodule PlatformWeb.GamingControllerTest do
  use PlatformWeb.ConnCase, async: false
  alias Platform.{Branding, Games, Repo, Tenancy}
  alias Platform.Accounts.User
  alias Platform.Tenancy.OrgMembership

  setup do
    old = Application.get_env(:platform, :game_publications)

    on_exit(fn ->
      Application.put_env(:platform, :game_publications, old || [])
      Application.delete_env(:platform, :oidc_mock_response)
    end)

    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Private account name",
          email: "gaming-owner@example.invalid",
          oidc_sub: "gaming-owner"
        })
      )

    org = Tenancy.get_org_by_slug!("acme")

    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{user_id: user.id, org_id: org.id, role: "admin"})
    )

    game = %{
      "slug" => "example-game",
      "published" => true,
      "org_id" => org.id,
      "title" => "Example game",
      "summary" => "Make a spectacular mess.",
      "image_path" => "/images/voltron-game.png",
      "current_version" => "one",
      "releases" => [
        %{
          "version" => "one",
          "attachment_id" => Ecto.UUID.generate(),
          "sha256" => String.duplicate("a", 64),
          "byte_size" => 1000
        }
      ]
    }

    Application.put_env(:platform, :game_publications, [game])
    %{actor: user, game: game}
  end

  test "workspace installs keep their root and do not expose gaming home", %{conn: conn} do
    refute Platform.Gaming.enabled?()
    assert conn |> get("/play") |> response(404)
    assert conn |> get("/") |> redirected_to() != "/play"
  end

  test "only an install admin can enable gaming; invalid profiles are rejected", %{actor: actor} do
    assert {:error, :unauthorized} = Branding.update_identity(nil, %{experience: "gaming"})
    assert {:error, _} = Branding.update_identity(actor, %{experience: "other"})
    assert {:ok, _} = Branding.update_identity(actor, %{experience: "gaming"})
    assert Platform.Gaming.enabled?()
    assert PlatformWeb.ManifestController.manifest().start_url == "/play"
  end

  test "gaming app root is public and the home uses actual published games", %{
    conn: conn,
    actor: actor
  } do
    {:ok, _} = Branding.update_identity(actor, %{experience: "gaming"})
    assert conn |> get("/") |> redirected_to() == "/play"
    page = conn |> get("/play") |> html_response(200)
    evidence("gaming-visitor", page)
    doc = LazyHTML.from_document(page)
    assert Enum.count(LazyHTML.query(doc, "#gaming-play[href='/games/example-game']")) == 1
    assert Enum.empty?(LazyHTML.query(doc, "#gaming-create"))
    assert Enum.empty?(LazyHTML.query(doc, "a[href='/tasks']"))
    assert Enum.empty?(LazyHTML.query(doc, "#gaming-community-count"))
    assert Enum.map(Games.list_published(), & &1["slug"]) == ["example-game"]
  end

  test "home shows the player persona and creator entry without account identity", %{
    conn: conn,
    actor: actor
  } do
    {:ok, _} = Branding.update_identity(actor, %{experience: "gaming"})
    conn = init_test_session(conn, current_user_id: actor.id)
    page = conn |> get("/play") |> html_response(200)
    evidence("gaming-owner", page)
    doc = LazyHTML.from_document(page)
    assert Enum.count(LazyHTML.query(doc, "#gaming-create[href='/admin/games']")) == 1

    assert doc |> LazyHTML.query("#gaming-persona") |> LazyHTML.text() |> String.trim() ==
             Games.player_display_name(actor)

    refute page =~ actor.email
    refute page =~ actor.name
  end

  test "unpublished stored games override configured entries and empty home is honest", %{
    conn: conn,
    actor: actor,
    game: game
  } do
    {:ok, _} = Branding.update_identity(actor, %{experience: "gaming"})

    Repo.insert!(
      Ecto.Changeset.change(%Games.Publication{slug: game["slug"]},
        manifest: Map.put(game, "published", false)
      )
    )

    assert Games.list_published() == []
    page = conn |> get("/play") |> html_response(200)
    evidence("gaming-empty", page)
    doc = LazyHTML.from_document(page)
    assert Enum.count(LazyHTML.query(doc, "#gaming-empty")) == 1
    assert Enum.empty?(LazyHTML.query(doc, "#gaming-play"))
  end

  test "workspace and meet roots remain separate from the gaming app root", %{
    conn: conn,
    actor: actor
  } do
    {:ok, _} = Branding.update_identity(actor, %{experience: "gaming"})
    meet = %{conn | host: "meet.example.test"} |> get("/")
    refute get_resp_header(meet, "location") == ["/play"]
  end

  test "ordinary owner login lands on the gaming home instead of business setup", %{
    conn: conn,
    actor: actor
  } do
    {:ok, _} = Branding.update_identity(actor, %{experience: "gaming"})
    claims = %{"sub" => actor.oidc_sub, "email" => actor.email, "name" => actor.name}

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "test"}}}
    )

    conn = init_test_session(conn, oidc_session_params: %{state: "gaming-state", nonce: "n"})
    response = get(conn, "/auth/oidc/callback?code=test&state=gaming-state")
    assert redirected_to(response) == "/play"
    assert get_session(response, :current_user_id) == actor.id
  end

  test "three independent games keep their pages, rooms and scoped create projects", %{conn: conn, actor: actor, game: game} do
    {:ok, _} = Branding.update_identity(actor, %{experience: "gaming"})
    games = for {slug, title, placeholder} <- [{"voltron", "Voltron", false}, {"sky-haulers", "Sky Haulers", true}, {"tiny-tactics", "Tiny Tactics", true}] do
      project = Repo.insert!(Platform.Tasks.Project.changeset(%Platform.Tasks.Project{}, %{name: title, slug: slug, org_id: game["org_id"]}))
      {:ok, room} = Platform.Chat.create_space(%{name: title <> " players", slug: slug <> "-players", kind: "channel", org_id: game["org_id"], metadata: %{"public_game_slug" => slug}})
      Map.merge(game, %{"slug" => slug, "title" => title, "placeholder" => placeholder, "project_id" => project.id, "community_space_id" => room.id})
    end
    Application.put_env(:platform, :game_publications, games)
    visitor = get(conn, "/play") |> html_response(200)
    evidence("gaming-three", visitor)
    doc = LazyHTML.from_document(visitor)
    assert Enum.count(LazyHTML.query(doc, "[data-game-tile]")) == 3
    assert Enum.count(LazyHTML.query(doc, "#gaming-play[href='/games/voltron']")) == 1
    for game <- games do
      page = get(build_conn(), "/games/#{game["slug"]}") |> html_response(200)
      evidence("gaming-game-" <> game["slug"], page)
      assert Enum.count(LazyHTML.query(LazyHTML.from_document(page), "#console-glass-shell")) == 1
      assert Enum.count(LazyHTML.query(LazyHTML.from_document(page), "#game-placeholder-notice")) == if(game["placeholder"], do: 1, else: 0)
      refute page =~ "/files/#{game["project_id"]}"
      assert Games.community(game, nil).space.id == game["community_space_id"]
    end
    owner = init_test_session(build_conn(), current_user_id: actor.id)
    create = get(owner, "/play?mode=create") |> html_response(200)
    evidence("gaming-create", create)
    for game <- games, do: assert(create =~ "/files/#{game["project_id"]}")
    # A publication cannot expose a project from a different organisation.
    wrong = Map.put(hd(games), "org_id", Ecto.UUID.generate())
    assert Platform.Gaming.projects(actor, [wrong])[wrong["slug"]] == nil
    discover = get(build_conn(), "/play?mode=discover&catalog[q]=sky") |> html_response(200)
    evidence("gaming-discover", discover)
    tiles = LazyHTML.query(LazyHTML.from_document(discover), "[data-game-tile]")
    assert Enum.count(tiles) == 1
    assert LazyHTML.attribute(tiles, "href") == ["/games/sky-haulers"]
  end

  defp evidence(name, html) do
    if directory = System.get_env("GAME_PAGE_BROWSER_EVIDENCE") do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, name <> ".html"), html)
    end
  end
end
