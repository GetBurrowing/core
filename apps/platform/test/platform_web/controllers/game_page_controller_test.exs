defmodule PlatformWeb.GamePageControllerTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Platform.{Accounts, Chat, Games, Repo, Tenancy}
  alias Platform.Accounts.User
  alias Platform.Chat.{Attachment, AttachmentStorage}
  alias Platform.Tenancy.{Org, OrgMembership}

  setup do
    previous = Application.get_env(:platform, :game_publications)
    root = Application.get_env(:platform, :chat_attachments_root)

    Application.put_env(
      :platform,
      :chat_attachments_root,
      Platform.TestTemp.path("game-downloads")
    )

    org =
      Repo.insert!(
        Org.changeset(%Org{}, %{
          name: "Game players",
          parent_org_id: Tenancy.get_org_by_slug!("acme").id,
          slug: "players-#{System.unique_integer([:positive])}"
        })
      )

    {:ok, stored} =
      AttachmentStorage.persist_binary_upload("PK-game-fixture", "game.zip", "application/zip")

    artifact = Repo.insert!(Attachment.changeset(%Attachment{}, stored))

    {:ok, community} =
      Chat.create_space(%{
        name: "Game community",
        slug: "game-community-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: org.id,
        metadata: %{"public_game_slug" => "voltron"}
      })

    game = %{
      "slug" => "voltron",
      "published" => true,
      "org_id" => org.id,
      "title" => "Voltron",
      "image_path" => "/images/voltron-game.png",
      "summary" => "Four pilots. One robot.",
      "community_space_id" => community.id,
      "current_version" => "one",
      "releases" => [
        %{
          "version" => "one",
          "attachment_id" => artifact.id,
          "sha256" => artifact.content_hash,
          "byte_size" => artifact.byte_size
        }
      ]
    }

    Application.put_env(:platform, :game_publications, [game])

    on_exit(fn ->
      Application.put_env(:platform, :game_publications, previous || [])
      File.rm_rf!(AttachmentStorage.storage_root())
      Application.put_env(:platform, :chat_attachments_root, root)
      Application.delete_env(:platform, :oidc_mock_response)
    end)

    %{game: game, artifact: artifact, community: community, org: org}
  end

  test "Windows player is personal, download-only and scoped to the game", %{
    conn: conn,
    game: game
  } do
    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Player grant",
          email: "player-grant@example.net",
          oidc_sub: "player-grant"
        })
      )

    assert conn |> get("/games/voltron/player") |> redirected_to() == "/games/voltron/sign-in"
    grant = Games.Player.token(game, user)

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> grant)
      |> get("/games/voltron/player/releases/one")

    assert response(response, 200) == "PK-game-fixture"
    assert conn |> get("/games/voltron/player/releases/one") |> response(401)
    assert {:error, :unauthorized} = Games.Player.authorize(Map.put(game, "slug", "other"), grant)
    assert {:error, :unauthorized} = Games.Player.authorize(game, grant <> "bad")

    expired =
      Phoenix.Token.sign(PlatformWeb.Endpoint, "game-player-download-v1", {"voltron", user.id},
        signed_at: System.system_time(:second) - 604_801
      )

    assert {:error, :unauthorized} = Games.Player.authorize(game, expired)
    conn = init_test_session(conn, current_user_id: user.id)
    zip = conn |> get("/games/voltron/player") |> response(200)
    {:ok, files} = :zip.extract(zip, [:memory])
    assert {~c"Play.bat", _} = List.keyfind(files, ~c"Play.bat", 0)
    {_, config} = List.keyfind(files, ~c"player.json", 0)
    assert %{"slug" => "voltron", "token" => token} = Jason.decode!(config)
    assert {:ok, _} = Games.Player.authorize(game, token)
    refute config =~ user.email
    Repo.update!(Ecto.Changeset.change(user, archived_at: DateTime.utc_now()))
    assert {:error, :unauthorized} = Games.Player.authorize(game, grant)
  end

  test "updates describe the pinned current artifact without granting download", %{
    conn: conn,
    game: game
  } do
    update = conn |> get("/games/voltron/updates") |> json_response(200)
    assert update["version"] == "one"
    assert update["sha256"] == Games.current_release(game)["sha256"]
    refute Map.has_key?(update, "token")
    assert conn |> get("/games/unknown/updates") |> response(404)
  end

  test "admin publishes from Burrow without env changes, creates player room, updates and rolls back",
       %{conn: conn, game: game, org: org, artifact: artifact} do
    actor =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Publisher",
          email: "publisher@example.net",
          oidc_sub: "publisher"
        })
      )

    attrs = %{
      "slug" => "test-published",
      "title" => "Test game",
      "summary" => "Physics fun",
      "org_id" => org.id,
      "version" => "one",
      "attachment_id" => artifact.id,
      "published" => "true"
    }

    assert {:error, _} = Games.Publishing.publish_release(actor, attrs)
    root_org = Tenancy.get_org_by_slug!("acme")

    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: actor.id,
        org_id: root_org.id,
        role: "admin"
      })
    )

    signed_in = init_test_session(conn, current_user_id: actor.id)
    {:ok, view, _} = live(signed_in, "/admin/games")
    assert has_element?(view, "#game-publication-form")
    view |> form("#game-publication-form", game: attrs) |> render_submit()
    assert has_element?(view, "#publication-test-published")
    assert {:ok, publication} = Games.Publishing.publish_release(actor, attrs)
    published = Games.get("test-published")
    assert published == publication.manifest
    assert Games.community(published, actor).joined?
    assert published["community_space_id"] != game["community_space_id"]

    {:ok, stored} =
      AttachmentStorage.persist_binary_upload("PK-new-release", "new.zip", "application/zip")

    next = Repo.insert!(Attachment.changeset(%Attachment{}, stored))

    assert {:error, :immutable_release} =
             Games.Publishing.publish_release(actor, Map.put(attrs, "attachment_id", next.id))

    assert {:ok, _} =
             Games.Publishing.publish_release(
               actor,
               Map.merge(attrs, %{"version" => "two", "attachment_id" => next.id})
             )

    assert Games.get("test-published")["current_version"] == "two"
    assert {:ok, _} = Games.Publishing.publish_release(actor, attrs)
    assert Games.get("test-published")["current_version"] == "one"
    assert length(Games.get("test-published")["releases"]) == 2

    assert {:ok, _} =
             Games.Publishing.publish_release(actor, Map.put(attrs, "published", "false"))

    refute Games.get("test-published")
    assert conn |> get("/games/test-published/updates") |> response(404)
  end

  test "anonymous visitor sees the game and sign-in; no chat membership is required", %{
    conn: conn
  } do
    page = conn |> get("/games/voltron") |> html_response(200)
    browser_evidence("visitor", page)
    html = LazyHTML.from_document(page)
    assert Enum.count(LazyHTML.query(html, "#game-sign-in")) == 1
    assert Enum.count(LazyHTML.query(html, "#game-download")) == 0
    assert conn |> get("/games/not-published") |> response(404) == "Game not found"

    assert conn |> get("/games/voltron/releases/one/download") |> redirected_to() ==
             "/games/voltron/sign-in"
  end

  test "signed-in stranger downloads only the explicitly published artifact", %{conn: conn} do
    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Player",
          email: "player@example.net",
          oidc_sub: "game-player"
        })
      )

    conn = init_test_session(conn, current_user_id: user.id)

    assert conn |> get("/games/voltron/releases/one/download") |> response(200) ==
             "PK-game-fixture"

    assert conn |> get("/games/voltron/releases/missing/download") |> response(404) ==
             "Release not found"
  end

  test "mismatched or unavailable package fails closed", %{conn: conn, game: game} do
    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Player",
          email: "player@example.net",
          oidc_sub: "game-player"
        })
      )

    bad = put_in(game, ["releases", Access.at(0), "sha256"], String.duplicate("0", 64))
    Application.put_env(:platform, :game_publications, [bad])
    conn = init_test_session(conn, current_user_id: user.id)

    assert conn |> get("/games/voltron/releases/one/download") |> response(503) =~
             "temporarily unavailable"
  end

  @tag :game_identity
  test "game OIDC login returns to its page and creates only external game membership", %{
    conn: conn,
    org: org
  } do
    conn = get(conn, "/auth/login?game=voltron")
    %{state: state} = get_session(conn, :oidc_session_params)

    claims = %{
      "sub" => "fresh-game-player",
      "email" => "fresh@example.net",
      "name" => "Fresh player"
    }

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "test"}}}
    )

    conn =
      conn
      |> recycle()
      |> get("/auth/oidc/callback?" <> URI.encode_query(%{state: state, code: "test"}))

    assert redirected_to(conn) == "/games/voltron"
    user = Accounts.get_user(get_session(conn, :current_user_id))

    assert [%OrgMembership{org_id: org_id, external: true}] =
             Repo.all(from(m in OrgMembership, where: m.user_id == ^user.id))

    assert org_id == org.id
    refute Tenancy.root_admin?(user)
    assert Repo.all(from(p in Chat.Participant, where: p.participant_id == ^user.id)) == []
    assert get_session(conn, :game_login) == nil
  end

  test "joining is explicit, idempotent, and limited to the tagged community", %{
    conn: conn,
    game: game,
    community: community
  } do
    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Player",
          email: "player@example.net",
          oidc_sub: "game-player"
        })
      )

    assert {:ok, id} = Games.join_community(game, user)
    assert id == community.id
    assert {:ok, ^id} = Games.join_community(game, user)

    assert Repo.aggregate(
             from(p in Chat.Participant, where: p.participant_id == ^user.id),
             :count
           ) == 1

    bad = Map.put(game, "slug", "other-game")
    assert {:error, :unavailable} = Games.join_community(bad, user)
    conn = init_test_session(conn, current_user_id: user.id)
    html = conn |> get("/games/voltron?tab=community") |> html_response(200)
    browser_evidence("community", html)
    assert html =~ "game-live-chat"
    refute html =~ "id=\"community-join\""
    joined = post(conn, "/games/voltron/community", %{})
    assert redirected_to(joined) == "/games/voltron?tab=community"
    document = LazyHTML.from_document(html)
    assert Enum.count(LazyHTML.query(document, "#game-live-chat [data-phx-session]")) == 1

    {:ok, view, _html} =
      live_isolated(conn, PlatformWeb.GameCommunityLive,
        session: %{"game_slug" => "voltron", "current_user_id" => user.id}
      )

    assert has_element?(view, "#compose-form")

    render_submit(view, "send_message", %{
      "compose" => %{"text" => "Ready to play from the game page"}
    })

    assert Enum.any?(
             Chat.list_messages(community.id),
             &(&1.content == "Ready to play from the game page")
           )
  end

  test "unknown games cannot set a login destination; ordinary login clears old game intent", %{
    conn: conn
  } do
    assert conn |> get("/auth/login?game=unknown") |> response(404) == "Game not found"

    conn =
      init_test_session(conn,
        game_login: %{slug: "voltron", expires_at: System.system_time(:second) + 600}
      )

    conn = get(conn, "/auth/login")
    assert get_session(conn, :game_login) == nil
  end

  test "invalid manifests and archived identities are not admitted", %{conn: conn, game: game} do
    refute Games.valid?(Map.put(game, "slug", "//elsewhere"))
    refute Games.valid?(Map.put(game, "image_path", "https://elsewhere/image"))

    user =
      Repo.insert!(%User{
        name: "Archived",
        email: "archived@example.net",
        oidc_sub: "archived",
        archived_at: DateTime.utc_now()
      })

    conn = init_test_session(conn, current_user_id: user.id)

    assert conn |> get("/games/voltron/releases/one/download") |> redirected_to() ==
             "/games/voltron/sign-in"
  end

  test "expired game login cannot fall through into ordinary internal admission", %{conn: conn} do
    claims = %{"sub" => "expired-player", "email" => "expired@example.net", "name" => "Expired"}

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "test"}}}
    )

    conn =
      init_test_session(conn,
        oidc_session_params: %{state: "expected-state", nonce: "n"},
        game_login: %{slug: "voltron", expires_at: 0}
      )

    conn = get(conn, "/auth/oidc/callback?code=test&state=expected-state")
    assert response(conn, 401) =~ "game_login_expired"
    assert Repo.get_by(User, oidc_sub: "expired-player") == nil
  end

  test "existing internal identities keep their memberships on game login", %{game: game} do
    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "internal-player",
        email: "internal@example.net",
        name: "Internal"
      })

    before =
      Repo.all(
        from(m in OrgMembership,
          where: m.user_id == ^user.id,
          select: {m.org_id, m.external, m.role}
        )
      )

    assert :ok = Games.admit_player(game, user)

    assert Repo.all(
             from(m in OrgMembership,
               where: m.user_id == ^user.id,
               select: {m.org_id, m.external, m.role}
             )
           ) == before
  end

  test "changing current release leaves the old release downloadable", %{conn: conn, game: game} do
    second = game["releases"] |> hd() |> Map.put("version", "two")

    game =
      game
      |> Map.put("current_version", "two")
      |> Map.put("releases", game["releases"] ++ [second])

    Application.put_env(:platform, :game_publications, [game])

    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Player",
          email: "player@example.net",
          oidc_sub: "game-player"
        })
      )

    conn = init_test_session(conn, current_user_id: user.id)

    assert conn |> get("/games/voltron/releases/one/download") |> response(200) ==
             "PK-game-fixture"

    assert conn |> get("/games/voltron/releases/two/download") |> response(200) ==
             "PK-game-fixture"
  end

  test "account creation uses only an explicitly configured issuer-host link", %{
    conn: conn,
    game: game
  } do
    assert conn |> get("/games/voltron/create-account") |> response(503) =~ "not available"
    assert Games.signup_url(Map.put(game, "signup_url", "https://other.example/signup")) == nil
    assert Games.signup_url(Map.put(game, "signup_url", "javascript:alert(1)")) == nil
    signup = Platform.OIDC.issuer() <> "/signup/example"
    Application.put_env(:platform, :game_publications, [Map.put(game, "signup_url", signup)])
    assert conn |> get("/games/voltron/create-account") |> redirected_to() == signup
  end

  test "phone visitors see Windows guidance and a real copy-link action", %{conn: conn} do
    html =
      conn
      |> put_req_header("user-agent", "Mozilla iPhone")
      |> get("/games/voltron")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(html, "#game-copy-link")) == 1
    assert Enum.count(LazyHTML.query(html, "[data-game-action][hidden]")) == 1
    refute LazyHTML.text(html) =~ "Email me"
  end

  test "only a successful artifact response acknowledges the exact download request", %{
    conn: conn,
    game: game
  } do
    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Player",
          email: "player@example.net",
          oidc_sub: "cookie-player"
        })
      )

    conn = init_test_session(conn, current_user_id: user.id)
    nonce = String.duplicate("a", 32)
    downloaded = get(conn, "/games/voltron/releases/one/download?download_request=" <> nonce)
    assert downloaded.resp_cookies["burrow_game_download"].value == nonce
    bad = put_in(game, ["releases", Access.at(0), "sha256"], String.duplicate("0", 64))
    Application.put_env(:platform, :game_publications, [bad])
    failed = get(conn, "/games/voltron/releases/one/download?download_request=" <> nonce)
    assert failed.status == 503
    refute Map.has_key?(failed.resp_cookies, "burrow_game_download")
  end

  test "non-members cannot render private chat messages or room codes", %{conn: conn, game: game} do
    assert %{joined?: false, member_count: 0} = Games.community(game, nil)
    html = conn |> get("/games/voltron?tab=community") |> html_response(200)
    refute html =~ "game-live-chat"
    assert html =~ "community-sign-in"
    assert html =~ "after you join"
  end

  # Optional CI artifact from the real controller render, consumed by the
  # approved runner's browser layout check. No production data is used.
  defp browser_evidence(name, html) do
    if directory = System.get_env("GAME_PAGE_BROWSER_EVIDENCE") do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, name <> ".html"), html)
    end
  end

  test "community socket refuses a stale or unjoined identity", %{
    conn: conn,
    game: game,
    community: community
  } do
    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Player",
          email: "player@example.net",
          oidc_sub: "socket-player"
        })
      )

    session = %{"game_slug" => "voltron", "current_user_id" => user.id}
    {:ok, refused, _} = live_isolated(conn, PlatformWeb.GameCommunityLive, session: session)
    assert has_element?(refused, "#game-chat-access-denied")
    refute has_element?(refused, "#compose-form")
    assert {:ok, _} = Games.join_community(game, user)

    Repo.delete_all(
      from(p in Chat.Participant,
        where: p.space_id == ^community.id and p.participant_id == ^user.id
      )
    )

    {:ok, revoked, _} = live_isolated(conn, PlatformWeb.GameCommunityLive, session: session)
    assert has_element?(revoked, "#game-chat-access-denied")
  end

  test "game page does not display the signed-in account name or email", %{conn: conn} do
    user =
      Repo.insert!(
        User.changeset(%User{}, %{
          name: "Private Legal Name",
          email: "private-account@example.net",
          oidc_sub: "private-page-player"
        })
      )

    html =
      conn
      |> init_test_session(current_user_id: user.id)
      |> get("/games/voltron")
      |> html_response(200)

    refute html =~ user.name
    refute html =~ user.email
  end

  test "blank account names never expose email, snapshots or account avatars in the game room", %{
    conn: conn,
    game: game,
    community: community
  } do
    user =
      Repo.insert!(%User{
        name: "",
        email: "private-blank-player@example.net",
        oidc_sub: "blank-public-label",
        avatar_url: "https://private.example/real-face.jpg"
      })

    assert {:ok, _} = Games.join_community(game, user)
    {:ok, participant} = Chat.SpaceAccess.authorize_writer(community.id, user)

    {:ok, _message} =
      Chat.post_message(%{
        space_id: community.id,
        participant_id: participant.id,
        content_type: "text",
        content: "Hello pilots",
        author_display_name: "Legacy Private Legal Name",
        author_avatar_url: user.avatar_url
      })

    session = %{"game_slug" => "voltron", "current_user_id" => user.id}
    {:ok, view, html} = live_isolated(conn, PlatformWeb.GameCommunityLive, session: session)
    assert html =~ Games.player_display_name(user)
    assert html =~ "pilot-"
    refute html =~ user.email
    refute html =~ "Legacy Private Legal Name"
    refute html =~ user.avatar_url
    render_submit(view, "send_message", %{"compose" => %{"text" => "Ready"}})
    refute render(view) =~ user.email
  end

  test "an explicitly chosen player display name is shared by the game card and room", %{
    conn: conn,
    game: game
  } do
    user =
      Repo.insert!(%User{
        name: "Private Account Name",
        email: "private-persona@example.net",
        oidc_sub: "chosen-public-label",
        preferences: %{"player_display_name" => "StarPilot"}
      })

    assert {:ok, _} = Games.join_community(game, user)

    page =
      conn
      |> init_test_session(current_user_id: user.id)
      |> get("/games/voltron")
      |> html_response(200)

    assert page =~ "StarPilot"
    refute page =~ user.name
    refute page =~ user.email
    assert Games.player_display_name(user) == "StarPilot"

    {:ok, view, _} =
      live_isolated(conn, PlatformWeb.GameCommunityLive,
        session: %{"game_slug" => "voltron", "current_user_id" => user.id}
      )

    html = render_submit(view, "send_message", %{"compose" => %{"text" => "Hello crew"}})
    assert html =~ "StarPilot"
    refute html =~ user.name
    refute html =~ user.email
  end

  describe "per-game launcher" do
    test "Voltron without a launch_path keeps its historical launcher", %{conn: conn} do
      assert conn |> get("/games/voltron/updates") |> json_response(200) |> Map.get("launch_path") ==
               "Play Voltron.bat"

      page = conn |> get("/games/voltron") |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.text(LazyHTML.query(page, "#game-launch-path")) == "Play Voltron.bat"
    end

    test "a game's own launch_path is what the player and the page name", %{
      conn: conn,
      game: game
    } do
      sky =
        Map.merge(game, %{
          "slug" => "sky-haulers",
          "title" => "Sky Haulers",
          "launch_path" => "Play Sky Haulers.cmd"
        })

      Application.put_env(:platform, :game_publications, [
        Map.put(game, "launch_path", "Start Voltron.exe"),
        sky
      ])

      assert conn
             |> get("/games/sky-haulers/updates")
             |> json_response(200)
             |> Map.get("launch_path") ==
               "Play Sky Haulers.cmd"

      assert conn |> get("/games/voltron/updates") |> json_response(200) |> Map.get("launch_path") ==
               "Start Voltron.exe"

      page = conn |> get("/games/sky-haulers") |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.text(LazyHTML.query(page, "#game-launch-path")) == "Play Sky Haulers.cmd"
      refute LazyHTML.text(LazyHTML.query(page, "#game-setup")) =~ "Voltron"
    end

    test "a game with no launch_path names no file and says so", %{conn: conn, game: game} do
      Application.put_env(:platform, :game_publications, [
        Map.merge(game, %{"slug" => "tiny-tactics", "title" => "Tiny Tactics"})
      ])

      update = conn |> get("/games/tiny-tactics/updates") |> json_response(200)
      assert Map.has_key?(update, "launch_path")
      assert update["launch_path"] == nil

      page = conn |> get("/games/tiny-tactics") |> html_response(200) |> LazyHTML.from_document()
      assert Enum.count(LazyHTML.query(page, "#game-launch-instructions")) == 1
      assert Enum.empty?(LazyHTML.query(page, "#game-launch-path"))
      assert LazyHTML.text(LazyHTML.query(page, "#game-launch-instructions")) =~ "no launcher yet"
      refute LazyHTML.text(page) =~ "Voltron.bat"
    end

    test "launch_path is one plain file name; anything else rejects the manifest", %{game: game} do
      for ok <- ["Play Voltron.bat", "start.cmd", "Game_v2-final.EXE"] do
        assert Games.launch_path?(ok), ok
        assert Games.valid?(Map.put(game, "launch_path", ok))
      end

      for bad <- [
            "../Play.bat",
            "..\\Play.bat",
            "a..b.bat",
            "/usr/bin/play.bat",
            "C:\\Windows\\play.bat",
            "bin/play.bat",
            "bin\\play.bat",
            "play.bat & calc.exe",
            "play|x.bat",
            "play;x.bat",
            "play%PATH%.bat",
            "play$(x).bat",
            "play`x`.bat",
            "\"play\".bat",
            "play.ps1",
            "play",
            ".play.bat",
            " play.bat",
            "play.bat\n",
            "",
            42
          ] do
        refute Games.launch_path?(bad), inspect(bad)
        refute Games.valid?(Map.put(game, "launch_path", bad)), inspect(bad)
      end
    end
  end

  describe "per-release launcher" do
    defp root_publisher(name) do
      actor =
        Repo.insert!(
          User.changeset(%User{}, %{
            name: name,
            email: "#{name}@example.net",
            oidc_sub: name
          })
        )

      Repo.insert!(
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: actor.id,
          org_id: Tenancy.get_org_by_slug!("acme").id,
          role: "admin"
        })
      )

      actor
    end

    defp zip_attachment(body) do
      {:ok, stored} =
        AttachmentStorage.persist_binary_upload(body, "build.zip", "application/zip")

      Repo.insert!(Attachment.changeset(%Attachment{}, stored))
    end

    defp served_launcher(conn, slug),
      do: conn |> get("/games/#{slug}/updates") |> json_response(200) |> Map.get("launch_path")

    defp page_launcher(conn, slug) do
      page = conn |> get("/games/#{slug}") |> html_response(200) |> LazyHTML.from_document()
      LazyHTML.text(LazyHTML.query(page, "#game-launch-path"))
    end

    test "a rollback serves the launcher of the release it rolls back to", %{
      conn: conn,
      org: org,
      artifact: artifact
    } do
      actor = root_publisher("launcher-publisher")
      next = zip_attachment("PK-renamed-entrypoint")

      v1 = %{
        "slug" => "renamer",
        "title" => "Renamer",
        "summary" => "Renames its entrypoint",
        "org_id" => org.id,
        "version" => "one",
        "attachment_id" => artifact.id,
        "launch_path" => "A.bat",
        "published" => "true"
      }

      v2 =
        Map.merge(v1, %{"version" => "two", "attachment_id" => next.id, "launch_path" => "B.bat"})

      assert {:ok, _} = Games.Publishing.publish_release(actor, v1)
      assert served_launcher(conn, "renamer") == "A.bat"
      assert {:ok, _} = Games.Publishing.publish_release(actor, v2)
      assert served_launcher(conn, "renamer") == "B.bat"
      assert page_launcher(conn, "renamer") == "B.bat"

      # Roll back by republishing v1 without naming a launcher: its own pin wins.
      assert {:ok, _} = Games.Publishing.publish_release(actor, Map.delete(v1, "launch_path"))
      assert Games.get("renamer")["current_version"] == "one"
      assert served_launcher(conn, "renamer") == "A.bat"
      assert page_launcher(conn, "renamer") == "A.bat"
      refute Map.has_key?(Games.get("renamer"), "launch_path")

      assert Enum.map(Games.get("renamer")["releases"], &{&1["version"], &1["launch_path"]}) ==
               [{"one", "A.bat"}, {"two", "B.bat"}]

      # A published release's launcher never changes, through either path.
      assert {:error, :immutable_release} =
               Games.Publishing.publish_release(actor, Map.put(v1, "launch_path", "B.bat"))

      manifest = Games.get("renamer")
      renamed = put_in(manifest, ["releases", Access.at(0), "launch_path"], "B.bat")
      assert {:error, _} = Games.Publishing.save(actor, renamed)

      assert {:error, :immutable_release} =
               Games.Publishing.pin_launch_path(actor, "renamer", "one", "B.bat")

      assert served_launcher(conn, "renamer") == "A.bat"
    end

    test "a legacy release gains a pin once, keeping its bytes and current version", %{
      conn: conn,
      org: org,
      artifact: artifact
    } do
      actor = root_publisher("launcher-pinner")

      attrs = %{
        "slug" => "legacy-pin",
        "title" => "Legacy pin",
        "org_id" => org.id,
        "version" => "one",
        "attachment_id" => artifact.id,
        "published" => "true"
      }

      assert {:ok, _} = Games.Publishing.publish_release(actor, attrs)
      refute Map.has_key?(hd(Games.get("legacy-pin")["releases"]), "launch_path")
      assert served_launcher(conn, "legacy-pin") == nil

      assert {:error, :invalid_publication} =
               Games.Publishing.pin_launch_path(actor, "legacy-pin", "one", "../x.bat")

      assert {:error, :invalid_publication} =
               Games.Publishing.pin_launch_path(actor, "legacy-pin", "missing", "Play.bat")

      before = Games.get("legacy-pin")
      assert {:ok, _} = Games.Publishing.pin_launch_path(actor, "legacy-pin", "one", "Play.bat")
      after_pin = Games.get("legacy-pin")
      assert served_launcher(conn, "legacy-pin") == "Play.bat"

      assert hd(after_pin["releases"]) ==
               Map.put(hd(before["releases"]), "launch_path", "Play.bat")

      assert Map.delete(after_pin, "releases") == Map.delete(before, "releases")

      # Idempotent: the same pin again is a no-op.
      assert {:ok, _} = Games.Publishing.pin_launch_path(actor, "legacy-pin", "one", "Play.bat")
      assert Games.get("legacy-pin") == after_pin
    end

    test "resolution order: release, then game (legacy), then Voltron's historical launcher", %{
      conn: conn,
      game: game
    } do
      release = Games.current_release(game)

      # A legacy manifest with only the game-level value.
      legacy = Map.put(game, "launch_path", "Start.cmd")
      assert Games.launch_path(legacy, release) == "Start.cmd"
      Application.put_env(:platform, :game_publications, [legacy])
      assert served_launcher(conn, "voltron") == "Start.cmd"
      assert page_launcher(conn, "voltron") == "Start.cmd"

      # The release's own value beats the game-level one.
      pinned = put_in(legacy, ["releases", Access.at(0), "launch_path"], "Play Pinned.exe")
      assert Games.launch_path(pinned, Games.current_release(pinned)) == "Play Pinned.exe"
      Application.put_env(:platform, :game_publications, [pinned])
      assert served_launcher(conn, "voltron") == "Play Pinned.exe"

      # Voltron with neither keeps its historical launcher; any other game names none.
      assert Games.launch_path(game, release) == "Play Voltron.bat"
      assert Games.launch_path(Map.put(game, "slug", "other"), release) == nil
    end

    test "a release's launch_path follows the same rules as the game's", %{
      game: game,
      org: org,
      artifact: artifact
    } do
      for ok <- ["Play Voltron.bat", "start.cmd", "Game_v2-final.EXE"] do
        assert Games.valid?(put_in(game, ["releases", Access.at(0), "launch_path"], ok)), ok
      end

      actor = root_publisher("launcher-validator")

      for bad <- [
            "../Play.bat",
            "a..b.bat",
            "bin/play.bat",
            "bin\\play.bat",
            "C:\\Windows\\play.bat",
            "play.bat & calc.exe",
            "play|x.bat",
            "play%PATH%.bat",
            "play.ps1",
            "play",
            ".play.bat",
            "play.bat\n",
            42,
            nil
          ] do
        unless is_nil(bad) do
          refute Games.valid?(put_in(game, ["releases", Access.at(0), "launch_path"], bad)),
                 inspect(bad)
        end

        attrs = %{
          "slug" => "bad-launcher",
          "title" => "Bad launcher",
          "org_id" => org.id,
          "version" => "one",
          "attachment_id" => artifact.id,
          "launch_path" => bad,
          "published" => "true"
        }

        if is_nil(bad) do
          # An omitted launcher is fine; nothing is stored on the release.
          assert {:ok, publication} = Games.Publishing.publish_release(actor, attrs)
          refute Map.has_key?(hd(publication.manifest["releases"]), "launch_path")
        else
          assert {:error, :invalid_publication} =
                   Games.Publishing.publish_release(actor, attrs),
                 inspect(bad)
        end
      end

      refute Games.get("bad-launcher")["releases"] |> hd() |> Map.has_key?("launch_path")
    end
  end

  test "the community header pluralises its member count", %{
    conn: conn,
    community: community
  } do
    header = fn ->
      conn
      |> get("/games/voltron?tab=community")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#game-community .gp-room header div > span")
      |> LazyHTML.text()
      |> String.trim()
    end

    assert header.() == "0 members"

    for n <- 1..2 do
      member =
        Repo.insert!(
          User.changeset(%User{}, %{
            name: "Pilot #{n}",
            email: "pilot-#{n}@example.net",
            oidc_sub: "pilot-#{n}"
          })
        )

      {:ok, _} =
        Chat.add_participant(community.id, %{
          participant_type: "user",
          participant_id: member.id,
          joined_at: DateTime.utc_now()
        })

      assert header.() == if(n == 1, do: "1 member", else: "2 members")
    end
  end

  describe "screenshot gallery" do
    @shots [
      %{
        "path" => "/images/play/voltron-shot-1.png",
        "alt" => "Gameplay: the robot in the street"
      },
      %{"path" => "/images/play/voltron-shot-2.png", "alt" => "Concept art: the lions at dusk"},
      %{"path" => "/images/play/voltron-shot-3.png", "alt" => "Concept art: the city skyline"}
    ]

    test "renders each screenshot as a keyboard-reachable link with a viewer", %{
      conn: conn,
      game: game
    } do
      Application.put_env(:platform, :game_publications, [Map.put(game, "screenshots", @shots)])
      html = conn |> get("/games/voltron") |> html_response(200)
      browser_evidence("gallery", html)
      page = LazyHTML.from_document(html)

      assert Enum.count(LazyHTML.query(page, "#game-screenshots")) == 1
      assert Enum.count(LazyHTML.query(page, "#game-screenshots a.gp-shot[href]")) == 3

      for {shot, n} <- Enum.with_index(@shots, 1) do
        link = LazyHTML.query(page, "#game-shot-#{n}")
        assert LazyHTML.attribute(link, "href") == [shot["path"]]
        assert [label] = LazyHTML.attribute(link, "aria-label")
        assert label =~ shot["alt"]
        assert label =~ "#{n} of 3"
        assert LazyHTML.attribute(LazyHTML.query(link, "img"), "src") == [shot["path"]]
      end

      assert Enum.count(LazyHTML.query(page, "dialog#game-lightbox[data-game-lightbox]")) == 1
      assert Enum.count(LazyHTML.query(page, "#game-lightbox [data-game-lightbox-step]")) == 2
      assert Enum.count(LazyHTML.query(page, "#game-lightbox [data-game-lightbox-close]")) == 1

      # The same gallery inside the Console Glass shell (browser layout evidence).
      admin =
        Repo.insert!(
          User.changeset(%User{}, %{
            name: "Gallery admin",
            email: "gallery-admin@example.net",
            oidc_sub: "gallery-admin"
          })
        )

      Repo.insert!(
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: admin.id,
          org_id: Tenancy.get_org_by_slug!("acme").id,
          role: "admin"
        })
      )

      {:ok, _} = Platform.Branding.update_identity(admin, %{experience: "gaming"})
      glass = conn |> get("/games/voltron") |> html_response(200)
      browser_evidence("gallery-glass", glass)
      glass = LazyHTML.from_document(glass)
      assert Enum.count(LazyHTML.query(glass, "html.console-glass #game-screenshots")) == 1
      assert Enum.count(LazyHTML.query(glass, "#game-screenshots a.gp-shot")) == 3
    end

    test "shows a visible caption under each shot and in the viewer, falling back to alt", %{
      conn: conn,
      game: game
    } do
      shots = [
        Map.put(hd(@shots), "caption", "In-game"),
        Map.put(Enum.at(@shots, 1), "caption", "Concept art"),
        Enum.at(@shots, 2)
      ]

      Application.put_env(:platform, :game_publications, [Map.put(game, "screenshots", shots)])
      page = conn |> get("/games/voltron") |> html_response(200) |> LazyHTML.from_document()

      caption = fn n ->
        page |> LazyHTML.query("#game-shot-caption-#{n}") |> LazyHTML.text() |> String.trim()
      end

      assert caption.(1) == "In-game"
      assert caption.(2) == "Concept art"
      assert caption.(3) == "Concept art: the city skyline"

      # A caption that repeats the link's alt is hidden from assistive tech.
      assert LazyHTML.attribute(LazyHTML.query(page, "#game-shot-caption-1"), "aria-hidden") == []

      assert LazyHTML.attribute(LazyHTML.query(page, "#game-shot-caption-3"), "aria-hidden") == [
               "true"
             ]

      assert LazyHTML.attribute(LazyHTML.query(page, "#game-shot-1"), "data-game-shot-caption") ==
               ["In-game"]

      assert LazyHTML.attribute(LazyHTML.query(page, "#game-shot-3"), "data-game-shot-caption") ==
               ["Concept art: the city skyline"]

      assert page |> LazyHTML.query("#game-lightbox-caption") |> LazyHTML.text() |> String.trim() ==
               "In-game"

      assert LazyHTML.attribute(LazyHTML.query(page, "[data-game-lightbox-image]"), "alt") ==
               [hd(@shots)["alt"]]
    end

    test "is hidden when a game has no screenshots", %{conn: conn, game: game} do
      for manifest <- [game, Map.put(game, "screenshots", [])] do
        Application.put_env(:platform, :game_publications, [manifest])
        page = conn |> get("/games/voltron") |> html_response(200) |> LazyHTML.from_document()
        assert Enum.empty?(LazyHTML.query(page, "#game-screenshots"))
        assert Enum.empty?(LazyHTML.query(page, "#game-lightbox"))
      end
    end

    test "a single screenshot gets a viewer without previous and next", %{conn: conn, game: game} do
      Application.put_env(:platform, :game_publications, [
        Map.put(game, "screenshots", Enum.take(@shots, 1))
      ])

      page = conn |> get("/games/voltron") |> html_response(200) |> LazyHTML.from_document()
      assert Enum.count(LazyHTML.query(page, "#game-shot-1")) == 1
      assert Enum.empty?(LazyHTML.query(page, "#game-lightbox [data-game-lightbox-step]"))
    end

    test "screenshots must be local images with alt text and an optional caption", %{game: game} do
      assert Games.valid?(Map.put(game, "screenshots", @shots))

      assert Games.valid?(
               Map.put(game, "screenshots", [Map.put(hd(@shots), "caption", "In-game")])
             )

      for bad <- [
            "/images/a.png",
            [%{"path" => "https://elsewhere/a.png", "alt" => "x"}],
            [%{"path" => "/images/../secret.png", "alt" => "x"}],
            [%{"path" => "/uploads/a.png", "alt" => "x"}],
            [%{"path" => "/images/a.png?x=1", "alt" => "x"}],
            [%{"path" => "/images/a.png"}],
            [%{"path" => "/images/a.png", "alt" => ""}],
            [%{"path" => "/images/a.png", "alt" => "x", "onclick" => "x"}],
            [%{"path" => "/images/a.png", "alt" => "x", "caption" => ""}],
            [%{"path" => "/images/a.png", "alt" => "x", "caption" => nil}],
            [%{"path" => "/images/a.png", "alt" => "x", "caption" => 7}],
            [%{"path" => "/images/a.png", "alt" => "x", "caption" => String.duplicate("c", 201)}],
            List.duplicate(hd(@shots), 9)
          ] do
        refute Games.valid?(Map.put(game, "screenshots", bad)), inspect(bad)
      end
    end
  end
end
