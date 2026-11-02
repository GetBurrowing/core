defmodule PlatformWeb.PageControllerTest do
  use PlatformWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  test "GET / redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET / redirects authenticated users to /chat", %{conn: conn} do
    # A member who predates the first-run box (task 01a19554-fd07 stage 3).
    user =
      Repo.insert!(%User{
        email: "user@example.com",
        name: "Test User",
        oidc_sub: "oidc-subject",
        preferences: %{"first_run_goal" => "existing"}
      })

    conn = init_test_session(conn, current_user_id: user.id)
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/chat"
  end

  defp member!(prefs) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "first-run-root-#{n}@example.com",
        name: "First Run Root #{n}",
        oidc_sub: "oidc-first-run-root-#{n}",
        preferences: prefs
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  describe "first-run landing (task 01a19554-fd07 stage 3)" do
    test "GET / sends a first-run member to /start", %{conn: conn} do
      user = member!(%{})

      conn = conn |> init_test_session(current_user_id: user.id) |> get(~p"/")

      assert redirected_to(conn) == "/start"
    end

    test "GET / sends a member who skipped to /chat", %{conn: conn} do
      user = member!(%{"first_run_goal" => "skipped", "theme" => %{"preset" => "default"}})

      conn = conn |> init_test_session(current_user_id: user.id) |> get(~p"/")

      assert redirected_to(conn) == "/chat"
    end

    test "GET / sends a member who submitted to /chat", %{conn: conn} do
      user = member!(%{"first_run_goal" => "submitted"})

      conn = conn |> init_test_session(current_user_id: user.id) |> get(~p"/")

      assert redirected_to(conn) == "/chat"
    end

    test "GET / sends an external user where it did before", %{conn: conn} do
      # Before this stage home/2 was an unconditional redirect to /chat. An
      # external user has no first_run_goal key and is still not pending.
      org = Platform.Tenancy.get_org_by_slug!("globex")
      ext = Platform.ExternalUserFixtures.external_user!(org)
      refute Map.has_key?(Platform.Accounts.get_user_preferences(ext.id), "first_run_goal")

      conn = conn |> init_test_session(current_user_id: ext.id) |> get(~p"/")

      assert redirected_to(conn) == "/chat"
    end
  end

  test "GET /chat renders the chat surface for authenticated users", %{conn: conn} do
    # Not a first-run member: a pending one is sent to /start by
    # `PlatformWeb.Plugs.FirstRunGate` (task 01a19943-c0b4 stage 1).
    user =
      Repo.insert!(%User{
        email: "user@example.com",
        name: "Test User",
        oidc_sub: "oidc-subject",
        preferences: %{"first_run_goal" => "existing"}
      })

    conn = init_test_session(conn, current_user_id: user.id)

    {:ok, view, html} = live(conn, ~p"/chat")

    # Shell layout and the Chat list should be present (Burrow redesign 22
    # stage 2 deleted the desktop channel rail; the Chat list replaces it).
    # The shell brand is the install's app name, "Burrow" on a migrated DB
    # (task 01a120c5 stage 3).
    assert html =~ "Burrow"
    assert has_element?(view, ~s(section#chat-list[aria-label="Chat"]))
  end
end
