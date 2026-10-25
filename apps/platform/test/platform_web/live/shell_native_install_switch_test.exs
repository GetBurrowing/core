defmodule PlatformWeb.ShellNativeInstallSwitchTest do
  @moduledoc """
  Task 01a1261e stage 3: the native install switcher in the shell's utility
  bar.

  The server renders the button for every client but HIDDEN; only the
  `NativeInstallSwitch` hook reveals it, inside the Burrow app. So what the
  server must guarantee is exactly: the element exists on a shell route, in
  the phone top strip (the utility bar until Burrow redesign 22), carries `hidden` and the hook, names the install, and
  holds the dot element (itself hidden) in the `bg-primary` slot.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp signed_in(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "switch-#{n}@example.com",
        name: "Switch #{n}",
        oidc_sub: "oidc-switch-#{n}"
      })

    Repo.insert!(%OrgMembership{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "member"
    })

    init_test_session(conn, current_user_id: user.id)
  end

  defp utility_bar(html) do
    case Regex.run(~r/(<header[^>]*id="phone-top-bar".*?<\/header>)/s, html) do
      [_, bar] -> bar
      nil -> flunk("the phone top strip never rendered")
    end
  end

  test "the shell renders the switcher hidden, in the phone top strip, with the hook, brand and dot",
       %{conn: conn} do
    {:ok, view, html} = live(signed_in(conn), ~p"/tasks")

    assert has_element?(view, "#native-install-switch")
    assert has_element?(view, "#phone-top-bar #native-install-switch")

    button = view |> element("#native-install-switch") |> render()
    [class] = Regex.run(~r/<button[^>]*\bclass="([^"]*)"/, button, capture: :all_but_first)

    assert "hidden" in String.split(class), "the server must render it hidden for every client"
    refute "flex" in String.split(class), "hidden + flex would leave the display to CSS order"
    assert button =~ ~s(phx-hook="NativeInstallSwitch")
    assert button =~ ~s(data-role="native-install-switch")
    assert button =~ Platform.Branding.app_name()
    assert button =~ ~s(src="/branding/current/apple_touch")
    assert button =~ "hero-chevron-down"

    [dot] =
      Regex.run(~r/<span[^>]*data-role="install-unread-dot"[^>]*>/, button)

    [dot_class] = Regex.run(~r/class="([^"]*)"/, dot, capture: :all_but_first)
    assert "hidden" in String.split(dot_class)
    assert "bg-primary" in String.split(dot_class)

    # Before the active-module label, per the canvas.
    bar = utility_bar(html)
    {switch_at, _} = :binary.match(bar, "native-install-switch")
    {module_at, _} = :binary.match(bar, "Tasks")
    assert switch_at < module_at
  end

  test "no emoji and no hex colour in the switcher markup", %{conn: conn} do
    {:ok, view, _html} = live(signed_in(conn), ~p"/tasks")
    button = view |> element("#native-install-switch") |> render()

    refute button =~ ~r/[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/u
    refute button =~ ~r/#[0-9a-fA-F]{3,8}\b/
  end
end
