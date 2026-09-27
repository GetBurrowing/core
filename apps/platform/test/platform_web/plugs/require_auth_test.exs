defmodule PlatformWeb.Plugs.RequireAuthTest do
  @moduledoc """
  Tests for the `RequireAuth` plug, focused on the MT/RBAC stack 2
  additions (`:current_user_org_membership` + `:fabrikam_admin?` assigns).

  Hot-path concern: the assigns must derive from the already-preloaded
  user struct — NOT from a follow-up Repo query — so any future
  refactor that drops the `Accounts.get_user/1` preload won't silently
  re-introduce an N+1 here.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Plugs.RequireAuth

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "require-auth-test-#{n}@example.com",
          name: "RequireAuth Test #{n}",
          oidc_sub: "oidc-require-auth-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp call(conn, user_id) do
    conn
    |> Plug.Test.init_test_session(%{"current_user_id" => user_id})
    |> RequireAuth.call(RequireAuth.init([]))
  end

  defp call_without_session(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> RequireAuth.call(RequireAuth.init([]))
  end

  describe "MT/RBAC assigns" do
    test "admin user → membership + fabrikam_admin?=true", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "admin")

      conn = call(conn, user.id)

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.fabrikam_admin? == true

      assert %{role: :admin, org: %{slug: "fabrikam"}} =
               conn.assigns.current_user_org_membership
    end

    test "member user → membership + fabrikam_admin?=false", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      conn = call(conn, user.id)

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.fabrikam_admin? == false

      assert %{role: :member, org: %{slug: "fabrikam"}} =
               conn.assigns.current_user_org_membership
    end

    test "user with no memberships → nil membership + fabrikam_admin?=false", %{conn: conn} do
      user = create_user!()

      conn = call(conn, user.id)

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.fabrikam_admin? == false
      assert is_nil(conn.assigns.current_user_org_membership)
    end

    test "anonymous (no session) → no assigns, redirect to login", %{conn: conn} do
      conn = conn |> Plug.Test.init_test_session(%{}) |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :current_user_org_membership)
      refute Map.has_key?(conn.assigns, :fabrikam_admin?)
    end

    test "stale session (user deleted) → drop session, redirect to login", %{conn: conn} do
      bogus_id = Ecto.UUID.generate()

      conn = call(conn, bogus_id)

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
    end
  end

  describe "archived user (Stage 5)" do
    test "session for an archived user → drop session + redirect to login", %{conn: conn} do
      user = create_user!()
      {:ok, _archived} = Accounts.archive_user(user)

      conn = call(conn, user.id)

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
      # `configure_session(drop: true)` marks the session for teardown on
      # response — `plug_session_info: :drop` in `conn.private` is the
      # signal the underlying `Plug.Session` looks at when it emits the
      # Set-Cookie. In-memory `get_session` still returns the old value
      # inside this request; verify the drop marker instead.
      assert conn.private.plug_session_info == :drop
      # never assigned the current_user (the guard fires before assign)
      refute Map.has_key?(conn.assigns, :current_user)
    end
  end

  describe "no-follow-up-query guarantee" do
    # If `Accounts.get_user/1` is ever refactored to drop the
    # `:org_memberships` preload, the assigns will silently degrade to
    # `nil` / `false`. This test pins the contract: the preloaded shape
    # must arrive on `:current_user` AND drive the derived assigns.
    test "current_user has :org_memberships preloaded (not %NotLoaded{})", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "admin")

      conn = call(conn, user.id)

      memberships = conn.assigns.current_user.org_memberships
      assert is_list(memberships)
      assert length(memberships) == 1

      [m] = memberships
      assert m.role == "admin"
      assert %Platform.Tenancy.Org{} = m.org
    end
  end

  describe "denial shape for API vs browser callers (01a09415 stage 2; nested envelope 01a0ac9c)" do
    test "no session + accept: application/json → 401 JSON, no location header", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> call_without_session()

      assert conn.status == 401
      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "location") == []

      body = Jason.decode!(conn.resp_body)
      assert is_map(body["error"])
      assert body["error"]["code"] == "unauthorized"
      assert is_binary(body["error"]["message"]) and body["error"]["message"] != ""
      assert body["error"]["reason"] == "no_session"
      refute Map.has_key?(body, "reason")
    end

    test "no session + authorization: Bearer → 401", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer nope")
        |> call_without_session()

      assert conn.status == 401
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert is_map(body["error"])
      assert body["error"]["code"] == "unauthorized"
      assert is_binary(body["error"]["message"]) and body["error"]["message"] != ""
      assert body["error"]["reason"] == "no_session"
      refute Map.has_key?(body, "reason")
    end

    # POSITIVE CONTROL. Without this, a plug that stopped running at all
    # would still satisfy the three 401 assertions above — nothing there
    # distinguishes "denied with 401" from "never reached". This pins that
    # the plug IS reachable and that the browser path is untouched.
    test "no session + no extra headers → still 302 to /auth/login", %{conn: conn} do
      conn = call_without_session(conn)

      assert conn.status == 302
      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "location") == ["/auth/login"]
    end

    test "stale current_user_id + accept: json → 401 and the session is dropped", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Test.init_test_session(%{"current_user_id" => Ecto.UUID.generate()})
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.status == 401
      assert conn.halted
      assert conn.private[:plug_session_info] == :drop

      body = Jason.decode!(conn.resp_body)
      assert is_map(body["error"])
      assert body["error"]["code"] == "unauthorized"
      assert is_binary(body["error"]["message"]) and body["error"]["message"] != ""
      assert body["error"]["reason"] == "stale_session"
      refute Map.has_key?(body, "reason")
    end

    test "archived user + accept: json → 401 nested envelope, reason user_archived, session dropped",
         %{conn: conn} do
      user = create_user!()
      {:ok, _archived} = Accounts.archive_user(user)

      conn =
        conn
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> call(user.id)

      assert conn.status == 401
      assert conn.halted
      assert conn.private[:plug_session_info] == :drop
      refute Map.has_key?(conn.assigns, :current_user)

      body = Jason.decode!(conn.resp_body)
      assert is_map(body["error"])
      assert body["error"]["code"] == "unauthorized"
      assert body["error"]["message"] == "Account is archived."
      assert body["error"]["reason"] == "user_archived"
      refute Map.has_key?(body, "reason")
    end
  end
end
