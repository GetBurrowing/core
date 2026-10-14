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
      assert body =~ "Contact your Burrow administrator."

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

  describe "chat-host pinning (task 019f9257)" do
    setup do
      prev = Application.get_env(:platform, :chat_host)
      Application.put_env(:platform, :chat_host, "chat.localhost")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :chat_host, prev),
          else: Application.delete_env(:platform, :chat_host)
      end)

      :ok
    end

    test "dev_login external :full is redirected to the ABSOLUTE chat-host /chat", %{conn: conn} do
      slug = "extpin#{System.unique_integer([:positive])}"
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

      # Absolute chat-host URL, not the host-relative ~p"/chat".
      assert redirected_to(conn, 302) == "https://chat.localhost/chat"
      assert get_session(conn, :current_user_id)
    end

    test "dev_login INTERNAL :full is unchanged — host-relative /chat even with CHAT_HOST set",
         %{conn: conn} do
      slug = "intpin#{System.unique_integer([:positive])}"

      conn =
        conn
        |> init_test_session(%{})
        |> PlatformWeb.AuthController.dev_login(%{"as" => slug})

      assert redirected_to(conn, 302) == ~p"/chat"
      assert get_session(conn, :current_user_id)
    end

    test "OIDC callback for an external :full user is redirected to the chat host", %{conn: conn} do
      target_org = tenant_org!()
      space = channel!(target_org)

      {:ok, _grant} =
        ExternalGrants.create_grant(%{
          email: "user@example.com",
          oidc_sub: "test-subject",
          target_org_id: target_org.id,
          space_grants: [%{"space_id" => space.id, "role" => "member"}],
          dm_allowlist_org_ids: [target_org.id]
        })

      mock_oidc_response(%{
        user: base_claims(),
        userinfo: base_claims(),
        id_token: base_claims()
      })

      conn =
        %{conn | host: "chat.localhost"}
        |> init_test_session(oidc_session_params: %{state: "expected-state", nonce: "n"})
        |> get(~p"/auth/oidc/callback?code=test-code&state=expected-state")

      assert redirected_to(conn, 302) == "https://chat.localhost/chat"
      assert get_session(conn, :current_user_id)
    end

    test "OIDC callback for an INTERNAL :full user is unchanged — host-relative /", %{conn: conn} do
      mock_oidc_response(%{
        user: base_claims(),
        userinfo: base_claims(),
        id_token: base_claims()
      })

      conn =
        conn
        |> init_test_session(oidc_session_params: %{state: "expected-state", nonce: "n"})
        |> get(~p"/auth/oidc/callback?code=test-code&state=expected-state")

      assert redirected_to(conn, 302) == ~p"/"
    end
  end

  # ── meet-host return after login (task 019ffec0) ───────────────────────
  #
  # EVERY assertion here compares `redirected_to/2` to an EXACT string. That a
  # 302 happened is not the property under test — WHICH HOST IT NAMES is the
  # defect, and a `=~` or a bare status assertion cannot see it.
  #
  # The negative cases are what stop this set being vacuous. An implementation
  # that skipped validation entirely — echoing whatever sits under the session
  # key — passes case 1 and the direction control on its own. Cases "no origin
  # key", "malformed binary", "unknown atom" and ":meet_host unset" are the
  # ones it fails.
  describe "meet-host return (task 019ffec0)" do
    setup do
      prev_chat = Application.get_env(:platform, :chat_host)
      prev_meet = Application.get_env(:platform, :meet_host)

      Application.put_env(:platform, :chat_host, "chat.localhost")
      Application.put_env(:platform, :meet_host, "meet.localhost")

      on_exit(fn ->
        restore_host(:chat_host, prev_chat)
        restore_host(:meet_host, prev_meet)
      end)

      :ok
    end

    defp restore_host(key, nil), do: Application.delete_env(:platform, key)
    defp restore_host(key, value), do: Application.put_env(:platform, key, value)

    # The OIDC claims resolve to user@example.com / test-subject, so a grant on
    # those makes the callback's admission return `external?: true, state:
    # :full` — the state whose landing this ticket changes.
    defp external_grant_for_claims! do
      target_org = tenant_org!()
      space = channel!(target_org)

      {:ok, _grant} =
        ExternalGrants.create_grant(%{
          email: "user@example.com",
          oidc_sub: "test-subject",
          target_org_id: target_org.id,
          space_grants: [%{"space_id" => space.id, "role" => "member"}],
          dm_allowlist_org_ids: [target_org.id]
        })

      :ok
    end

    # Drives the REAL `callback/2` through the router. `origin` is seeded into
    # the same signed session the `state` check reads, which is exactly where
    # `LoginOrigin.capture/1` puts it in `login/2`.
    defp callback_with_origin(conn, origin) do
      mock_oidc_response(%{
        user: base_claims(),
        userinfo: base_claims(),
        id_token: base_claims()
      })

      session =
        case origin do
          :none ->
            [oidc_session_params: %{state: "expected-state", nonce: "n"}]

          value ->
            [
              oidc_session_params: %{state: "expected-state", nonce: "n"},
              login_origin_surface: value
            ]
        end

      conn
      |> init_test_session(session)
      |> get(~p"/auth/oidc/callback?code=test-code&state=expected-state")
    end

    test "1. external :full with origin :meet lands on the ABSOLUTE meet host", %{conn: conn} do
      external_grant_for_claims!()

      conn = callback_with_origin(conn, :meet)

      assert redirected_to(conn, 302) == "https://meet.localhost/meetings"
      assert get_session(conn, :current_user_id)
    end

    test "2. NO origin key lands on the chat host — today's destination", %{conn: conn} do
      external_grant_for_claims!()

      conn = callback_with_origin(conn, :none)

      assert redirected_to(conn, 302) == "https://chat.localhost/chat"
    end

    test "3. a malformed BINARY origin is not echoed — chat host, no attacker string",
         %{conn: conn} do
      external_grant_for_claims!()

      conn = callback_with_origin(conn, "meet.attacker.example")

      assert redirected_to(conn, 302) == "https://chat.localhost/chat"

      refute redirected_to(conn, 302) =~ "attacker",
             "the supplied value must never reach the Location header; equality with " <>
               "the chat URL alone would still pass if the two happened to coincide"
    end

    test "4. an unknown atom origin lands on the chat host", %{conn: conn} do
      external_grant_for_claims!()

      conn = callback_with_origin(conn, :evil)

      assert redirected_to(conn, 302) == "https://chat.localhost/chat"
    end

    # DIRECTION CONTROL. This clause is the shared landing for every sign-in on
    # every surface, so the change must be invisible to internal users even
    # when the origin says :meet and both hosts are configured. Byte-identical
    # to the existing internal expectations.
    test "5. an INTERNAL :full user is unchanged — host-relative, origin ignored", %{conn: conn} do
      conn_callback = callback_with_origin(conn, :meet)

      assert redirected_to(conn_callback, 302) == ~p"/"

      slug = "meetint#{System.unique_integer([:positive])}"

      conn_dev =
        conn
        |> init_test_session(login_origin_surface: :meet)
        |> PlatformWeb.AuthController.dev_login(%{"as" => slug})

      assert redirected_to(conn_dev, 302) == ~p"/chat"
    end

    test "6. origin :meet with :meet_host UNSET falls back — never https:///", %{conn: conn} do
      Application.delete_env(:platform, :meet_host)
      external_grant_for_claims!()

      conn = callback_with_origin(conn, :meet)

      assert redirected_to(conn, 302) == "https://chat.localhost/chat"
      refute redirected_to(conn, 302) =~ "https:///"
    end

    test "7. login/2 stores the origin when the request arrives on the meet host",
         %{conn: conn} do
      conn = %{conn | host: "meet.localhost"} |> get(~p"/auth/login")

      assert get_session(conn, :login_origin_surface) == :meet
      assert redirected_to(conn, 302) =~ "https://issuer.example.com/authorize?"
    end

    test "8. a completed callback CLEARS the origin key", %{conn: conn} do
      external_grant_for_claims!()

      conn = callback_with_origin(conn, :meet)

      assert redirected_to(conn, 302) == "https://meet.localhost/meetings"

      assert get_session(conn, :login_origin_surface) == nil,
             "a completed login must not leave a key that steers the next one"
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
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
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
