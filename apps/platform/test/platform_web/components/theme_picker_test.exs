defmodule PlatformWeb.Components.ThemePickerTest do
  @moduledoc """
  The utility bar's theme picker (task 01a1557a stage 4), rendered on a real
  ShellLive route, plus the `set_theme` / open / close events ShellLive's
  `:drawer_events` hook handles. The hook's browser behaviour (apply then
  push, keyboard, the check, the chips' mode) is in
  `assets/test/hooks/theme_picker.test.js`.
  """

  use PlatformWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.ThemePreference
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @bodies ["#theme-picker-popover-body", "#theme-picker-sheet-body"]

  defp insert_user do
    Repo.insert!(%User{
      email: "theme_picker_#{System.unique_integer([:positive])}@example.com",
      name: "Theme Picker User",
      oidc_sub: "oidc-theme-picker-#{System.unique_integer([:positive])}"
    })
  end

  defp open_chat(conn, user) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Theme Picker Space",
        slug: "theme-picker-#{System.unique_integer([:positive])}"
      })

    conn
    |> init_test_session(current_user_id: user.id)
    |> live(~p"/chat/#{space.slug}")
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp q(doc, selector), do: LazyHTML.query(doc, selector)

  setup %{conn: conn} do
    user = insert_user()
    {:ok, view, html} = open_chat(conn, user)
    %{user: user, view: view, html: html}
  end

  describe "markup (inventory I1-I10)" do
    test "I1: one trigger, in the utility bar where the toggle sat", %{html: html} do
      doc = doc(html)

      assert doc |> q("#utility-bar #theme-picker-trigger") |> Enum.count() == 1
      assert doc |> q("#theme-toggle") |> Enum.count() == 0
      assert doc |> q(~s([phx-hook="ThemeToggle"])) |> Enum.count() == 0
    end

    test "I2/I3: Mode then Theme, three modes and five presets in registry order",
         %{html: html} do
      doc = doc(html)

      for body <- @bodies do
        groups = q(doc, "#{body} [role=radiogroup]")
        assert LazyHTML.attribute(groups, "data-theme-group") == ["mode", "preset"]

        labels = doc |> q("#{body} p") |> Enum.map(&LazyHTML.text/1) |> Enum.map(&String.trim/1)
        assert labels == ["Mode", "Theme"]

        modes = q(doc, ~s(#{body} [data-theme-option="mode"]))
        assert LazyHTML.attribute(modes, "data-value") == ThemePreference.modes()

        assert modes |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) ==
                 ["Light", "Dark", "System"]

        rows = q(doc, ~s(#{body} [data-theme-option="preset"]))
        assert LazyHTML.attribute(rows, "data-value") == ThemePreference.preset_ids()

        names = Enum.map(ThemePreference.presets(), & &1.name)

        assert doc
               |> q(~s(#{body} [data-theme-option="preset"] > span.flex-1))
               |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == names

        assert rows |> LazyHTML.attribute("role") |> Enum.uniq() == ["radio"]
      end
    end

    test "I4: every chip carries its own data-preset and a data-theme", %{html: html} do
      doc = doc(html)

      for body <- @bodies do
        chips = q(doc, "#{body} [data-theme-chip]")
        assert LazyHTML.attribute(chips, "data-preset") == ThemePreference.preset_ids()
        # Default user: dark, painted by the server for the first frame.
        assert LazyHTML.attribute(chips, "data-theme") |> Enum.uniq() == ["dark"]
      end
    end

    test "I5/I10: no Save button and no Settings link", %{html: html} do
      doc = doc(html)

      for scope <- ["#theme-picker", "#theme-picker-sheet"] do
        text = doc |> q(scope) |> LazyHTML.text()
        refute text =~ ~r/save/i
        refute text =~ ~r/settings/i
        assert doc |> q("#{scope} a") |> Enum.count() == 0
        assert doc |> q("#{scope} [type=submit]") |> Enum.count() == 0
      end
    end

    test "I6: the active row is checked, with a visible check icon; the others are not",
         %{conn: conn} do
      user = insert_user()

      {:ok, _} =
        Accounts.put_theme_preference(user, %{"preset" => "burrow-sand", "mode" => "light"})

      {:ok, _view, html} = open_chat(conn, user)
      doc = doc(html)

      for body <- @bodies do
        checked = q(doc, ~s(#{body} [role=radio][aria-checked="true"]))
        assert LazyHTML.attribute(checked, "data-value") == ["light", "burrow-sand"]

        visible_checks = q(doc, "#{body} [data-theme-check]:not(.invisible)")
        assert Enum.count(visible_checks) == 1
        assert visible_checks |> LazyHTML.attribute("class") |> hd() =~ "hero-check"

        sand_row = q(doc, ~s(#{body} [data-value="burrow-sand"]))
        assert sand_row |> q("[data-theme-check]:not(.invisible)") |> Enum.count() == 1

        # The chips paint in the stored mode.
        assert doc
               |> q("#{body} [data-theme-chip]")
               |> LazyHTML.attribute("data-theme")
               |> Enum.uniq() == ["light"]
      end
    end

    test "I7: roving tabindex, one tab stop per group", %{html: html} do
      doc = doc(html)

      for body <- @bodies, group <- ["mode", "preset"] do
        tabindex =
          doc
          |> q(~s(#{body} [data-theme-option="#{group}"]))
          |> LazyHTML.attribute("tabindex")

        assert Enum.count(tabindex, &(&1 == "0")) == 1
      end
    end

    test "I8: popover at lg, sheet below lg, the sheet hidden at lg", %{html: html} do
      doc = doc(html)

      [sheet_class] = doc |> q("#theme-picker-sheet") |> LazyHTML.attribute("class")
      assert "lg:hidden" in String.split(sheet_class)

      [popover_class] = doc |> q("#theme-picker-popover") |> LazyHTML.attribute("class")
      # Closed: hidden at every width.
      assert "hidden" in String.split(popover_class)
      refute "lg:block" in String.split(popover_class)
    end

    test "the picker bodies are hook-owned and patch-proof", %{html: html} do
      doc = doc(html)

      for body <- @bodies do
        el = q(doc, body)
        assert LazyHTML.attribute(el, "phx-hook") == ["ThemePicker"]
        assert LazyHTML.attribute(el, "phx-update") == ["ignore"]
      end
    end

    test "the Burrow chip restates exactly the :root --font-sans stack" do
      css = File.read!(Path.join(File.cwd!(), "assets/css/app.css"))

      [root_stack] =
        Regex.run(~r/\n:root \{[^}]*?--font-sans: ([^;]+);/s, css, capture: :all_but_first)

      [chip_stack] =
        Regex.run(~r/\.theme-chip\[data-preset="burrow"\] \{\s*--font-sans: ([^;]+);/, css,
          capture: :all_but_first
        )

      assert chip_stack == root_stack
      assert css =~ ~r/\.theme-chip \{\s*font-family: var\(--font-sans\);/
    end
  end

  describe "open and close" do
    test "toggle opens the popover (lg) and the sheet; close shuts both", %{view: view} do
      html = view |> element("#theme-picker-trigger") |> render_click()
      doc = doc(html)

      [popover_class] = doc |> q("#theme-picker-popover") |> LazyHTML.attribute("class")
      assert "lg:block" in String.split(popover_class)
      assert doc |> q("#theme-picker-sheet") |> LazyHTML.attribute("data-open") == ["true"]
      assert doc |> q("#theme-picker-trigger") |> LazyHTML.attribute("aria-expanded") == ["true"]

      html = render_hook(view, "close_theme_picker", %{})
      doc = doc(html)

      [popover_class] = doc |> q("#theme-picker-popover") |> LazyHTML.attribute("class")
      refute "lg:block" in String.split(popover_class)
      assert doc |> q("#theme-picker-sheet") |> LazyHTML.attribute("data-open") == ["false"]
    end
  end

  describe "set_theme" do
    test "persists a registered preset and mode", %{view: view, user: user} do
      render_hook(view, "set_theme", %{"preset" => "burrow-sand", "mode" => "light"})

      assert Accounts.theme_preference(user.id) == %{
               "preset" => "burrow-sand",
               "mode" => "light"
             }

      render_hook(view, "set_theme", %{"preset" => "high-contrast", "mode" => "system"})

      assert Accounts.theme_preference(user.id) == %{
               "preset" => "high-contrast",
               "mode" => "system"
             }
    end

    test "an unregistered preset writes nothing", %{view: view, user: user} do
      render_hook(view, "set_theme", %{"preset" => "burrow-sand", "mode" => "light"})
      render_hook(view, "set_theme", %{"preset" => "not-a-preset", "mode" => "dark"})

      assert Accounts.theme_preference(user.id) == %{
               "preset" => "burrow-sand",
               "mode" => "light"
             }

      raw = Repo.get!(User, user.id).preferences["theme"]
      assert raw == %{"preset" => "burrow-sand", "mode" => "light"}
    end

    test "an unregistered mode writes nothing", %{view: view, user: user} do
      render_hook(view, "set_theme", %{"preset" => "burrow-forest", "mode" => "sepia"})

      assert Repo.get!(User, user.id).preferences["theme"] == nil
      assert Accounts.theme_preference(user.id) == ThemePreference.default()
    end

    test "a malformed preset is a no-op and keeps the view alive", %{view: view, user: user} do
      render_hook(view, "set_theme", %{"preset" => ["burrow-sand"]})
      assert Repo.get!(User, user.id).preferences["theme"] == nil
      assert render(view) =~ "theme-picker-trigger"
    end

    test "an anonymous shell (no user record) writes nothing and keeps its socket" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user_record: nil}}
      before = Repo.aggregate(User, :count)

      assert PlatformWeb.ShellLive.put_theme(socket, %{
               "preset" => "burrow-sand",
               "mode" => "light"
             }) == socket

      assert PlatformWeb.ShellLive.put_theme(socket, :not_a_map) == socket
      assert Repo.aggregate(User, :count) == before
    end

    test "a successful write refreshes the socket's user record", %{user: user} do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user_record: user}}

      socket =
        PlatformWeb.ShellLive.put_theme(socket, %{"preset" => "burrow-forest", "mode" => "dark"})

      assert Accounts.theme_preference(socket.assigns.current_user_record) == %{
               "preset" => "burrow-forest",
               "mode" => "dark"
             }
    end
  end
end
