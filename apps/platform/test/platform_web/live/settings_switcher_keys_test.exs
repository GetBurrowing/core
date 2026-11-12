defmodule PlatformWeb.SettingsSwitcherKeysTest do
  @moduledoc """
  Task 01a1ccd4 stage 2: Settings lists the badge keys other installs'
  switchers hold for this one, and removes (revokes) them.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures

  alias Platform.Switcher

  defp member! do
    user = create_user!()
    plain_member!(user, hd(Platform.Tenancy.list_orgs()))
    user
  end

  test "no keys, no section", %{conn: conn} do
    user = member!()

    {:ok, view, _html} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/settings")

    refute has_element?(view, "[data-role=settings-switcher-keys]")
  end

  test "lists live keys and Remove revokes one", %{conn: conn} do
    user = member!()
    {:ok, %{token: token, key: key}} = Switcher.mint(user, "https://a.example")
    {:ok, %{key: other}} = Switcher.mint(user, "https://c.example:8443")
    {:ok, %{key: revoked}} = Switcher.mint(user, "https://gone.example")
    {:ok, _} = Switcher.revoke(user, revoked.id)
    # Someone else's key never shows.
    {:ok, _} = Switcher.mint(member!(), "https://z.example")

    {:ok, view, _html} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/settings")

    assert has_element?(view, "#switcher_keys-#{key.id}", "https://a.example")
    assert has_element?(view, "#switcher_keys-#{other.id}", "https://c.example:8443")
    refute has_element?(view, "#switcher_keys-#{revoked.id}")
    refute render(view) =~ "z.example"

    view
    |> element("#switcher_keys-#{key.id} [data-role=settings-switcher-key-revoke]")
    |> render_click()

    refute has_element?(view, "#switcher_keys-#{key.id}")
    assert has_element?(view, "#switcher_keys-#{other.id}")
    assert Switcher.verify(token, "https://a.example") == :error
  end

  test "a forged revoke for another user's key changes nothing", %{conn: conn} do
    user = member!()
    stranger = member!()
    {:ok, %{token: token, key: key}} = Switcher.mint(stranger, "https://a.example")
    {:ok, _} = Switcher.mint(user, "https://b.example")

    {:ok, view, _html} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/settings")

    render_hook(view, "revoke_switcher_key", %{"id" => key.id})

    assert {:ok, _, _} = Switcher.verify(token, "https://a.example")
  end
end
