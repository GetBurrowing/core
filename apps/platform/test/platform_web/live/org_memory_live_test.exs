defmodule PlatformWeb.OrgMemoryLiveTest do
  @moduledoc """
  T7 stage 2 (task 019e41da-3610-7972-8573-54121ea1f3f5) — verifies:

    * `GET /org_memory` mounts `PlatformWeb.OrgMemoryLive`.
    * `GET /org-context` returns a 301 redirect to `/org_memory`.
    * `GET /org-context/:file_key` returns a 301 redirect to
      `/org_memory/:file_key`, preserving the deep-link segment.

  This file is the home for all subsequent T7 LiveView tests (page
  viewer, editor, three-pane layout). For now it locks in the rename +
  redirect contract.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "org-memory-#{n}@example.com",
          name: "Org Memory Test #{n}",
          oidc_sub: "oidc-org-memory-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  describe "GET /org_memory" do
    test "renders 200 and mounts OrgMemoryLive", %{conn: conn} do
      user = create_user!()

      {:ok, view, html} = conn |> authenticated_conn(user) |> live(~p"/org_memory")

      # The LV mounted — confirm it's the OrgMemoryLive module and the
      # page chrome rendered.
      assert view.module == PlatformWeb.OrgMemoryLive
      # The renamed user-visible heading appears in the empty-file panel
      # (no file selected on first mount).
      assert html =~ "Org Memory"
    end
  end

  describe "GET /org-context (legacy path) 301 redirects" do
    test "/org-context responds 301 with location: /org_memory", %{conn: conn} do
      conn = get(conn, "/org-context")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/org_memory"]
    end

    test "/org-context/:file_key responds 301 with the file_key preserved", %{conn: conn} do
      conn = get(conn, "/org-context/ORG_IDENTITY.md")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/org_memory/ORG_IDENTITY.md"]
    end
  end
end
