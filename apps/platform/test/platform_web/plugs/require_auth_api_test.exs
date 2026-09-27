defmodule PlatformWeb.Plugs.RequireAuthAPITest do
  @moduledoc """
  Tests for the JSON-API counterpart to `RequireAuth`. Focus is on the
  Stage 5 archived-user guard: a session cookie whose user was archived
  mid-flight must return `401 { error: { code: "unauthorized", message:
  "Account is archived." } }` and drop the session, not crash and not
  assign `:current_user`.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias PlatformWeb.Plugs.RequireAuthAPI

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "require-auth-api-#{n}@example.com",
          name: "RequireAuthAPI Test #{n}",
          oidc_sub: "oidc-require-auth-api-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp call(conn, user_id) do
    conn
    |> Plug.Test.init_test_session(%{"current_user_id" => user_id})
    |> RequireAuthAPI.call(RequireAuthAPI.init([]))
  end

  describe "archived user (Stage 5)" do
    test "session for an archived user → 401 JSON + drop session", %{conn: conn} do
      user = create_user!()
      {:ok, _archived} = Accounts.archive_user(user)

      conn = call(conn, user.id)

      assert conn.halted
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)

      assert body == %{
               "error" => %{"code" => "unauthorized", "message" => "Account is archived."}
             }

      assert conn.private.plug_session_info == :drop
      refute Map.has_key?(conn.assigns, :current_user)
    end
  end

  describe "regression coverage" do
    test "active user → :current_user assign, not halted", %{conn: conn} do
      user = create_user!()

      conn = call(conn, user.id)

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "stale session (nonexistent user) → 401 JSON + drop session", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      conn = call(conn, bogus)

      assert conn.halted
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unauthorized"
    end

    test "no session → 401 JSON, no assign", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> RequireAuthAPI.call(RequireAuthAPI.init([]))

      assert conn.halted
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unauthorized"
      assert body["error"]["message"] == "Authentication required."
    end
  end
end
