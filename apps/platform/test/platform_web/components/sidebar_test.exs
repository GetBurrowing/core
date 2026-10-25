defmodule PlatformWeb.Components.SidebarTest do
  @moduledoc """
  The desktop sidebar (Burrow redesign 22 stage 1; master-desktop.html
  `#side`). Component renders pin the row list, its order and its states;
  the shell renders (below) pin what left the desktop with it: the icon
  rail, its collapse control, the utility bar and the account menu, and the
  phone top strip that kept the utility bar's phone children.

  `async: false`: the extension cases swap `:platform, :extensions`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.{IconRail, Sidebar}

  defp render_sidebar(assigns) do
    assigns =
      Map.merge(
        %{
          current_path: "/chat",
          root_user: false,
          access_scope: nil,
          inbox_unread_count: 0,
          chat_unread_count: 0,
          meeting_active: false,
          user: nil,
          current_user: "Pat Example",
          org_name: nil,
          masked?: false
        },
        assigns
      )

    rendered_to_string(~H"""
    <Sidebar.sidebar
      current_path={@current_path}
      root_user={@root_user}
      access_scope={@access_scope}
      inbox_unread_count={@inbox_unread_count}
      chat_unread_count={@chat_unread_count}
      meeting_active={@meeting_active}
      brand_name="Acme Ops"
      current_user={@current_user}
      user={@user}
      org_name={@org_name}
      masked?={@masked?}
    />
    """)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(doc, selector), do: LazyHTML.query(doc, selector)

  defp row_keys(html) do
    html
    |> doc()
    |> q("#sidebar-nav .sidebar-row")
    |> LazyHTML.attribute("data-destination")
    |> Enum.map(&String.to_atom/1)
  end

  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  defp user!(role) do
    user =
      Repo.insert!(%User{
        email: "sidebar_#{System.unique_integer([:positive])}@example.com",
        name: "Sidebar Person",
        oidc_sub: "oidc-sidebar-#{System.unique_integer([:positive])}"
      })

    if role do
      Repo.insert!(%OrgMembership{
        user_id: user.id,
        org_id: Tenancy.get_org_by_slug!("acme").id,
        role: role
      })
    end

    user
  end

  defp scope_of(user), do: user.id |> Accounts.get_user() |> Scope.for_user()

  describe "rows" do
    test "equal the tab bar's link tabs then the More sheet's rows, for the legacy path" do
      for root_user <- [true, false] do
        expected =
          Enum.map(IconRail.tab_destinations(nil), & &1.key) ++
            Enum.map(IconRail.more_sheet_rows(nil, root_user), & &1.key)

        # Positive control: both halves are populated, and the tab half is
        # exactly mobile_tab_keys/0.
        assert Enum.take(expected, 4) == IconRail.mobile_tab_keys()
        assert length(expected) > 4

        assert row_keys(render_sidebar(%{root_user: root_user})) == expected
        assert Sidebar.row_keys(nil, root_user) == expected
      end
    end

    test "equal mobile_tab_keys ++ more_sheet_rows for a root admin's Scope and a restricted one" do
      root = scope_of(user!("admin"))
      guest = %Scope{actor: :someone, permissions: %{"chat.read" => :all}}

      for scope <- [root, guest] do
        tabs =
          Enum.filter(IconRail.mobile_tab_keys(), fn key ->
            key in Enum.map(IconRail.tab_destinations(scope), & &1.key)
          end)

        expected = tabs ++ Enum.map(IconRail.more_sheet_rows(scope, false), & &1.key)
        assert row_keys(render_sidebar(%{access_scope: scope})) == expected
      end

      # Control: the two scopes really differ, so the restricted render is
      # not the root render under another name.
      assert row_keys(render_sidebar(%{access_scope: guest})) == [:chat]
      assert length(row_keys(render_sidebar(%{access_scope: root}))) > 10
    end

    test "labels are the destination labels, More rows under a More label" do
      html = render_sidebar(%{root_user: true})
      labels = html |> doc() |> q("#sidebar-nav .sidebar-row span.truncate") |> Enum.map(&text/1)

      assert Enum.take(labels, 4) == ["Chat", "Voice", "Tasks", "Meetings"]
      assert "Inbox" in labels
      assert "Org memory" in labels

      assert html |> doc() |> q(~s([data-role="sidebar-more-label"])) |> Enum.map(&text/1) == [
               "More"
             ]
    end

    test "an extension's rail item arrives through the rail_items seam right after Inbox" do
      before = Sidebar.row_keys(nil, false)
      refute :fixture in before

      Platform.FixtureExtension.register()

      keys = row_keys(render_sidebar(%{}))
      inbox_at = Enum.find_index(keys, &(&1 == :inbox))
      assert is_integer(inbox_at)
      assert Enum.at(keys, inbox_at + 1) == :fixture
    end

    test "More rows use the More sheet's icons; module rows the tab bar's outline set" do
      html = render_sidebar(%{root_user: true})
      d = doc(html)

      icon = fn key ->
        [class] =
          d
          |> q(~s(#sidebar-nav .sidebar-row[data-destination="#{key}"] > span:first-child))
          |> LazyHTML.attribute("class")

        class |> String.split() |> Enum.find(&String.starts_with?(&1, "hero-"))
      end

      assert icon.("chat") == IconRail.tab_icon(:chat, false)
      assert icon.("meetings") == IconRail.tab_icon(:meetings, false)

      inbox = Enum.find(IconRail.more_sheet_rows(nil, true), &(&1.key == :inbox))
      assert icon.("inbox") == inbox.hero_icon
    end
  end

  describe "states" do
    test "the current row carries aria-current, the base-300 fill and the bar class; no other row does" do
      d = render_sidebar(%{current_path: "/tasks/019abc"}) |> doc()

      assert d
             |> q(~s(.sidebar-row[aria-current="page"]))
             |> LazyHTML.attribute("data-destination") ==
               ["tasks"]

      [class] = d |> q(~s(.sidebar-row[data-destination="tasks"])) |> LazyHTML.attribute("class")
      assert class =~ "sidebar-row--current"
      assert class =~ "bg-base-300"
      assert class =~ "text-base-content"

      [rest] = d |> q(~s(.sidebar-row[data-destination="chat"])) |> LazyHTML.attribute("class")
      assert rest =~ "text-subtle"
      assert rest =~ "lg:hover:bg-base-300"
      refute rest =~ "sidebar-row--current"
    end

    test "Settings is current on every settings path, and Agents does not steal /control/usage" do
      for path <- IconRail.settings_paths() ++ ["/control/usage"] do
        d = render_sidebar(%{current_path: path, root_user: true}) |> doc()

        assert d
               |> q(~s(.sidebar-row[aria-current="page"]))
               |> LazyHTML.attribute("data-destination") ==
                 ["settings"],
               path
      end

      # Control: /control is Agents.
      d = render_sidebar(%{current_path: "/control"}) |> doc()

      assert d
             |> q(~s(.sidebar-row[aria-current="page"]))
             |> LazyHTML.attribute("data-destination") ==
               ["agents"]
    end

    test "Canvases is current on its filtered browser URL, Files elsewhere under /files" do
      d = render_sidebar(%{current_path: "/files?tab=browse&type=canvas"}) |> doc()

      assert d
             |> q(~s(.sidebar-row[aria-current="page"]))
             |> LazyHTML.attribute("data-destination") ==
               ["canvases"]

      d = render_sidebar(%{current_path: "/files/abc"}) |> doc()

      assert d
             |> q(~s(.sidebar-row[aria-current="page"]))
             |> LazyHTML.attribute("data-destination") ==
               ["files"]
    end

    test "Chat and Inbox badges: absent at 0, the capped label above, primary fill" do
      d = render_sidebar(%{}) |> doc()
      assert d |> q("#chat-badge") |> Enum.count() == 0
      assert d |> q("#inbox-badge") |> Enum.count() == 0
      # Positive control: the rows themselves rendered.
      assert d |> q(~s(.sidebar-row[data-destination="inbox"])) |> Enum.count() == 1

      d = render_sidebar(%{chat_unread_count: 150, inbox_unread_count: 3}) |> doc()

      assert d |> q(~s(.sidebar-row[data-destination="chat"] #chat-badge)) |> Enum.map(&text/1) ==
               ["99+"]

      assert d |> q(~s(.sidebar-row[data-destination="inbox"] #inbox-badge)) |> Enum.map(&text/1) ==
               ["3"]

      for id <- ~w(#chat-badge #inbox-badge) do
        [class] = d |> q(id) |> LazyHTML.attribute("class")
        assert class =~ "bg-primary"
        assert class =~ "text-primary-content"
        refute class =~ ~r/#[0-9a-fA-F]{3,6}/
      end

      assert d |> q("#chat-badge") |> LazyHTML.attribute("aria-label") == ["150 unread messages"]
      # No email unread count exists in the shell, so no #email-badge.
      assert d |> q("#email-badge") |> Enum.count() == 0
    end

    test "the live-call dot is on Meetings only while a meeting is active" do
      d = render_sidebar(%{meeting_active: false}) |> doc()
      assert d |> q(~s([data-role="live-call-dot"])) |> Enum.count() == 0

      d = render_sidebar(%{meeting_active: true}) |> doc()

      assert d
             |> q(~s(.sidebar-row[data-destination="meetings"] [data-role="live-call-dot"]))
             |> LazyHTML.attribute("title") == ["live call"]
    end
  end

  describe "footer" do
    test "Settings row, mode row, user row in that order; the user row links /settings" do
      d = render_sidebar(%{org_name: "Acme"}) |> doc()

      assert d |> q(~s(.sidebar-row[data-destination="settings"])) |> LazyHTML.attribute("href") ==
               ["/settings"]

      assert d |> q("#sidebar-user") |> LazyHTML.attribute("href") == ["/settings"]

      assert d |> q(~s(#sidebar-user [data-role="sidebar-user-name"])) |> Enum.map(&text/1) ==
               ["Pat Example"]

      assert d |> q(~s(#sidebar-user [data-role="sidebar-user-org"])) |> Enum.map(&text/1) == [
               "Acme"
             ]

      assert d |> q("#sidebar-user [data-avatar-kind=human]") |> Enum.count() == 1

      # Org line omitted when no assign carries it.
      d = render_sidebar(%{}) |> doc()
      assert d |> q(~s([data-role="sidebar-user-org"])) |> Enum.count() == 0
    end

    test "the mode row names the mode a click turns on, from the stored preference" do
      dark = user!(nil)
      {:ok, dark} = Accounts.put_theme_preference(dark, %{"mode" => "dark"})
      light = user!(nil)
      {:ok, light} = Accounts.put_theme_preference(light, %{"mode" => "light"})

      d = render_sidebar(%{user: dark}) |> doc()
      assert d |> q("#mode-toggle #mode-label") |> Enum.map(&text/1) == ["Light mode"]
      assert d |> q(~s(#mode-toggle[phx-hook="ModeToggle"])) |> Enum.count() == 1
      [crescent] = d |> q(~s(#mode-toggle [data-mode-icon="dark"])) |> LazyHTML.attribute("class")
      refute crescent =~ "hidden"

      d = render_sidebar(%{user: light}) |> doc()
      assert d |> q("#mode-toggle #mode-label") |> Enum.map(&text/1) == ["Dark mode"]
    end

    test "the Names masked chip renders in the footer only while masked, with its own ids" do
      d = render_sidebar(%{masked?: false}) |> doc()
      assert d |> q(~s([data-role="mask-names-chip"])) |> Enum.count() == 0

      d = render_sidebar(%{masked?: true}) |> doc()

      assert d |> q(~s(#sidebar-mask-names-chip[data-role="mask-names-chip"])) |> Enum.count() ==
               1

      assert d |> q("#mask-names-chip") |> Enum.count() == 0
    end

    test "no colour literal and no unconditional hover utility in the component source" do
      src = File.read!(Path.expand("../../../lib/platform_web/components/sidebar.ex", __DIR__))
      refute src =~ ~r/#[0-9a-fA-F]{6}\b/
      tokens = Regex.scan(~r/[\w:\[\]\-\/\.]*hover:[\w\-\[\]\/]+/, src) |> List.flatten()
      assert tokens != [], "the reader found no hover utility at all"
      assert Enum.all?(tokens, &String.starts_with?(&1, "lg:hover:")), inspect(tokens)
    end
  end

  # ── Command palette affordances (rung 23 stage 3) ───────────────────────

  describe "command palette affordances" do
    test "#cmdk-btn sits in the brand row, after the name, and pushes palette_open to #command-palette" do
      d = render_sidebar(%{}) |> doc()

      assert d |> q("#sidebar-brand > button#cmdk-btn") |> Enum.count() == 1
      assert d |> q("#sidebar-brand > button#cmdk-btn:last-child") |> Enum.count() == 1
      assert d |> q("#cmdk-btn") |> LazyHTML.attribute("type") == ["button"]
      assert d |> q("#cmdk-btn") |> LazyHTML.attribute("title") == ["Jump anywhere (⌘K)"]
      assert d |> q("#cmdk-btn") |> LazyHTML.attribute("aria-label") == ["Command palette"]
      assert d |> q("#cmdk-btn .hero-magnifying-glass") |> Enum.count() == 1

      [click] = d |> q("#cmdk-btn") |> LazyHTML.attribute("phx-click")

      assert [["push", %{"event" => "palette_open", "target" => "#command-palette"}]] =
               Jason.decode!(click)
    end

    test "#sidebar-cmdk-hint follows #sidebar-user as the footer's last child, verbatim" do
      d = render_sidebar(%{}) |> doc()

      assert d |> q("#sidebar-user + #sidebar-cmdk-hint") |> Enum.count() == 1
      assert d |> q("#sidebar-cmdk-hint:last-child") |> Enum.count() == 1

      assert d |> q(~s(#sidebar-cmdk-hint[data-role="sidebar-cmdk-hint"])) |> Enum.count() == 1

      [hint] = d |> q("#sidebar-cmdk-hint") |> Enum.map(&text/1)
      assert String.replace(hint, ~r/\s+/, " ") == "⌘K jump · Esc close"

      assert d |> q("#sidebar-cmdk-hint kbd") |> Enum.map(&text/1) == ["⌘K", "Esc"]
    end
  end

  # ── The shell at lg ─────────────────────────────────────────────────────

  describe "the shell" do
    setup %{conn: conn} do
      user = user!("admin")
      %{conn: init_test_session(conn, current_user_id: user.id), user: user}
    end

    test "renders #sidebar and none of the icon rail, utility bar, account menu or collapse control",
         %{conn: conn} do
      for path <- ~w(/chat /tasks /meetings /settings) do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "aside#sidebar[data-sidebar]"), path

        for gone <-
              ~w(#utility-bar #shell-sidebar [data-icon-rail] #account-menu #account-menu-trigger #sidebar-collapse-hook #theme-picker-trigger) do
          refute has_element?(view, gone), "#{gone} on #{path}"
        end

        refute has_element?(view, ~s([phx-click="toggle_sidebar"])), path
        refute has_element?(view, ~s([aria-label="Collapse sidebar"])), path
        refute has_element?(view, ~s([aria-label="Expand sidebar"])), path
      end
    end

    test "the phone top strip keeps the utility bar's phone children and hides at lg",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/tasks")

      [class] =
        html
        |> LazyHTML.from_document()
        |> q("header#phone-top-bar")
        |> LazyHTML.attribute("class")

      assert "lg:hidden" in String.split(class)
      assert "h-11" in String.split(class)

      assert has_element?(view, "#phone-top-bar #native-install-switch")
      assert has_element?(view, "#phone-top-bar span.truncate", "Tasks")
      # The theme swatch was lg-only (max-lg:hidden) and the account menu
      # lg-only too: neither was ever visible on a phone.
      refute has_element?(view, "#phone-top-bar #theme-picker")
      refute has_element?(view, "#phone-top-bar #account-menu")
    end

    test "the mode row flips its label when set_theme lands", %{conn: conn, user: user} do
      {:ok, _} = Accounts.put_theme_preference(user, %{"mode" => "dark"})
      {:ok, view, _html} = live(conn, "/tasks")

      assert view |> element("#mode-toggle #mode-label") |> render() =~ "Light mode"

      render_hook(view, "set_theme", %{"preset" => "burrow", "mode" => "light"})
      assert view |> element("#mode-toggle #mode-label") |> render() =~ "Dark mode"

      render_hook(view, "set_theme", %{"preset" => "burrow", "mode" => "dark"})
      assert view |> element("#mode-toggle #mode-label") |> render() =~ "Light mode"
    end

    test "Settings > Appearance opens the theme popover from the sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")
      refute has_element?(view, "#sidebar #theme-picker-popover.lg\\:block")

      render_click(view, "toggle_theme_picker", %{})
      assert has_element?(view, "#sidebar #theme-picker #theme-picker-popover.lg\\:block")
    end

    test "clicking #cmdk-btn on /tasks opens the command palette", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tasks")
      assert has_element?(view, ~s(#command-palette[data-open="false"]))

      view |> element("#sidebar #cmdk-btn") |> render_click()

      assert has_element?(view, ~s(#command-palette[data-open="true"]))
    end

    test "the user row is the sidebar's link to /settings, where Sign out lives", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tasks")
      assert has_element?(view, ~s(#sidebar-user[href="/settings"]))

      {:ok, settings, _} = live(conn, "/settings")
      assert has_element?(settings, ~s([data-role="settings-sign-out"]), "Sign out")
    end
  end
end
