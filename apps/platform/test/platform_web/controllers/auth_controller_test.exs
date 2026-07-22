defmodule PlatformWeb.AuthControllerTest do
  use PlatformWeb.ConnCase

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalDmAllowlistEntry
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    :ok
  end

  test "GET /auth/login redirects to the provider and stores session params", %{conn: conn} do
    conn = get(conn, ~p"/auth/login")

    assert redirected_to(conn, 302) =~ "https://issuer.example.com/authorize?"
    assert %{state: _, nonce: _} = get_session(conn, :oidc_session_params)
  end

  test "GET /auth/oidc/callback creates a user, stores avatar metadata, and signs them in", %{
    conn: conn
  } do
    mock_oidc_response(%{
      user: base_claims(),
      userinfo:
        Map.put(base_claims(), "picture", "https://issuer.example.com/userinfo-avatar.png"),
      id_token:
        Map.put(base_claims(), "picture", "https://issuer.example.com/id-token-avatar.png")
    })

    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=expected-state")

    assert redirected_to(conn, 302) == ~p"/"

    user_id = get_session(conn, :current_user_id)
    assert user_id

    user = Repo.get!(User, user_id)
    assert user.email == "user@example.com"
    assert user.name == "Test User"
    assert user.oidc_sub == "test-subject"
    assert user.avatar_url == "https://issuer.example.com/id-token-avatar.png"
    assert user.avatar_source == :oidc
    assert get_session(conn, :oidc_id_token) == "test-id-token"
  end

  test "GET /auth/oidc/callback refreshes an existing user's name and avatar on repeat login",
       %{conn: conn} do
    existing_user =
      insert_user(%{
        name: "Old Name",
        avatar_url: "https://issuer.example.com/old-avatar.png",
        avatar_source: :generated
      })

    mock_oidc_response(%{
      user: base_claims(%{"name" => "Renamed User"}),
      userinfo: base_claims(%{"name" => "Renamed User"}),
      id_token:
        base_claims(%{
          "name" => "Renamed User",
          "picture" => "https://issuer.example.com/new-avatar.png"
        })
    })

    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=expected-state")

    assert redirected_to(conn, 302) == ~p"/"
    assert get_session(conn, :current_user_id) == existing_user.id

    user = Repo.get!(User, existing_user.id)
    assert user.name == "Renamed User"
    assert user.avatar_url == "https://issuer.example.com/new-avatar.png"
    assert user.avatar_source == :oidc
  end

  test "GET /auth/oidc/callback keeps the stored avatar when the provider omits picture", %{
    conn: conn
  } do
    existing_user =
      insert_user(%{
        avatar_url: "https://issuer.example.com/stable-avatar.png",
        avatar_source: :oidc
      })

    mock_oidc_response(%{
      user: base_claims(%{"name" => "Still Test User"}),
      userinfo: base_claims(%{"name" => "Still Test User"}),
      id_token: base_claims(%{"name" => "Still Test User"})
    })

    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=expected-state")

    assert redirected_to(conn, 302) == ~p"/"
    assert get_session(conn, :current_user_id) == existing_user.id

    user = Repo.get!(User, existing_user.id)
    assert user.name == "Still Test User"
    assert user.avatar_url == "https://issuer.example.com/stable-avatar.png"
    assert user.avatar_source == :oidc
  end

  test "GET /auth/oidc/callback rejects an invalid state", %{conn: conn} do
    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=wrong-state")

    assert response(conn, 401) =~ "Invalid OIDC state"
  end

  describe "archived user (Stage 5)" do
    test "GET /auth/oidc/callback rejects an archived user with 403 and no session", %{
      conn: conn
    } do
      # Seed an existing archived user under the same OIDC sub the mock
      # response will present. The callback path resolves by `oidc_sub`,
      # sees `archived_at != nil`, and must refuse.
      user = insert_user()
      {:ok, _archived} = Accounts.archive_user(user)

      mock_oidc_response(%{
        user: base_claims(),
        userinfo: base_claims(),
        id_token: base_claims()
      })

      conn =
        init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

      conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=expected-state")

      body = response(conn, 403)
      assert body =~ "archived"
      assert body =~ "Suite administrator"

      # No `current_user_id` planted in the session, and any bleed-through
      # was dropped by `configure_session(drop: true)`.
      # `configure_session(drop: true)` marks the cookie for teardown;
      # in-memory `get_session` still returns the pre-drop state during
      # this request, but critically no `:current_user_id` was ever set.
      assert get_session(conn, :current_user_id) == nil or
               conn.private.plug_session_info == :drop
    end

    test "AuthController.dev_login refuses an archived user without crashing", %{conn: conn} do
      # The `/dev/login` route is only registered in `Mix.env() == :dev`
      # (see router.ex:103), so we invoke the controller action
      # directly. This guards a real regression: prior to Stage 5 the
      # action pattern-matched `{:ok, user} = find_or_create_from_oidc(...)`
      # which FunctionClauseError-crashed on `{:error, :user_archived}`.
      slug = "archived-dev-#{System.unique_integer([:positive])}"

      {:ok, user} =
        Accounts.find_or_create_from_oidc(%{
          sub: "dev-#{slug}",
          email: "#{slug}@localhost",
          name: "Dev #{slug}"
        })

      {:ok, _archived} = Accounts.archive_user(user)

      conn =
        conn
        |> init_test_session(%{})
        |> PlatformWeb.AuthController.dev_login(%{"as" => slug})

      body = response(conn, 403)
      assert body =~ "archived"

      assert get_session(conn, :current_user_id) == nil or
               conn.private.plug_session_info == :drop
    end
  end

  describe "external admission routing (M2 stage 3)" do
    test "dev_login with a pre-staged grant lands :full — session, /chat, materialized membership",
         %{conn: conn} do
      slug = "extfull#{System.unique_integer([:positive])}"
      target_org = tenant_org!()
      space = channel!(target_org)

      {:ok, _grant} =
        ExternalGrants.create_grant(%{
          email: "#{slug}@localhost",
          oidc_sub: "dev-#{slug}",
          target_org_id: target_org.id,
          space_grants: [%{"space_id" => space.id, "role" => "member"}],
          dm_allowlist_org_ids: [target_org.id]
        })

      conn =
        %{conn | host: "chat.localhost"}
        |> init_test_session(%{})
        |> PlatformWeb.AuthController.dev_login(%{"as" => slug})

      assert redirected_to(conn, 302) == ~p"/chat"
      user_id = get_session(conn, :current_user_id)
      assert user_id
      # Full admission plants NO holding key.
      assert get_session(conn, :external_admission) == nil

      membership = Repo.get_by!(OrgMembership, user_id: user_id, org_id: target_org.id)
      assert membership.external == true
    end

    test "dev_login with no grant on the external surface lands :holding — session, holding key, /welcome, zero scoped rows",
         %{conn: conn} do
      slug = "exthold#{System.unique_integer([:positive])}"

      conn =
        %{conn | host: "chat.localhost"}
        |> init_test_session(%{})
        |> PlatformWeb.AuthController.dev_login(%{"as" => slug})

      # M3 stage 2 flipped `post_login_path(:holding)` from the `/chat`
      # placeholder to the dedicated holding landing `/welcome`.
      assert redirected_to(conn, 302) == ~p"/welcome"
      user_id = get_session(conn, :current_user_id)
      assert user_id

      assert %{state: :holding, user_id: ^user_id} =
               holding = get_session(conn, :external_admission)

      assert holding.reason in [:missing_claim, :awaiting_grant, :unknown]

      assert Repo.aggregate(
               from(p in Chat.Participant, where: p.participant_id == ^user_id),
               :count
             ) == 0

      assert Repo.aggregate(
               from(e in ExternalDmAllowlistEntry, where: e.user_id == ^user_id),
               :count
             ) == 0
    end

    test "ordinary internal dev_login is unchanged — :full, no holding key", %{conn: conn} do
      slug = "internal#{System.unique_integer([:positive])}"

      conn =
        conn
        |> init_test_session(%{})
        |> PlatformWeb.AuthController.dev_login(%{"as" => slug})

      assert redirected_to(conn, 302) == ~p"/chat"
      assert get_session(conn, :current_user_id)
      assert get_session(conn, :external_admission) == nil
    end
  end

  test "GET /auth/logout clears the session and redirects to the end-session endpoint", %{
    conn: conn
  } do
    conn =
      conn
      |> init_test_session(
        current_user_id: Ecto.UUID.generate(),
        oidc_id_token: "signed-id-token"
      )
      |> get(~p"/auth/logout")

    redirect_url = redirected_to(conn, 302)

    assert redirect_url =~ "https://issuer.example.com/end-session?"
    assert redirect_url =~ "id_token_hint=signed-id-token"
    assert redirect_url =~ "post_logout_redirect_uri=http%3A%2F%2Fwww.example.com"
  end

  defp mock_oidc_response(claim_sets) do
    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, Map.put(claim_sets, :token, %{"id_token" => "test-id-token"})}
    )
  end

  defp base_claims(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "test-subject",
        "email" => "user@example.com",
        "name" => "Test User"
      },
      overrides
    )
  end

  defp tenant_org!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    default = %{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    }

    %Org{} |> Org.changeset(Map.merge(default, attrs)) |> Repo.insert!()
  end

  defp channel!(org) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Chan #{n}", slug: "chan-#{n}", kind: "channel", org_id: org.id})

    space
  end

  defp insert_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(
      Map.merge(
        %{
          email: "user@example.com",
          name: "Test User",
          oidc_sub: "test-subject"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
