defmodule PlatformWeb.Plugs.AttachmentAuthTest do
  @moduledoc """
  Tests for the dual-auth attachment plug (ADR 0039 phase 3), focused on
  the Stage 5 archived-user guard on the session-cookie branch.

  Runtime bearer path is intentionally NOT touched by the archival rule
  — bearer tokens authenticate agent runtimes, not users — so this file
  keeps to the session-cookie surface.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias PlatformWeb.Plugs.AttachmentAuth

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "attach-auth-#{n}@example.com",
          name: "AttachAuth Test #{n}",
          oidc_sub: "oidc-attach-auth-#{n}"
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
    |> AttachmentAuth.call(AttachmentAuth.init([]))
  end

  describe "archived user (Stage 5)" do
    test "session for an archived user → drop session + redirect to /auth/login", %{conn: conn} do
      user = create_user!()
      {:ok, _archived} = Accounts.archive_user(user)

      conn = call(conn, user.id)

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
      assert conn.private.plug_session_info == :drop
      refute Map.has_key?(conn.assigns, :principal)
      refute Map.has_key?(conn.assigns, :current_user)
    end
  end

  describe "regression coverage" do
    test "active user → :principal + :current_user assigns, not halted", %{conn: conn} do
      user = create_user!()

      conn = call(conn, user.id)

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.principal == {:user, user.id}
    end

    test "no session → redirect to /auth/login, no principal", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> AttachmentAuth.call(AttachmentAuth.init([]))

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
      refute Map.has_key?(conn.assigns, :principal)
    end
  end
end
