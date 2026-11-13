defmodule PlatformWeb.Components.GamingShellInstallSwitchTest do
  @moduledoc """
  The Console Glass gaming shell (/play, /games/*) carries the install
  switcher on its Burrow brand, so a player on a gaming install can switch
  installs (sponsor report, 2026-11-12: stuck in Burrow Play with no way out).

  These pages are controller-rendered dead views, so there is no LiveView to
  call `has_element?/2` on: the rendered component is queried with LazyHTML's
  `query/2`, which descends the whole tree.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PlatformWeb.Components.GamingShell

  defp render_shell(attrs) do
    assigns = Map.merge(%{games: [], brand_name: "Burrow Play"}, attrs)

    rendered_to_string(~H"""
    <GamingShell.shell games={@games} brand_name={@brand_name}>
      <p id="page-body">body</p>
    </GamingShell.shell>
    """)
    |> LazyHTML.from_fragment()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "the brand is the install switcher, wired to the shared hook" do
    doc = render_shell(%{})

    button = LazyHTML.query(doc, ".cg-side button#gaming-install-switch")
    assert Enum.count(button) == 1
    assert LazyHTML.attribute(button, "phx-hook") == ["NativeInstallSwitch"]
    assert LazyHTML.attribute(button, "data-variant") == ["play"]
    assert LazyHTML.attribute(button, "data-install-name") == ["Burrow Play"]
    assert LazyHTML.attribute(button, "aria-label") == ["Switch install, current: Burrow Play"]
    # Console Glass look: the mark and the PLAY pill stay.
    assert count(doc, "#gaming-install-switch img[src='/images/burrow-mark.svg']") == 1

    assert doc |> LazyHTML.query("#gaming-install-switch > span") |> Enum.at(0) |> LazyHTML.text() ==
             "PLAY"

    assert count(doc, "#gaming-install-switch [data-role='install-unread-dot']") == 1
  end

  test "it renders hidden with a /play fallback link for when no hook reveals it" do
    doc = render_shell(%{})

    [class] = doc |> LazyHTML.query("#gaming-install-switch") |> LazyHTML.attribute("class")
    assert "hidden" in String.split(class)
    assert count(doc, ".cg-side a.cg-brand-fallback[href='/play']") == 1
  end

  test "its dropdown container is unique, ignored by patches, and outside the glass sidebar" do
    doc = render_shell(%{})

    assert count(doc, "#gaming-install-switch") == 1
    assert count(doc, "#gaming-install-switch-menu") == 1
    assert count(doc, "#gaming-install-switch-menu[phx-update='ignore']") == 1
    # .cg-side has a backdrop-filter: a fixed dropdown inside it would be
    # positioned against it and clipped.
    assert count(doc, ".cg-side #gaming-install-switch-menu") == 0
    assert count(doc, ".cg-app #gaming-install-switch-menu") == 0
    assert count(doc, "[data-install-switch-bar] #gaming-install-switch") == 1
  end

  test "the brand name defaults to this install's branding" do
    doc = render_shell(%{brand_name: nil})

    assert LazyHTML.attribute(LazyHTML.query(doc, "#gaming-install-switch"), "data-install-name") ==
             [Platform.Branding.app_name()]
  end

  test "a disabled shell renders no switcher" do
    assigns = %{}

    doc =
      rendered_to_string(~H"""
      <GamingShell.shell enabled={false}>
        <p>body</p>
      </GamingShell.shell>
      """)
      |> LazyHTML.from_fragment()

    assert count(doc, "#gaming-install-switch") == 0
    assert count(doc, "#gaming-install-switch-menu") == 0
  end
end
