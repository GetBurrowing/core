defmodule PlatformWeb.ThemeBootRenderTest do
  @moduledoc """
  The root layout's theme boot (task 01a1557a stage 3), renamed in place from
  `theme_toggle_test.exs` (task 019d3fd3).

  A signed-in request renders the stored preference on `<html>` so a device
  with an empty cache paints the chosen preset in its first frame; the
  `data-role="theme-boot"` script then resolves server value, then the
  `burrow-theme-v1` cache, then the default. The script's behaviour is
  covered by `assets/test/theme_boot_test.mjs`; this file pins what the
  server renders. These cases use a dead `get/2`, not `live/2`, because only
  the dead render carries the root layout.
  """

  use PlatformWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Accounts
  alias Platform.Accounts.ThemePreference
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp insert_user do
    Repo.insert!(%User{
      email: "theme_test_#{System.unique_integer([:positive])}@example.com",
      name: "Theme Test User",
      oidc_sub: "oidc-theme-test-#{System.unique_integer([:positive])}"
    })
  end

  defp authenticated_conn(conn, user) do
    init_test_session(conn, current_user_id: user.id)
  end

  defp space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Theme Boot Space",
        slug: "theme-boot-#{System.unique_integer([:positive])}"
      })

    space
  end

  defp user_with_theme!(pref) do
    user = insert_user()
    {:ok, user} = Accounts.put_theme_preference(user, pref)
    user
  end

  # The dead render of a LiveView route: the only response that carries the
  # root layout.
  defp page_for(conn, user) do
    conn
    |> authenticated_conn(user)
    |> get(~p"/chat/#{space!().slug}")
    |> html_response(200)
  end

  defp html_tag(html) do
    [tag] = Regex.run(~r/<html\b[^>]*>/, html, capture: :first)
    tag
  end

  defp boot_tag(html) do
    [tag] = Regex.run(~r/<script\b[^>]*data-role="theme-boot"[^>]*>/, html, capture: :first)
    tag
  end

  describe "server render of the stored theme on <html>" do
    test "a sand + light user renders data-theme=light and data-preset=burrow-sand",
         %{conn: conn} do
      user = user_with_theme!(%{"preset" => "burrow-sand", "mode" => "light"})
      tag = conn |> page_for(user) |> html_tag()

      assert tag =~ ~s(data-theme="light")
      assert tag =~ ~s(data-preset="burrow-sand")
    end

    test "a High contrast + dark user renders both attributes", %{conn: conn} do
      user = user_with_theme!(%{"preset" => "high-contrast", "mode" => "dark"})
      tag = conn |> page_for(user) |> html_tag()

      assert tag =~ ~s(data-theme="dark")
      assert tag =~ ~s(data-preset="high-contrast")
    end

    test "a Burrow user renders no data-preset", %{conn: conn} do
      user = user_with_theme!(%{"preset" => "burrow", "mode" => "light"})
      tag = conn |> page_for(user) |> html_tag()

      assert tag =~ ~s(data-theme="light")
      refute tag =~ "data-preset"
    end

    test "a user with no stored theme renders the default: dark, no data-preset",
         %{conn: conn} do
      tag = conn |> page_for(insert_user()) |> html_tag()

      assert ThemePreference.default() == %{"preset" => "burrow", "mode" => "dark"}
      assert tag =~ ~s(data-theme="dark")
      refute tag =~ "data-preset"
    end

    test "a system user renders no data-theme, and the script still gets the stored pair",
         %{conn: conn} do
      user = user_with_theme!(%{"preset" => "burrow-forest", "mode" => "system"})
      html = page_for(conn, user)

      refute html_tag(html) =~ "data-theme"
      assert html_tag(html) =~ ~s(data-preset="burrow-forest")

      boot = boot_tag(html)
      assert boot =~ ~s(data-server-preset="burrow-forest")
      assert boot =~ ~s(data-server-mode="system")
    end

    test "a Burrow + system user renders neither attribute but still hands the script the stored pair",
         %{conn: conn} do
      user = user_with_theme!(%{"preset" => "burrow", "mode" => "system"})
      html = page_for(conn, user)

      refute html_tag(html) =~ "data-theme"
      refute html_tag(html) =~ "data-preset"

      boot = boot_tag(html)
      assert boot =~ ~s(data-server-preset="burrow")
      assert boot =~ ~s(data-server-mode="system")
    end

    test "a signed-out render carries neither attribute and no server preference" do
      html =
        rendered_to_string(
          PlatformWeb.Layouts.root(%{inner_content: "signed out", page_title: nil})
        )

      refute html_tag(html) =~ "data-theme"
      refute html_tag(html) =~ "data-preset"

      boot = boot_tag(html)
      refute boot =~ "data-server-preset"
      refute boot =~ "data-server-mode"
    end
  end

  describe "the theme-boot script" do
    test "sits after the app.css link and before </head>", %{conn: conn} do
      html = page_for(conn, insert_user())
      [head] = Regex.run(~r/<head>.*<\/head>/s, html, capture: :first)

      {css_at, _} = :binary.match(head, "/assets/css/app.css")
      {boot_at, _} = :binary.match(head, ~s(data-role="theme-boot"))

      assert css_at < boot_at
      assert length(Regex.scan(~r/data-role="theme-boot"/, html)) == 1
    end

    test "carries the registry as data attributes, rendered from ThemePreference",
         %{conn: conn} do
      boot = conn |> page_for(insert_user()) |> boot_tag()

      assert boot =~ ~s(data-presets="#{Enum.join(ThemePreference.preset_ids(), " ")}")
      assert boot =~ ~s(data-modes="#{Enum.join(ThemePreference.modes(), " ")}")
      assert boot =~ ~s(data-base-preset="#{ThemePreference.base_preset()}")
      assert boot =~ ~s(data-default-preset="#{ThemePreference.default()["preset"]}")
      assert boot =~ ~s(data-default-mode="#{ThemePreference.default()["mode"]}")
    end

    test "the theme debug panel and the old theme API are gone", %{conn: conn} do
      html = page_for(conn, insert_user())

      refute html =~ "theme-debug-panel"
      refute html =~ "phx:" <> "theme"
      refute html =~ "setApp" <> "Theme"
      refute html =~ "phx:" <> "set-theme"
      assert html =~ "burrow-theme-v1"
      assert html =~ "window.burrowTheme"
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
end
