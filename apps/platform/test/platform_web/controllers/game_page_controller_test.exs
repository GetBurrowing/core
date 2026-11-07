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
    user = Repo.insert!(User.changeset(%User{}, %{name: "Private Legal Name", email: "private-account@example.net", oidc_sub: "private-page-player"}))
    html = conn |> init_test_session(current_user_id: user.id) |> get("/games/voltron") |> html_response(200)
    refute html =~ user.name
    refute html =~ user.email
  end


  test "blank account names never expose email, snapshots or account avatars in the game room", %{conn: conn, game: game, community: community} do
    user = Repo.insert!(%User{name: "", email: "private-blank-player@example.net", oidc_sub: "blank-public-label", avatar_url: "https://private.example/real-face.jpg"})
    assert {:ok, _} = Games.join_community(game, user)
    {:ok, participant} = Chat.SpaceAccess.authorize_writer(community.id, user)
    {:ok, _message} = Chat.post_message(%{space_id: community.id, participant_id: participant.id,
      content_type: "text", content: "Hello pilots", author_display_name: "Legacy Private Legal Name",
      author_avatar_url: user.avatar_url})
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

  test "an explicitly chosen player display name is shared by the game card and room", %{conn: conn, game: game} do
    user = Repo.insert!(%User{name: "Private Account Name", email: "private-persona@example.net", oidc_sub: "chosen-public-label", preferences: %{"player_display_name" => "StarPilot"}})
    assert {:ok, _} = Games.join_community(game, user)
    page = conn |> init_test_session(current_user_id: user.id) |> get("/games/voltron") |> html_response(200)
    assert page =~ "StarPilot"
    refute page =~ user.name
    refute page =~ user.email
    assert Games.player_display_name(user) == "StarPilot"
    {:ok, view, _} = live_isolated(conn, PlatformWeb.GameCommunityLive,
      session: %{"game_slug" => "voltron", "current_user_id" => user.id})
    html = render_submit(view, "send_message", %{"compose" => %{"text" => "Hello crew"}})
    assert html =~ "StarPilot"
    refute html =~ user.name
    refute html =~ user.email
  end

end
