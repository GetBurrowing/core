defmodule PlatformWeb.GamePageControllerTest do
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  alias Platform.{Accounts, Chat, Games, Repo, Tenancy}
  alias Platform.Accounts.User
  alias Platform.Chat.{Attachment, AttachmentStorage}
  alias Platform.Tenancy.{Org, OrgMembership}

  setup do
    previous = Application.get_env(:platform, :game_publications)
    root = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, Platform.TestTemp.path("game-downloads"))
    org = Repo.insert!(Org.changeset(%Org{}, %{name: "Game players", parent_org_id: Tenancy.get_org_by_slug!("acme").id, slug: "players-#{System.unique_integer([:positive])}"}))
    {:ok, stored} = AttachmentStorage.persist_binary_upload("PK-game-fixture", "game.zip", "application/zip")
    artifact = Repo.insert!(Attachment.changeset(%Attachment{}, stored))
    {:ok, community} = Chat.create_space(%{name: "Game community", slug: "game-community-#{System.unique_integer([:positive])}", kind: "channel", org_id: org.id, metadata: %{"public_game_slug" => "voltron"}})
    game = %{"slug" => "voltron", "published" => true, "org_id" => org.id,
      "title" => "Voltron", "summary" => "Four pilots. One robot.",
      "community_space_id" => community.id, "current_version" => "one",
      "releases" => [%{"version" => "one", "attachment_id" => artifact.id,
        "sha256" => artifact.content_hash, "byte_size" => artifact.byte_size}]}
    Application.put_env(:platform, :game_publications, [game])
    on_exit(fn ->
      Application.put_env(:platform, :game_publications, previous || [])
      File.rm_rf!(AttachmentStorage.storage_root())
      Application.put_env(:platform, :chat_attachments_root, root)
      Application.delete_env(:platform, :oidc_mock_response)
    end)
    %{game: game, artifact: artifact, community: community, org: org}
  end

  test "anonymous visitor sees the game and sign-in; no chat membership is required", %{conn: conn} do
    html = conn |> get("/games/voltron") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.query(html, "#game-sign-in") != []
    assert LazyHTML.query(html, "#game-download") == []
    assert conn |> get("/games/not-published") |> response(404) == "Game not found"
    assert conn |> get("/games/voltron/releases/one/download") |> redirected_to() == "/games/voltron/sign-in"
  end

  test "signed-in stranger downloads only the explicitly published artifact", %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{name: "Player", email: "player@example.net", oidc_sub: "game-player"}))
    conn = init_test_session(conn, current_user_id: user.id)
    assert conn |> get("/games/voltron/releases/one/download") |> response(200) == "PK-game-fixture"
    assert conn |> get("/games/voltron/releases/missing/download") |> response(404) == "Release not found"
  end

  test "mismatched or unavailable package fails closed", %{conn: conn, game: game} do
    user = Repo.insert!(User.changeset(%User{}, %{name: "Player", email: "player@example.net", oidc_sub: "game-player"}))
    bad = put_in(game, ["releases", Access.at(0), "sha256"], String.duplicate("0", 64))
    Application.put_env(:platform, :game_publications, [bad])
    conn = init_test_session(conn, current_user_id: user.id)
    assert conn |> get("/games/voltron/releases/one/download") |> response(503) =~ "temporarily unavailable"
  end

  test "game OIDC login returns to its page and creates only external game membership", %{conn: conn, org: org} do
    conn = get(conn, "/auth/login?game=voltron")
    %{state: state} = get_session(conn, :oidc_session_params)
    claims = %{"sub" => "fresh-game-player", "email" => "fresh@example.net", "name" => "Fresh player"}
    Application.put_env(:platform, :oidc_mock_response, {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "test"}}})
    conn = conn |> recycle() |> get("/auth/oidc/callback?" <> URI.encode_query(%{state: state, code: "test"}))
    assert redirected_to(conn) == "/games/voltron"
    user = Accounts.get_user(get_session(conn, :current_user_id))
    assert [%OrgMembership{org_id: org_id, external: true}] = Repo.all(from m in OrgMembership, where: m.user_id == ^user.id)
    assert org_id == org.id
    assert Repo.all(from p in Chat.Participant, where: p.participant_id == ^user.id) == []
    assert get_session(conn, :game_login) == nil
  end

  test "joining is explicit, idempotent, and limited to the tagged community", %{conn: conn, game: game, community: community} do
    user = Repo.insert!(User.changeset(%User{}, %{name: "Player", email: "player@example.net", oidc_sub: "game-player"}))
    assert {:ok, id} = Games.join_community(game, user)
    assert id == community.id
    assert {:ok, ^id} = Games.join_community(game, user)
    assert Repo.aggregate(from(p in Chat.Participant, where: p.participant_id == ^user.id), :count) == 1
    bad = Map.put(game, "slug", "other-game")
    assert {:error, :unavailable} = Games.join_community(bad, user)
    conn = init_test_session(conn, current_user_id: user.id)
    assert conn |> get("/games/voltron?tab=community") |> html_response(200) =~ "community-join"
  end

  test "unknown games cannot set a login destination; ordinary login clears old game intent", %{conn: conn} do
    assert conn |> get("/auth/login?game=unknown") |> response(404) == "Game not found"
    conn = init_test_session(conn, game_login: %{slug: "voltron", expires_at: System.system_time(:second) + 600})
    conn = get(conn, "/auth/login")
    assert get_session(conn, :game_login) == nil
  end

  test "invalid manifests and archived identities are not admitted", %{conn: conn, game: game} do
    refute Games.valid?(Map.put(game, "slug", "//elsewhere"))
    refute Games.valid?(Map.put(game, "image_path", "https://elsewhere/image"))
    user = Repo.insert!(%User{name: "Archived", email: "archived@example.net", oidc_sub: "archived", archived_at: DateTime.utc_now()})
    conn = init_test_session(conn, current_user_id: user.id)
    assert conn |> get("/games/voltron/releases/one/download") |> redirected_to() == "/games/voltron/sign-in"
  end
end
