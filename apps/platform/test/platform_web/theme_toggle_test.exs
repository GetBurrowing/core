defmodule PlatformWeb.ThemeToggleTest do
  @moduledoc """
  Regression tests for the dark/light theme toggle.

  Task: 019d3fd3 — Theme toggle bug: button action fires but light/dark theme does not apply.

  Root causes fixed in PR #123:
  1. daisyUI was configured with `themes: false` — no CSS generated for `data-theme` switching.
  2. Default theme was "system" which removed `data-theme` entirely, leaving daisyUI with no theme.
  3. ThemeToggle hook used unreliable CustomEvent dispatch path.
  """

  use PlatformWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "theme_test_#{System.unique_integer([:positive])}@example.com",
        name: "Theme Test User",
        oidc_sub: "oidc-theme-test-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  describe "ThemeToggle hook" do
    test "shell renders theme-toggle button with phx-hook=\"ThemeToggle\"", %{conn: conn} do
      {:ok, space} =
        Chat.create_space(%{
          name: "Theme Test Space",
          slug: "theme-test-#{System.unique_integer([:positive])}"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # ThemeToggle hook must be wired on the button element
      assert html =~ ~s(phx-hook="ThemeToggle")
    end

    test "shell renders sun and moon icon spans for ThemeToggle", %{conn: conn} do
      {:ok, space} =
        Chat.create_space(%{
          name: "Theme Icons Space",
          slug: "theme-icons-#{System.unique_integer([:positive])}"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # Icon spans that ThemeToggle.updateIcon() manages
      assert html =~ ~s(data-icon="sun")
      assert html =~ ~s(data-icon="moon")
    end

    test "sun icon starts hidden (dark default, moon should be visible)", %{conn: conn} do
      {:ok, space} =
        Chat.create_space(%{
          name: "Theme Default Space",
          slug: "theme-default-#{System.unique_integer([:positive])}"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # In dark mode (default), sun icon is hidden and moon is visible
      # The sun span should include the "hidden" class
      assert html =~ ~r/data-icon="sun"[^>]*class="[^"]*hidden/
    end
  end

  describe "CSS theme configuration" do
    test "app.css includes both light and dark themes for daisyUI" do
      css_path =
        Application.app_dir(:platform, "priv/static/assets")
        |> Path.join("app.css")

      # If the compiled CSS exists, check it contains theme selectors
      if File.exists?(css_path) do
        css = File.read!(css_path)
        # Both themes should generate CSS selectors via data-theme attribute
        assert css =~ "[data-theme=dark]" or css =~ "[data-theme=\"dark\"]",
               "daisyUI dark theme CSS selectors missing — themes: false may have been set"

        assert css =~ "[data-theme=light]" or css =~ "[data-theme=\"light\"]",
               "daisyUI light theme CSS selectors missing — themes: false may have been set"
      else
        # In test environment, compiled CSS may not exist — check source config instead
        source_css =
          Path.join([
            File.cwd!(),
            "apps/platform/assets/css/app.css"
          ])

        if File.exists?(source_css) do
          source = File.read!(source_css)

          refute source =~ ~s(themes: false),
                 "daisyUI themes: false disables theme CSS generation — must be [\"light\", \"dark\"]"

          assert source =~ ~s(themes: ["light", "dark"]) or
                   source =~ ~s(themes: ['light', 'dark']),
                 "daisyUI must be configured with themes: [\"light\", \"dark\"] for toggle to work"
        end
      end
    end
  end

  describe "root layout theme initialization" do
    test "root layout defaults to dark theme when no localStorage preference", %{conn: conn} do
      conn = authenticated_conn(conn)

      # Navigate to home page to get the root layout
      {:ok, _view, html} = live(conn, ~p"/chat")

      # The root layout inline script should default to dark
      # This prevents the original bug where default "system" removed data-theme entirely
      assert html =~ ~s(|| "dark"), "Root layout must default to dark, not system"

      refute html =~ ~s(|| "system"),
             "Default of 'system' removes data-theme, breaking daisyUI — must be 'dark'"
    end

    test "root layout includes phx:set-theme event listener", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ "phx:set-theme",
             "phx:set-theme listener must be present in root layout for Layouts.theme_toggle component"
    end
  end
end
