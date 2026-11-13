defmodule PlatformWeb.Components.GamingShellBottomNavTest do
  @moduledoc """
  The Console Glass gaming shell (/play, /games/*) carries the workspace's
  phone tab bar (Chat, Calendar, Meetings, Inbox, More) for a signed-in
  viewer, so the quick access stays up outside Create mode (sponsor ask,
  2026-11-13). It is the same `IconRail.bottom_rail/1` the workspace shell
  renders, not a copy.

  These pages are controller-rendered dead views, so there is no LiveView to
  call `has_element?/2` on: the rendered component is queried with LazyHTML's
  `query/2`, which descends the whole tree.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.{GamingShell, IconRail}

  defp member(role) do
    user =
      Repo.insert!(%User{
        email: "play_nav_#{System.unique_integer([:positive])}@example.com",
        name: "Play Nav",
        oidc_sub: "play-nav-#{System.unique_integer([:positive])}"
      })

    Repo.insert!(%OrgMembership{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: role
    })

    user
  end

  defp render_shell(user, enabled \\ true) do
    assigns = %{user: user, enabled: enabled}

    rendered_to_string(~H"""
    <GamingShell.shell games={[]} brand_name="Burrow Play" user={@user} enabled={@enabled}>
      <p id="page-body">body</p>
    </GamingShell.shell>
    """)
    |> LazyHTML.from_fragment()
  end

  defp has_element?(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count() > 0

  test "a signed-in viewer gets the workspace tab bar, outside the glass sidebar" do
    user = member("admin")
    doc = render_shell(user)

    assert has_element?(doc, "nav#bottom-nav[data-bottom-rail]")
    # Outside .cg-side (its backdrop-filter would trap the fixed bar) and
    # outside .cg-app (whose end padding clears it, console_glass.css).
    refute has_element?(doc, ".cg-side #bottom-nav")
    refute has_element?(doc, ".cg-app #bottom-nav")

    # The same link tabs, in the same order, as the workspace bar.
    expected =
      user
      |> Platform.Access.Scope.for_user()
      |> IconRail.tab_destinations()
      |> Enum.map(&to_string(&1.key))

    assert "chat" in expected

    tabs =
      doc
      |> LazyHTML.query("#bottom-nav a.bottom-nav-tab[data-destination]")
      |> LazyHTML.attribute("data-destination")

    assert tabs == expected ++ ["more"]
    assert has_element?(doc, ~s(#bottom-nav a[data-destination="chat"][href="/chat"]))
    assert has_element?(doc, ~s(#bottom-nav a[data-destination="meetings"][href="/meetings"]))
    # Nothing on /play is one of the tabs.
    refute has_element?(doc, "#bottom-nav [aria-current]")
  end

  test "More is a link that opens the sheet in the workspace, not a dead phx-click" do
    doc = render_shell(member("admin"))

    assert has_element?(doc, ~s(#bottom-nav a[data-destination="more"][href="/chat?more=1"]))
    refute has_element?(doc, "#bottom-nav button[data-destination=more]")
    refute has_element?(doc, "#bottom-nav [phx-click]")
    # The bar's hooks, mounted by hand on dead views (dead_view_tab_bar.js).
    assert has_element?(doc, ~s(#bottom-nav[phx-hook="TabPill"]))
    assert has_element?(doc, ~s(#native-tab-bridge[phx-hook="NativeTabBar"]))
  end

  test "a signed-out player gets no workspace nav" do
    doc = render_shell(nil)

    assert has_element?(doc, "#console-glass-shell")
    refute has_element?(doc, "#bottom-nav")
  end

  test "a disabled shell renders no tab bar" do
    doc = render_shell(member("admin"), false)

    assert has_element?(doc, "#page-body")
    refute has_element?(doc, "#bottom-nav")
  end
end
